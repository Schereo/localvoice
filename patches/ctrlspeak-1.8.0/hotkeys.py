"""
Hotkey activation handler for ctrlSPEAK.

Handles triple-tap Ctrl activation and routes to either:
- Streaming mode: For models that support real-time streaming (e.g., Nemotron)
- Queue mode: For models that use batch transcription (e.g., Parakeet, Canary)
"""

import fcntl
import logging
import math
import os
import queue
import socket
import subprocess
import threading
import time
import state
from state import TranscriptionJob
from utils import localvoice_config
from utils import media_pause
from utils.clipboard import copy_to_clipboard, paste_from_clipboard, type_text
from utils.player import play_start_beep, play_stop_beep
from utils.history import get_history_manager
from transcription import discard_pending_jobs, quiet_content_logger

logger = logging.getLogger("ctrlspeak.hotkeys")

_streaming_model = None

_session_lock_handle = None

_OVERLAY_PATH = os.environ.get(
    "CTRLSPEAK_OVERLAY_PATH",
    "/opt/homebrew/bin/ctrlspeak-overlay",
)
_overlay_session = None
_overlay_session_lock = threading.Lock()
_language_lock = threading.Lock()

# --- Hotkey dispatch -------------------------------------------------------
#
# The key callbacks run on pynput's CGEventTap callback, which macOS expects
# to return promptly — and which the whole hotkey system depends on. Every
# heavy step (opening CoreAudio, the clipboard, waiting for a transcription)
# can wedge in a C-level mutex, and wedging it there took dictation down for
# good. So the callbacks only enqueue; this worker does the work.
_command_queue = queue.Queue()
_worker_thread = None
_worker_lock = threading.Lock()

# The watchdog's view of the worker: when the current command started, and
# what it was. Plain assignments, atomic in CPython, read without a lock so
# the watchdog can never block on the thread it is watching.
_command_started_at = None
_command_name = None
_watchdog_event = threading.Event()

# Generous enough for a long recording's transcription (a 30 s clip decodes
# in about a second), short enough that a wedge does not cost the morning.
WATCHDOG_TIMEOUT_S = 90.0

def _announce_restart():
    """Put a pill on screen explaining the imminent hard exit.

    Spawned detached and stdin-less: this process is about to die, and the
    pill has to outlive it long enough to be read.
    """
    try:
        subprocess.Popen(
            [_OVERLAY_PATH, "error", state.source_lang],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        logger.warning(f"Could not show the restart pill: {exc}")


def _watchdog():
    """Restart the service when a command stops making progress.

    A CoreAudio or pasteboard deadlock leaves the process alive, so launchd's
    KeepAlive never fires — dictation is dead but the service looks healthy.
    os._exit is the only exit that works with threads stuck in a kernel mutex;
    the LaunchAgent brings us back a few seconds later.
    """
    while True:
        started = _command_started_at
        if started is None:
            # Sleep without waking while idle (0 wakeups/s).
            _watchdog_event.wait()
            _watchdog_event.clear()
            continue

        elapsed = time.monotonic() - started
        if elapsed < WATCHDOG_TIMEOUT_S:
            _watchdog_event.wait(timeout=min(1.0, WATCHDOG_TIMEOUT_S - elapsed))
            _watchdog_event.clear()
            continue

        logger.error(
            f"Watchdog: '{_command_name}' has not finished after {elapsed:.0f}s; "
            "the audio or clipboard stack is wedged. Restarting the service."
        )
        _announce_restart()
        time.sleep(0.4)  # let the pill process get off the ground
        os._exit(1)


def _worker():
    """Run queued hotkey commands one at a time, in order."""
    global _command_started_at, _command_name

    while True:
        name, handler = _command_queue.get()
        _command_name = name
        _command_started_at = time.monotonic()
        _watchdog_event.set()
        try:
            handler()
        except Exception:
            logger.error("Hotkey command '%s' failed.", name)
        finally:
            _command_started_at = None
            _command_name = None
            _watchdog_event.set()


def _ensure_worker():
    global _worker_thread

    with _worker_lock:
        if _worker_thread is not None:
            return

        _worker_thread = threading.Thread(
            target=_worker, name="ctrlspeak-hotkey-worker", daemon=True
        )
        _worker_thread.start()
        threading.Thread(
            target=_watchdog, name="ctrlspeak-watchdog", daemon=True
        ).start()


def _dispatch(name, handler):
    """Hand a command to the worker and return to the event tap at once."""
    _ensure_worker()
    _command_queue.put((name, handler))
    return True


class _SocketOverlayProcess:
    """Process-compatible wrapper around LocalVoice's in-process overlay socket."""

    def __init__(self, sock):
        self._sock = sock
        self._closed = False
        self.stdin = sock.makefile("w", encoding="utf-8", buffering=1)
        self.stdout = sock.makefile("r", encoding="utf-8", buffering=1)

    def poll(self):
        return 0 if self._closed else None

    def _close_all(self):
        if self._closed:
            return
        self._closed = True
        for stream in (self.stdin, self.stdout):
            try:
                stream.close()
            except OSError:
                pass
        try:
            self._sock.close()
        except OSError:
            pass

    def kill(self):
        self._close_all()

    def terminate(self):
        self._close_all()

    def wait(self, timeout=None):
        self._close_all()
        return 0


def _connect_overlay_socket():
    """Connect to the launcher's embedded overlay server, or return None."""
    socket_path = os.environ.get("LOCALVOICE_OVERLAY_SOCKET")
    if not socket_path:
        return None
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(1.0)
        sock.connect(socket_path)
        sock.settimeout(None)
        return _SocketOverlayProcess(sock)
    except OSError as exc:
        try:
            sock.close()
        except OSError:
            pass
        logger.debug("Embedded overlay socket unavailable (%s); falling back to helper.", exc)
        return None


class _OverlaySession:
    """Own a persistent recorder HUD and feed it microphone levels."""

    def __init__(self, language, initial_mode="recording"):
        self.language = language
        self.initial_mode = initial_mode
        self.reusable = initial_mode == "recording"
        self.commands = queue.SimpleQueue()
        self._alive = True
        self.thread = threading.Thread(
            target=self._run,
            name="ctrlspeak-overlay",
            daemon=True,
        )

    def start(self):
        self.thread.start()

    def is_reusable_and_alive(self):
        return self.reusable and self._alive and self.thread.is_alive()

    def show(self, language):
        """Reuse this running standby/result pill for a fresh recording."""
        self.language = language
        while True:
            try:
                self.commands.get_nowait()
            except queue.Empty:
                break
        self.commands.put(f"show {language}")

    def set_state(self, overlay_state):
        self.commands.put(f"state {overlay_state}")

    def set_detail(self, text):
        """Set the pill's secondary line. Newlines would desync the protocol."""
        self.commands.put("detail " + " ".join(str(text).split()))

    def set_final_text(self, text):
        """Replace the pill's confirmed live-transcript line."""
        self.commands.put(("final " + " ".join(str(text).split())).rstrip())

    def set_partial_text(self, text):
        """Replace the pill's dimmed in-progress guess."""
        self.commands.put(("partial " + " ".join(str(text).split())).rstrip())

    def close(self):
        self.commands.put("quit")

    def discard(self):
        # Capture is already frozen: no worker can enqueue another preview.
        while True:
            try:
                self.commands.get_nowait()
            except queue.Empty:
                break
        self.set_final_text("")
        self.set_partial_text("")
        self.set_state("cancelled")

    @staticmethod
    def _normalized_level():
        """Convert ctrlSPEAK's RMS value to a perceptual 0...1 meter."""
        rms = float(getattr(state.audio_manager, "last_rms", 0.0) or 0.0)
        decibels = 20.0 * math.log10(max(rms, 1e-7))
        return max(0.0, min(1.0, (decibels + 60.0) / 48.0))

    @staticmethod
    def _write(process, command):
        process.stdin.write(command + "\n")
        process.stdin.flush()

    def _run(self):
        process = None
        mode = self.initial_mode
        terminal_deadline = None

        try:
            if self.initial_mode == "recording":
                process = _take_standby_overlay()
                if process is None:
                    process = _connect_overlay_socket()
                if process is None:
                    process = subprocess.Popen(
                        [_OVERLAY_PATH, "standby", self.language],
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        text=True,
                        bufsize=1,
                    )
                if process is not None:
                    try:
                        self._write(process, f"show {self.language}")
                    except (BrokenPipeError, OSError):
                        process.kill()
                        process = None
            if process is None:
                self.reusable = False
                process = subprocess.Popen(
                    [_OVERLAY_PATH, self.initial_mode, self.language],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    bufsize=1,
                )
            logger.info("Animated recorder overlay started")

            while process.poll() is None:
                if mode == "recording":
                    wait_timeout = 0.04
                elif terminal_deadline is not None:
                    wait_timeout = max(0.05, terminal_deadline - time.monotonic())
                elif self.reusable:
                    # Hidden standby between recordings: block with 0 wakeups/s.
                    wait_timeout = None
                else:
                    wait_timeout = 0.5
                try:
                    command = self.commands.get(timeout=wait_timeout)
                except queue.Empty:
                    command = None

                if command:
                    self._write(process, command)

                    if command == "quit":
                        break

                    if command.startswith("show "):
                        mode = "recording"
                        terminal_deadline = None
                    elif command.startswith("state "):
                        mode = command.split(" ", 1)[1]
                        if mode in {"success", "empty", "cancelled", "clipboard", "failed"}:
                            if self.reusable:
                                # The Swift overlay fades to hidden standby and stays alive.
                                mode = "standby"
                                terminal_deadline = None
                            else:
                                terminal_deadline = time.monotonic() + 3.0

                if mode == "recording":
                    self._write(process, f"level {self._normalized_level():.4f}")

                if terminal_deadline and time.monotonic() >= terminal_deadline:
                    break

        except (BrokenPipeError, OSError) as exc:
            logger.warning(f"Recorder overlay stopped unexpectedly: {exc}")
        finally:
            self._alive = False
            if process is not None:
                try:
                    if process.stdin:
                        process.stdin.close()
                except OSError:
                    pass

                if process.poll() is None:
                    try:
                        process.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        process.terminate()


# A pill started ahead of the hotkey in the overlay's "standby" mode: AppKit
# is up and the window built, but nothing is on screen. "show <language>"
# brings it up within a frame (~20 ms) instead of after a process launch
# (~0.15-0.25 s), which was most of the wait between hotkey and pill.
_standby_overlay = None
_standby_overlay_lock = threading.Lock()


def prepare_overlay():
    """Have a hidden pill waiting for the next recording. Never raises."""
    global _standby_overlay
    if os.environ.get("LOCALVOICE_OVERLAY_SOCKET"):
        # Connect to the launcher's embedded overlay over the Unix socket so
        # _arm_overlay() and the first recording have 0 ms startup overhead.
        with _standby_overlay_lock:
            if _standby_overlay is not None and _standby_overlay.poll() is None:
                return
            _standby_overlay = _connect_overlay_socket()
        return
    with _standby_overlay_lock:
        if _standby_overlay is not None and _standby_overlay.poll() is None:
            return
        try:
            _standby_overlay = subprocess.Popen(
                [_OVERLAY_PATH, "standby", state.source_lang],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            _standby_overlay = None
            logger.warning(f"Could not prepare the recorder overlay: {exc}")


def _signal_standby_overlay(command):
    """Send one command to the waiting pill without taking it. Never raises;
    returns whether it was delivered."""
    with _overlay_session_lock:
        if _overlay_session is not None and _overlay_session.is_reusable_and_alive():
            _overlay_session.commands.put(command)
            return True
    with _standby_overlay_lock:
        process = _standby_overlay
        if process is None or process.poll() is not None:
            return False
        try:
            process.stdin.write(command + "\n")
            process.stdin.flush()
            return True
        except (BrokenPipeError, OSError):
            return False


def _arm_overlay():
    """Answer the hotkey at once: the waiting pill appears as a small circle
    while the microphone opens, and grows into the pill on "show"."""
    return _signal_standby_overlay("arm")


def _disarm_overlay():
    """The start failed after arming: fold the circle away again."""
    _signal_standby_overlay("disarm")


def _take_standby_overlay():
    global _standby_overlay
    with _standby_overlay_lock:
        process, _standby_overlay = _standby_overlay, None
    if process is not None and process.poll() is None:
        return process
    return None


def _start_recording_overlay():
    """Show the persistent recording overlay (reusing it across sessions)."""
    global _overlay_session

    with _overlay_session_lock:
        if _overlay_session is not None and _overlay_session.is_reusable_and_alive():
            _overlay_session.show(state.source_lang)
            return
        if _overlay_session is not None:
            _overlay_session.close()

        _overlay_session = _OverlaySession(state.source_lang)
        _overlay_session.start()


def _show_start_error(detail):
    # Use the existing short-lived status, not the watchdog-only restart mode.
    overlay = _OverlaySession(state.source_lang, initial_mode="empty")
    overlay.set_detail(detail)
    overlay.set_state("empty")
    overlay.start()


def _set_overlay_state(overlay_state):
    """Transition the current overlay without recreating its window."""
    with _overlay_session_lock:
        if _overlay_session is not None:
            _overlay_session.set_state(overlay_state)


def _set_overlay_detail(text):
    """Add a secondary line to the current overlay."""
    with _overlay_session_lock:
        if _overlay_session is not None:
            _overlay_session.set_detail(text)


def set_overlay_transcript(final=None, partial=None):
    """Update the live transcript in the recording pill; None leaves a half
    untouched. Called from the transcription worker, hence public and
    self-locking."""
    with _overlay_session_lock:
        if _overlay_session is None:
            return
        if final is not None:
            _overlay_session.set_final_text(final)
        if partial is not None:
            _overlay_session.set_partial_text(partial)


def _apply_language(language, persist=True):
    """Apply a language edited in the config.

    persist=False is for changes that already come *from* the config file;
    writing them back would touch its mtime and ping the watcher again.
    """
    if getattr(state.stt_model, "supports_forced_language", True) is False:
        return
    language = language.lower()
    if language not in localvoice_config.VALID_LANGUAGES:
        logger.warning("Ignoring unsupported language from recorder overlay.")
        return

    with _language_lock:
        state.source_lang = language
        state.target_lang = language
        # A preview decoded in the old language is not this segment's text.
        state.last_preview = None

        if hasattr(state, "app_state_ref") and state.app_state_ref:
            state.app_state_ref.source_lang = language
            state.app_state_ref.target_lang = language

        if persist:
            try:
                localvoice_config.set_value("language", language)
            except OSError as exc:
                logger.warning(f"Could not persist language preference: {exc}")

    logger.info(f"Forced transcription language changed to: {language}")


def open_config():
    """Queue opening the config file in a text editor (Cmd+, while recording)."""
    return _dispatch("open-config", _perform_open_config)


def _perform_open_config():
    """Open the LocalVoice configuration in the default text editor.

    The recording keeps running: the shortcut is a door to the settings, not
    a verdict on the current dictation — Esc discards, Enter inserts, as ever.
    """
    try:
        config_path = localvoice_config.ensure_config_file()
        subprocess.Popen(
            ["/usr/bin/open", "-t", str(config_path)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        logger.info(f"Opened the configuration file: {config_path}")
    except OSError as exc:
        logger.warning(f"Could not open the configuration file: {exc}")


# --- Live transcript preview ----------------------------------------------
#
# With "live-preview" on, the pill shows the transcript while the user talks:
# confirmed phrases come from the normal segment pipeline (pushed by the
# transcription worker), and the dimmed guess of the phrase in progress comes
# from this ticker. About once a second it snapshots the still-open segment
# buffer and hands it to the transcription queue as a preview job — the same
# worker thread decodes it, because MLX streams are thread-local.

PREVIEW_INTERVAL_S = 1.0
# A guess only needs the tail of a long phrase, and decoding minutes of audio
# every second would starve the pipeline the preview rides on.
PREVIEW_MAX_WINDOW_S = 15.0
PREVIEW_MIN_AUDIO_S = 0.6


# Decode the open segment as soon as the speaker pauses, live preview or not.
# If they stop (or pause long enough for the silence cut) without saying more,
# that decode is the segment's transcript and nothing is left to wait for.
SPECULATE_QUIET_CHUNKS = 4  # ~0.26 s of quiet audio after speech
# A whole segment fits one Whisper window; longer ones are decoded as usual.
SPECULATE_MAX_WINDOW_S = 28.0
SEGMENT_TICK_S = 0.05


def _segment_ticker(manager, recording_id):
    """Feed snapshots of the open segment to the worker while recording:
    every second for the live preview, and once per pause in speech."""
    import numpy as np
    from utils.audio import SAMPLE_RATE

    last_preview = time.monotonic()
    covered = None  # (segment, speech end) of the newest whole snapshot
    event = getattr(manager, "speculate_event", None)
    while True:
        if event is not None:
            if state.live_preview_active:
                timeout = min(SEGMENT_TICK_S, max(0.01, PREVIEW_INTERVAL_S - (time.monotonic() - last_preview)))
            else:
                timeout = SEGMENT_TICK_S
            event.wait(timeout=timeout)
            event.clear()
        else:
            time.sleep(SEGMENT_TICK_S)
        with manager.capture_lock:
            if not (manager.is_collecting and manager.recording_id == recording_id):
                return
            # Real segments win. Only copy the tail, and make enqueue atomic
            # with freeze so Stop/Esc cannot miss a late producer.
            if state.transcription_queue.unfinished_tasks or not manager.audio_buffer:
                continue
            chunks = len(manager.audio_buffer)
            key = (manager.segments_queued, chunks - manager.quiet_tail_chunks)
            speculate = manager.quiet_tail_chunks >= SPECULATE_QUIET_CHUNKS and key != covered
            periodic = (state.live_preview_active
                        and time.monotonic() - last_preview >= PREVIEW_INTERVAL_S)
            if not (speculate or periodic):
                continue
            window = SPECULATE_MAX_WINDOW_S if speculate else PREVIEW_MAX_WINDOW_S
            remaining = int(window * SAMPLE_RATE)
            parts = []
            for chunk in reversed(manager.audio_buffer):
                parts.append(chunk[-remaining:])
                remaining -= len(parts[-1])
                if remaining <= 0:
                    break
            # Whole segment (not just its tail): the result can stand in for
            # the segment's own decode; see AudioManager._queue_segment.
            whole = remaining > 0
            if speculate:
                covered = key  # one try per pause, whole or not
            if not whole and not state.live_preview_active:
                continue  # a tail is only good for the pill, and there is none
            last_preview = time.monotonic()
            audio = np.concatenate(parts[::-1])
            if len(audio) >= int(PREVIEW_MIN_AUDIO_S * SAMPLE_RATE):
                if whole:
                    covered = key
                state.transcription_queue.put(
                    TranscriptionJob(
                        recording_id, "preview", audio, manager.segments_queued,
                        preview_chunks=chunks if whole else -1,
                    )
                )


def _start_live_preview():
    """Start the segment ticker; the pill shows previews if the config asks."""
    state.live_preview_active = localvoice_config.as_bool("live-preview")
    threading.Thread(
        target=_segment_ticker,
        args=(state.audio_manager, state.audio_manager.recording_id),
        name="ctrlspeak-segment-ticker",
        daemon=True,
    ).start()
    if state.live_preview_active:
        logger.info("Live transcript preview enabled for this session.")


def _clear_transcript():
    state.transcribed_chunks.clear()
    state.last_preview = None
    if getattr(state, "app_state_ref", None):
        state.app_state_ref.accumulated_text = ""


def _start_streaming_recording(manager, model):
    def on_chunk(audio, is_final=False):
        # Preserve the old queue's bounded backlog, but never drop the tail.
        if is_final or state.transcription_queue.qsize() < 50:
            state.transcription_queue.put(
                TranscriptionJob(
                    manager.recording_id, "stream", audio, is_final=is_final, backend=model
                )
            )

    with manager.capture_lock:
        manager.start_streaming(getattr(model, "chunk_size_ms", 1120), on_chunk)
        state.transcription_queue.put(
            TranscriptionJob(manager.recording_id, "stream-start", backend=model)
        )


def _acquire_session_lock():
    path = os.environ.get("LOCALVOICE_SESSION_LOCK")
    if not path:
        return None
    # A separate handle for each session. Do not truncate or unlink the inode:
    # the launcher must always be locking the same file.
    handle = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        os.close(handle)
        raise
    return handle


def _release_session_lock():
    global _session_lock_handle
    handle, _session_lock_handle = _session_lock_handle, None
    if handle is not None:
        os.close(handle)


def is_recording():
    """Whether a recording session is currently collecting audio."""
    return state.audio_manager is not None and state.audio_manager.is_collecting


def _request_end(name, *, discard=False):
    manager = state.audio_manager
    if manager is None:
        return True
    recording_id = manager.recording_id
    if not manager.is_collecting:
        return True
    return _dispatch(name, lambda: _end_recording(recording_id, discard=discard))


def cancel_recording():
    """Queue a discard for this recording, never for a later recording."""
    return _request_end("cancel", discard=True)


def finish_recording():
    """Queue a stop-and-insert (called from the event tap)."""
    return _request_end("finish")


def on_activate():
    """Queue a hotkey activation (called from the event tap)."""
    if is_recording():
        return _request_end("finish")
    return _dispatch("activate", _start_recording)


def press_to_talk(on_nothing=None):
    """Queue a start for hold-to-talk; a running recording is left alone.

    `on_nothing` runs if the start leaves no recording collecting (the
    microphone failed to open, the model is loading), so the app does not
    wait for a release that has nothing to end.
    """
    def start():
        _start_recording()
        manager = state.audio_manager
        if on_nothing is not None and (manager is None or not manager.is_collecting):
            on_nothing()

    return _dispatch("start", start)


def _queued_end(name, *, discard):
    # Unlike finish and cancel, this does not look at the recording now: it
    # queues behind the start, so a press shorter than the microphone takes
    # to open still ends the recording it began instead of leaving it running.
    def end():
        manager = state.audio_manager
        if manager is not None and manager.is_collecting:
            _end_recording(manager.recording_id, discard=discard)

    return _dispatch(name, end)


def release_to_insert():
    """Queue stop-and-insert for hold-to-talk, behind the start."""
    return _queued_end("stop", discard=False)


def release_to_discard():
    """Queue a discard for hold-to-talk (⌃⌘ let go after a click), behind the start."""
    return _queued_end("release-cancel", discard=True)


def _start_recording():
    global _streaming_model, _session_lock_handle
    manager = state.audio_manager
    if manager is None or manager.is_collecting:
        return
    if getattr(state, "app_state_ref", None) and state.app_state_ref.is_loading_model:
        state.console.print("[yellow]Please wait for model to finish loading...[/yellow]")
        return
    if not state.model_loaded:
        state.console.print("[yellow]Model is still loading. Please wait...[/yellow]")
        return

    try:
        _session_lock_handle = _acquire_session_lock()
    except BlockingIOError:
        logger.info("Recording deferred while the launcher holds the session lock.")
        _show_start_error("Model is changing — try again in a moment")
        return
    except OSError:
        logger.error("Could not acquire the recording session lock.")
        _show_start_error("Recording is temporarily unavailable")
        return

    opened_on_demand = False
    started = False
    # Before the microphone: a Bluetooth input can take seconds to open, and
    # the hotkey should still get an answer within a frame. The circle is not
    # the recording pill, so it claims nothing the microphone isn't taking.
    armed = _arm_overlay()
    try:
        if model_id := os.environ.get("LOCALVOICE_MODEL_ID"):
            # Apply a preference at the recording boundary, including for
            # Nemotron's streaming prompt. Never change it mid-recording.
            state.source_lang = state.target_lang = localvoice_config.model_language(model_id)
        paused = None
        if localvoice_config.as_bool("pause-media"):
            # Runs while the microphone opens instead of before it.
            paused = threading.Event()
            _queue_media(lambda: _pause_media(paused))
        with manager.input_stream_lock:
            if not state.mic_standby:
                opened_on_demand = True
                # Also readies a standby capture child for the next one.
                manager.open_input_stream(prepare_next=True)
            if paused is not None:
                # Music still playing from the speakers must not open the
                # dictation. Usually done already (osascript ~50 ms, the
                # microphone ~100 ms); bounded for a slow Apple Event.
                paused.wait(PAUSE_MEDIA_WAIT_S)
                if media_pause.paused_any():
                    manager.drop_preroll()
            state.recording_start_time = time.monotonic()
            _clear_transcript()
            model = state.stt_model
            _streaming_model = model if getattr(model, "supports_streaming", False) else None
            if getattr(state, "model_unloaded", False) and _streaming_model is None:
                # Reload the idle-unloaded model on the worker thread while the
                # user speaks so the first segment does not wait for startup.
                state.transcription_queue.put(
                    TranscriptionJob(manager.recording_id, "preload")
                )
            state.live_preview_active = (_streaming_model is not None
                                         and localvoice_config.as_bool("live-preview"))
            if _streaming_model is not None:
                _start_streaming_recording(manager, _streaming_model)
            else:
                manager.start_recording()

        if localvoice_config.sounds():
            play_start_beep()
        # The recording pill itself only once capture is live, so it never
        # claims a recording the microphone is not yet taking. The armed
        # circle grows into it; without one, the standby pill grows from a
        # dot (~20 ms, not a ~0.2 s process launch).
        _start_recording_overlay()
        if _streaming_model is None:
            _start_live_preview()
        started = True
    except Exception:
        logger.error("Could not start recording.")
        _show_start_error("Could not start recording")
    finally:
        if not started:
            if armed:
                _disarm_overlay()
            if manager.is_collecting:
                _end_recording(manager.recording_id, discard=True)
            else:
                try:
                    with manager.input_stream_lock:
                        if opened_on_demand and not state.mic_standby:
                            manager.close_input_stream()
                finally:
                    _resume_playback()
                    state.recording_start_time = None
                    _streaming_model = None
                    _release_session_lock()


# Pausing and resuming media players runs osascript (~50 ms with no player
# open, more once Apple Events reach Spotify or Music), which used to sit in
# front of the microphone on every start and in front of the transcription on
# every stop. One serial thread takes them off both paths and keeps their
# order, so a resume can never overtake the pause it undoes, nor the pause of
# a recording started right after it.
# A daemon, unlike a ThreadPoolExecutor's workers: a pending osascript must
# never hold up the service's exit.
_media_queue = queue.Queue()
_media_thread = None
_media_thread_lock = threading.Lock()


def _media_worker():
    while True:
        operation = _media_queue.get()
        try:
            operation()
        finally:
            _media_queue.task_done()


def _queue_media(operation):
    global _media_thread
    with _media_thread_lock:
        if _media_thread is None:
            _media_thread = threading.Thread(
                target=_media_worker, name="ctrlspeak-media", daemon=True
            )
            _media_thread.start()
    _media_queue.put(operation)


# How long a recording start waits for media to stop before capturing.
PAUSE_MEDIA_WAIT_S = 0.5


def _pause_media(done=None):
    try:
        media_pause.pause_playing()
    except Exception:
        logger.warning("Could not pause playback.")
    finally:
        if done is not None:
            done.set()


def _resume_media():
    try:
        media_pause.resume_paused()
    except Exception:
        logger.warning("Could not resume playback.")


def _resume_playback():
    _queue_media(_resume_media)


def _end_recording(recording_id, *, discard=False):
    global _streaming_model
    manager = state.audio_manager
    if manager is None or not manager.is_collecting or recording_id != manager.recording_id:
        return

    playback_resumed = False
    try:
        if not manager.freeze_recording(discard=discard):
            return
        state.live_preview_active = False
        with manager.input_stream_lock:
            if not state.mic_standby:
                manager.close_input_stream()

        if discard:
            # The worker may already be decoding. It owns task_done for that
            # job; the invalidated recording ID prevents it publishing.
            discard_pending_jobs(state.transcription_queue)
            _clear_transcript()
            manager.discard_recording()
            with _overlay_session_lock:
                if _overlay_session is not None:
                    _overlay_session.discard()
            return

        _set_overlay_state("processing")
        try:
            if localvoice_config.sounds():
                play_stop_beep()
        except Exception:
            logger.warning("Could not play the stop sound.")
        _resume_playback()
        playback_resumed = True

        if _streaming_model is not None:
            manager.finish_streaming()
            state.transcription_queue.put(
                TranscriptionJob(recording_id, "stream-finish", backend=_streaming_model)
            )
        else:
            # Earlier segments and an in-flight preview finish first (the
            # worker is serial, so the tail could not have started sooner);
            # that preview may already be the tail's transcript.
            state.transcription_queue.join()
            manager.finish_recording()
        state.transcription_queue.join()

        final_text = " ".join(state.transcribed_chunks).strip()
        if final_text:
            duration = time.monotonic() - state.recording_start_time if state.recording_start_time else 0.0
            _deliver_transcript(final_text, duration)
            if state.failed_recording_id == recording_id:
                _set_overlay_detail("Some audio could not be transcribed")
        elif state.failed_recording_id == recording_id:
            _set_overlay_state("failed")
        else:
            _set_overlay_state("empty")
    finally:
        if not playback_resumed:
            _resume_playback()
        state.recording_start_time = None
        _streaming_model = None
        _release_session_lock()


def _deliver_transcript(text, duration):
    copied = False
    try:
        copied = copy_to_clipboard(text)
        if copied:
            # Never send Cmd+V unless the new transcript reached the clipboard.
            _set_overlay_state("success" if paste_from_clipboard() else "clipboard")
        elif type_text(text):
            _set_overlay_detail("Typed — clipboard unavailable")
            _set_overlay_state("success")
        else:
            _set_overlay_detail("Clipboard unavailable")
            _set_overlay_state("empty")
    except Exception:
        logger.warning("Could not insert the transcript.")
        _set_overlay_state("clipboard" if copied else "empty")

    # History is an explicit storage surface, independent of generic output.
    if state.history_enabled:
        try:
            # The upstream helper logs raw database exceptions and result
            # lengths; neither is needed to report a failed save.
            with quiet_content_logger(logging.getLogger("ctrlspeak.history")):
                entry = get_history_manager(state.history_db_path).add_entry(
                    text=text, model=state.model_type,
                    duration_seconds=duration, language=state.source_lang,
                )
            if entry is None:
                logger.error("Failed to save to history.")
        except Exception:
            logger.error("Failed to save to history.")
