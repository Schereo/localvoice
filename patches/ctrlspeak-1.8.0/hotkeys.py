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
from utils.clipboard import copy_to_clipboard, paste_from_clipboard
from utils.player import play_start_beep, play_stop_beep
from utils.history import get_history_manager
import streaming

logger = logging.getLogger("ctrlspeak.hotkeys")

# Track which mode we're in for the current recording session
_current_session_streaming = False

_OVERLAY_PATH = os.environ.get(
    "CTRLSPEAK_OVERLAY_PATH",
    "/opt/homebrew/bin/ctrlspeak-overlay",
)
_overlay_session = None
_overlay_session_lock = threading.Lock()


class _OverlaySession:
    """Own a persistent recorder HUD and feed it microphone levels."""

    def __init__(self):
        self.commands = queue.Queue()
        self.thread = threading.Thread(
            target=self._run,
            name="ctrlspeak-overlay",
            daemon=True,
        )

    def start(self):
        self.thread.start()

    def set_state(self, overlay_state):
        self.commands.put(overlay_state)

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

    def _run(self):
        process = None
        mode = "recording"
        terminal_deadline = None

        try:
            process = subprocess.Popen(
                [_OVERLAY_PATH, "recording"],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            logger.info("Animated recorder overlay started")

            while process.poll() is None:
                try:
                    command = self.commands.get(timeout=0.04)
                except queue.Empty:
                    command = None

                if command:
                    self._write(process, command if command == "quit" else f"state {command}")

                    if command == "quit":
                        break

                    mode = command
                    if command in {"success", "empty"}:
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

        _overlay_session = _OverlaySession()
        _overlay_session.start()


def _set_overlay_state(overlay_state):
    """Transition the current overlay without recreating its window."""
    with _overlay_session_lock:
        if _overlay_session is not None:
            _overlay_session.set_state(overlay_state)


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

        # Play start beep
        play_start_beep()

        # Track recording start time for history (stored in state for thread safety)
        state.recording_start_time = time.time()

        # Determine if we should use streaming mode
        if streaming.is_model_streaming_capable():
            logger.info("Using STREAMING mode (model supports streaming)")
            _current_session_streaming = True
            streaming.start_streaming()
        else:
            logger.info("Using QUEUE mode (batch transcription)")
            _current_session_streaming = False
            _start_queue_recording()

        _start_recording_overlay()

    else:
        # =================================================================
        # STOP RECORDING
        # =================================================================

        logger.info("Stop activated. Stopping audio recording...")
        play_stop_beep()
        _set_overlay_state("processing")

        # Use the mode we started with
        if _current_session_streaming:
            final_text = streaming.stop_streaming()
        else:
            final_text = _stop_queue_recording()

        # Handle final text
        if final_text:
            # Calculate recording duration
            duration_seconds = 0.0
            if state.recording_start_time:
                duration_seconds = time.time() - state.recording_start_time
                state.recording_start_time = None  # Reset for next recording

            logger.info(f"Final text ({len(final_text)} chars): {final_text[:100]}...")
            copy_to_clipboard(final_text)
            paste_from_clipboard()
            _set_overlay_state("success")

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
