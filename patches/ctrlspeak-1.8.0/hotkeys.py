"""
Hotkey activation handler for ctrlSPEAK.

Handles triple-tap Ctrl activation and routes to either:
- Streaming mode: For models that support real-time streaming (e.g., Nemotron)
- Queue mode: For models that use batch transcription (e.g., Parakeet, Canary)
"""

import logging
import math
import os
import queue
import subprocess
import threading
import time
import state
from utils import localvoice_config
from utils import media_pause
from utils.clipboard import copy_to_clipboard, paste_from_clipboard, type_text
from utils.player import play_start_beep, play_stop_beep
from utils.history import get_history_manager
import streaming

logger = logging.getLogger("ctrlspeak.hotkeys")

# Track which mode we're in for the current recording session
_current_session_streaming = False

# Set while an Esc-cancel is tearing the session down, so the transcript that
# still comes out of the worker is thrown away instead of pasted.
_session_cancelled = False

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

# Generous enough for a long recording's transcription (a 30 s clip decodes
# in about a second), short enough that a wedge does not cost the morning.
WATCHDOG_TIMEOUT_S = 90.0

# How long the microphone stays open after a recording. Zero — release it at
# once, so the macOS indicator tracks dictation exactly. The delay existed to
# avoid cycling CoreAudio's teardown, where the HAL deadlocks; capture now
# lives in a child process and releasing is a kill, so there is nothing left
# to avoid. Raise it only to shave the ~0.15 s respawn off back-to-back
# dictations, at the cost of an indicator that outstays its recording.
MIC_IDLE_CLOSE_S = 0.0
_mic_close_timer = None
_mic_timer_lock = threading.Lock()


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
        time.sleep(1.0)

        started = _command_started_at
        if started is None:
            continue

        elapsed = time.monotonic() - started
        if elapsed < WATCHDOG_TIMEOUT_S:
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
        try:
            handler()
        except Exception as exc:
            logger.error(f"Hotkey command '{name}' failed: {exc}", exc_info=True)
        finally:
            _command_started_at = None
            _command_name = None


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


def _cancel_mic_close():
    """Stop a pending teardown, so a new recording reuses the open stream."""
    global _mic_close_timer

    with _mic_timer_lock:
        if _mic_close_timer is not None:
            _mic_close_timer.cancel()
            _mic_close_timer = None


def _schedule_mic_close():
    """Release the microphone: at once, or after the configured idle time."""
    global _mic_close_timer

    if MIC_IDLE_CLOSE_S <= 0:
        state.audio_manager.close_input_stream()
        return

    def _close_if_idle():
        global _mic_close_timer

        with _mic_timer_lock:
            _mic_close_timer = None

        if is_recording():
            return

        logger.info("Microphone idle; releasing the input stream.")
        state.audio_manager.close_input_stream()

    with _mic_timer_lock:
        if _mic_close_timer is not None:
            _mic_close_timer.cancel()

        _mic_close_timer = threading.Timer(MIC_IDLE_CLOSE_S, _close_if_idle)
        _mic_close_timer.name = "ctrlspeak-mic-idle-close"
        _mic_close_timer.daemon = True
        _mic_close_timer.start()


class _OverlaySession:
    """Own a persistent recorder HUD and feed it microphone levels."""

    def __init__(self, language):
        self.language = language
        self.commands = queue.Queue()
        self.thread = threading.Thread(
            target=self._run,
            name="ctrlspeak-overlay",
            daemon=True,
        )

    def start(self):
        self.thread.start()

    def set_state(self, overlay_state):
        self.commands.put(f"state {overlay_state}")

    def set_detail(self, text):
        """Set the pill's secondary line. Newlines would desync the protocol."""
        self.commands.put("detail " + " ".join(str(text).split()))

    def close(self):
        self.commands.put("quit")

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

    @staticmethod
    def _read_events(process):
        """Apply interaction events emitted by the native recorder HUD."""
        try:
            for line in process.stdout:
                parts = line.strip().split()
                if len(parts) == 2 and parts[0] == "language":
                    _apply_language(parts[1])
        except OSError as exc:
            logger.warning(f"Could not read recorder overlay events: {exc}")

    def _run(self):
        process = None
        mode = "recording"
        terminal_deadline = None

        try:
            process = subprocess.Popen(
                [_OVERLAY_PATH, "recording", self.language],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            threading.Thread(
                target=self._read_events,
                args=(process,),
                name="ctrlspeak-overlay-events",
                daemon=True,
            ).start()
            logger.info("Animated recorder overlay started")

            while process.poll() is None:
                try:
                    command = self.commands.get(timeout=0.04)
                except queue.Empty:
                    command = None

                if command:
                    self._write(process, command)

                    if command == "quit":
                        break

                    if command.startswith("state "):
                        mode = command.split(" ", 1)[1]
                        if mode in {"success", "empty", "cancelled", "clipboard"}:
                            terminal_deadline = time.monotonic() + 3.0

                if mode == "recording":
                    self._write(process, f"level {self._normalized_level():.4f}")

                if terminal_deadline and time.monotonic() >= terminal_deadline:
                    break

        except (BrokenPipeError, OSError) as exc:
            logger.warning(f"Recorder overlay stopped unexpectedly: {exc}")
        finally:
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


def _start_recording_overlay():
    """Start a fresh persistent overlay for this recording session."""
    global _overlay_session

    with _overlay_session_lock:
        if _overlay_session is not None:
            _overlay_session.close()

        _overlay_session = _OverlaySession(state.source_lang)
        _overlay_session.start()


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


def _apply_language(language, persist=True):
    """Apply a language selected in the recorder HUD or edited in the config.

    persist=False is for changes that already come *from* the config file;
    writing them back would touch its mtime and ping the watcher again.
    """
    language = language.lower()
    if language not in localvoice_config.VALID_LANGUAGES:
        logger.warning(f"Ignoring unsupported language from recorder overlay: {language}")
        return

    with _language_lock:
        state.source_lang = language
        state.target_lang = language

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


def _start_queue_recording():
    """Start recording in queue-based mode (original behavior)."""
    logger.info("Starting queue-based recording session...")

    state.transcribed_chunks.clear()
    logger.info("Cleared previous transcribed chunks.")

    # Reset accumulated text for UI
    if hasattr(state, 'app_state_ref') and state.app_state_ref:
        state.app_state_ref.accumulated_text = ""

    state.audio_manager.start_recording()


def _stop_queue_recording():
    """Stop queue-based recording and wait for transcription."""
    logger.info("Stopping queue-based recording session...")

    state.audio_manager.stop_recording()

    logger.info("Waiting for transcription worker to finish processing queue...")
    state.transcription_queue.join()
    logger.info("Transcription queue processed.")

    final_text = " ".join(state.transcribed_chunks).strip()
    return final_text


def is_recording():
    """Whether a recording session is currently collecting audio."""
    return state.audio_manager is not None and state.audio_manager.is_collecting


def cancel_recording():
    """Queue a discard of the running session (called from the event tap)."""
    if not is_recording():
        return True

    return _dispatch("cancel", _perform_cancel)


def _perform_cancel():
    global _session_cancelled

    if not is_recording():
        return

    logger.info("Recording cancelled via Esc.")
    _session_cancelled = True
    try:
        _set_overlay_state("cancelled")
        # The audio pipeline still runs to completion so the worker queue
        # stays consistent; _perform_activate sees the flag and drops the text.
        _perform_activate()
    finally:
        _session_cancelled = False


def finish_recording():
    """Queue a stop-and-insert (called from the event tap)."""
    if not is_recording():
        return True

    logger.info("Recording finished via Enter.")
    return _dispatch("finish", _perform_activate)


def on_activate():
    """Queue a hotkey activation (called from the event tap)."""
    return _dispatch("activate", _perform_activate)


def _perform_activate():
    """Start or stop a recording session.

    Runs on the hotkey worker thread, never on the event tap.
    """
    global _current_session_streaming

    if not state.audio_manager.is_collecting:
        # =================================================================
        # START RECORDING
        # =================================================================

        # Check if model is being swapped
        if hasattr(state, 'app_state_ref') and state.app_state_ref:
            if state.app_state_ref.is_loading_model:
                logger.warning("Cannot record while model is loading")
                state.console.print("[yellow]Please wait for model to finish loading...[/yellow]")
                return

        if not state.model_loaded:
            state.console.print("[bold yellow]Model is still loading. Please wait...[/bold yellow]")
            return

        # Silence the room first: a playing Spotify or Music is paused before
        # the microphone opens, so no music tail leaks into the recording and
        # nothing competes with the dictation. Resumed on stop.
        if localvoice_config.as_bool("pause-media"):
            media_pause.pause_playing()

        # On-demand microphone: open the stream for this session, so the
        # macOS mic indicator lights up around recordings rather than always.
        # A pending idle teardown is cancelled first — reusing a still-open
        # stream is both faster and one less trip through CoreAudio's teardown.
        if not state.mic_standby:
            _cancel_mic_close()
            try:
                state.audio_manager.open_input_stream()
            except Exception as exc:
                logger.error(f"Could not open the microphone stream: {exc}")
                state.console.print("[bold red]Could not open the microphone.[/bold red]")
                _set_overlay_detail("Microphone unavailable")
                _set_overlay_state("empty")
                media_pause.resume_paused()
                return

        # Track recording start time for history (stored in state for thread safety)
        state.recording_start_time = time.time()

        # Recording starts before the beep: the beep is a "go" signal, and
        # anything said while it plays is already being captured.
        if streaming.is_model_streaming_capable():
            logger.info("Using STREAMING mode (model supports streaming)")
            _current_session_streaming = True
            streaming.start_streaming()
        else:
            logger.info("Using QUEUE mode (batch transcription)")
            _current_session_streaming = False
            _start_queue_recording()

        play_start_beep()
        _start_recording_overlay()

    else:
        # =================================================================
        # STOP RECORDING
        # =================================================================

        logger.info("Stop activated. Stopping audio recording...")
        play_stop_beep()
        # Music comes back right away, not after transcription: the recording
        # is over the moment the stop beep plays.
        media_pause.resume_paused()
        if not _session_cancelled:
            _set_overlay_state("processing")

        # Use the mode we started with
        if _current_session_streaming:
            final_text = streaming.stop_streaming()
        else:
            final_text = _stop_queue_recording()

        if not state.mic_standby:
            _schedule_mic_close()

        if _session_cancelled:
            # The pill already shows "cancelled"; the transcript is discarded.
            logger.info("Session was cancelled; discarding transcription result.")
            state.transcribed_chunks.clear()
            state.recording_start_time = None
            _current_session_streaming = False
            return

        # Handle final text
        if final_text:
            # Calculate recording duration
            duration_seconds = 0.0
            if state.recording_start_time:
                duration_seconds = time.time() - state.recording_start_time
                state.recording_start_time = None  # Reset for next recording

            logger.info(f"Final text ({len(final_text)} chars): {final_text[:100]}...")
            copied = copy_to_clipboard(final_text)
            # Pasting means pressing Cmd+V, which would deliver whatever the
            # clipboard still held from before — so only paste what we put there.
            pasted = paste_from_clipboard() if copied else False

            if copied:
                # No text field in focus: the transcript is on the clipboard,
                # and the pill says so instead of claiming an insertion that
                # never was.
                _set_overlay_state("success" if pasted else "clipboard")
            elif type_text(final_text):
                # Clipboard unreachable, but the text still got there. Say how,
                # because the paste-vs-typed distinction matters in apps that
                # mangle synthetic keystrokes.
                _set_overlay_detail("Typed — clipboard unavailable")
                _set_overlay_state("success")
            else:
                # Nothing could take the text. Name the reason and pick a state
                # that dismisses itself; a pill left standing is what made this
                # look like a dead app before. The transcript is still written
                # to the log and to history below.
                _set_overlay_detail("Clipboard unavailable")
                _set_overlay_state("empty")

            state.console.print("\n[bold cyan]Transcription:[/bold cyan]")
            state.console.print(final_text)

            # Save to history (if enabled)
            if state.history_enabled:
                try:
                    history = get_history_manager(state.history_db_path)
                    history.add_entry(
                        text=final_text,
                        model=state.model_type,
                        duration_seconds=duration_seconds,
                        language=state.source_lang
                    )
                except Exception as e:
                    logger.error(f"Failed to save to history: {e}", exc_info=True)
        else:
            state.console.print("[yellow]No transcription result[/yellow]")
            _set_overlay_state("empty")

        # Reset session state
        _current_session_streaming = False
