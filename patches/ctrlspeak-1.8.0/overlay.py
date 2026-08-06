"""Shared control of the native recorder pill for non-recording status.

The recording session in hotkeys.py owns its own overlay because it has to
stream microphone levels. Everything else that wants the pill — the permission
gate and the first-run model download — goes through StatusOverlay here.
"""

import logging
import os
import subprocess
import threading

logger = logging.getLogger("ctrlspeak.overlay")

OVERLAY_PATH = os.environ.get(
    "CTRLSPEAK_OVERLAY_PATH",
    "/opt/homebrew/bin/ctrlspeak-overlay",
)


class StatusOverlay:
    """Show a single status in the pill until it is closed.

    Every method is best-effort: if the overlay binary is missing or the pill
    was dismissed, commands are dropped instead of raising. ctrlSPEAK has to
    stay usable without it.
    """

    def __init__(self, mode, language="de"):
        self.mode = mode
        self.language = language
        self._process = None
        self._lock = threading.Lock()

    def start(self):
        """Launch the pill; returns self so callers can chain."""
        with self._lock:
            if self._process is not None:
                return self

            try:
                self._process = subprocess.Popen(
                    [OVERLAY_PATH, self.mode, self.language],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    bufsize=1,
                )
                logger.info(f"Status overlay started in {self.mode} mode")
            except OSError as exc:
                logger.warning(f"Could not start the status overlay: {exc}")
                self._process = None

        return self

    def _write(self, command):
        with self._lock:
            process = self._process
            if process is None or process.stdin is None or process.poll() is not None:
                return

            try:
                process.stdin.write(command + "\n")
                process.stdin.flush()
            except (BrokenPipeError, OSError) as exc:
                logger.debug(f"Status overlay stopped accepting commands: {exc}")

    def set_state(self, overlay_state):
        self._write(f"state {overlay_state}")

    def set_progress(self, fraction):
        """Set completion from 0 to 1; None renders an indeterminate bar."""
        if fraction is None:
            self._write("progress -1")
        else:
            self._write(f"progress {max(0.0, min(1.0, fraction)):.4f}")

    def set_detail(self, text):
        """Set the secondary line. Newlines would desync the line protocol."""
        self._write("detail " + " ".join(str(text).split()))

    def close(self):
        with self._lock:
            process = self._process
            self._process = None

        if process is None:
            return

        try:
            if process.stdin is not None:
                try:
                    process.stdin.write("quit\n")
                    process.stdin.flush()
                except (BrokenPipeError, OSError):
                    pass

                try:
                    process.stdin.close()
                except OSError:
                    pass

            # The pill fades out before it exits, so give it a moment.
            try:
                process.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                process.terminate()
        except OSError as exc:
            logger.debug(f"Could not close the status overlay cleanly: {exc}")

    def __enter__(self):
        return self.start()

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False
