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
from pathlib import Path
import state
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
_LANGUAGE_FILE = Path(
    os.environ.get(
        "CTRLSPEAK_LANGUAGE_FILE",
        str(Path.home() / ".config" / "ctrlspeak" / "language"),
    )
)
_overlay_session = None
_overlay_session_lock = threading.Lock()
_language_lock = threading.Lock()


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


def _save_language(language):
    """Persist the language atomically for the next service launch."""
    _LANGUAGE_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary_file = _LANGUAGE_FILE.with_suffix(".tmp")
    temporary_file.write_text(language + "\n", encoding="utf-8")
    os.replace(temporary_file, _LANGUAGE_FILE)


def _apply_language(language):
    """Apply and persist a language selected in the recorder HUD."""
    language = language.lower()
    if language not in {"de", "en", "auto"}:
        logger.warning(f"Ignoring unsupported language from recorder overlay: {language}")
        return

    with _language_lock:
        state.source_lang = language
        state.target_lang = language

        if hasattr(state, "app_state_ref") and state.app_state_ref:
            state.app_state_ref.source_lang = language
            state.app_state_ref.target_lang = language

        try:
            _save_language(language)
        except OSError as exc:
            logger.warning(f"Could not persist language preference: {exc}")

    logger.info(f"Forced transcription language changed to: {language}")


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
    """Discard the running recording session without inserting anything."""
    global _session_cancelled

    if not is_recording():
        return True

    logger.info("Recording cancelled via Esc.")
    _session_cancelled = True
    try:
        _set_overlay_state("cancelled")
        # The audio pipeline still runs to completion so the worker queue
        # stays consistent; on_activate sees the flag and drops the text.
        on_activate()
    finally:
        _session_cancelled = False
    return True


def finish_recording():
    """Stop the running recording session and insert the transcript."""
    if not is_recording():
        return True

    logger.info("Recording finished via Enter.")
    return on_activate()


def on_activate():
    """Handle global hotkey activation.

    Routes to streaming or queue-based mode depending on model capabilities.
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

        # On-demand microphone: open the stream for this session only, so
        # the macOS mic indicator lights up during recordings, not always.
        if not state.mic_standby:
            try:
                state.audio_manager.open_input_stream()
            except Exception as exc:
                logger.error(f"Could not open the microphone stream: {exc}")
                state.console.print("[bold red]Could not open the microphone.[/bold red]")
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
        if not _session_cancelled:
            _set_overlay_state("processing")

        # Use the mode we started with
        if _current_session_streaming:
            final_text = streaming.stop_streaming()
        else:
            final_text = _stop_queue_recording()

        if not state.mic_standby:
            state.audio_manager.close_input_stream()

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

            # In automatic mode the choice is the model's, so name it rather
            # than leaving the user to infer it from the transcript.
            if state.source_lang == "auto" and state.last_detected_language:
                _set_overlay_detail(f"Detected {state.last_detected_language.upper()}")

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
