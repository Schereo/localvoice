"""Verified local Parakeet inference over a private, persistent Core ML worker."""

import base64
import json
import os
from pathlib import Path
import select
import subprocess
import threading
import time


VARIANTS = {
    "parakeet-v3": "v3",
    "parakeet-ultra": "ultra",
    "parakeet-redux": "redux",
}
NEMOTRON = "nemotron-streaming"
MAX_SAMPLES = 30 * 16_000
MAX_REPLY = 1024 * 1024


class ParakeetCoreMLModel:
    supports_streaming = False
    supports_forced_language = False
    deferred_load = True

    def __init__(self, model_id, model_path, worker=None):
        self.variant = "nemotron" if model_id == NEMOTRON else VARIANTS[model_id]
        self.model_path = Path(model_path)
        self.worker = Path(worker or os.environ.get("LOCALVOICE_PARAKEET_WORKER", ""))
        self.process = None
        self._pending = bytearray()
        self._guard = threading.Lock()
        self._closed = False

    def load_model(self):
        with self._guard:
            if self._closed:
                raise RuntimeError("The Parakeet backend has closed.")
            if self.process is not None and self.process.poll() is None:
                return
            # A worker that crashed or was killed is replaced, not mourned.
            stale, self.process = self.process, None
            self._pending.clear()
            if not self.worker.is_absolute() or not self.worker.is_file() or not os.access(self.worker, os.X_OK):
                raise RuntimeError("The bundled Parakeet worker is unavailable.")
            if not self.model_path.is_absolute() or not self.model_path.is_dir():
                raise RuntimeError("The verified Parakeet directory is unavailable.")
            process = subprocess.Popen(
                [str(self.worker), self.variant, str(self.model_path)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
            )
            self.process = process
        if stale is not None:
            self._reap(stale)
        try:
            os.set_blocking(process.stdin.fileno(), False)
            if self._read(process, time.monotonic() + 110).get("event") != "ready":
                raise RuntimeError("The Parakeet worker could not load the model.")
        except BaseException:
            self._discard()
            raise

    @staticmethod
    def _wait(fd, deadline, *, write=False):
        remaining = max(0, deadline - time.monotonic())
        r, w, _ = select.select([] if write else [fd], [fd] if write else [], [], remaining)
        if not (w if write else r):
            raise TimeoutError("The Parakeet worker timed out.")

    def _read(self, process, deadline):
        fd = process.stdout.fileno()
        while True:
            end = self._pending.find(b"\n")
            if end >= 0:
                if end > MAX_REPLY:
                    raise RuntimeError("The Parakeet worker returned an oversized reply.")
                line = self._pending[:end]
                del self._pending[:end + 1]
                message = json.loads(line)
                if not isinstance(message, dict):
                    raise RuntimeError("The Parakeet worker returned an invalid reply.")
                return message
            if len(self._pending) > MAX_REPLY:
                raise RuntimeError("The Parakeet worker returned an oversized reply.")
            self._wait(fd, deadline)
            chunk = os.read(fd, 65536)
            if not chunk:
                raise RuntimeError("The Parakeet worker exited unexpectedly.")
            self._pending.extend(chunk)

    @staticmethod
    def _pcm(samples):
        if samples.ndim != 1 or len(samples) > MAX_SAMPLES:
            raise ValueError("The Core ML worker expects at most 30 seconds of mono PCM.")
        return base64.b64encode(samples.astype("<f4", copy=False).tobytes()).decode("ascii")

    def _exchange(self, request):
        process = self.process
        if process is None or process.poll() is not None:
            # The previous worker died or was dropped after an error. Start a
            # fresh one so one stall does not break every later dictation.
            self.load_model()
            process = self.process
            if process is None:
                raise RuntimeError("The Core ML worker is unavailable.")
        try:
            data = memoryview(json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n")
            fd = process.stdin.fileno()
            deadline = time.monotonic() + 45
            while data:
                self._wait(fd, deadline, write=True)
                try:
                    data = data[os.write(fd, data[:65536]):]
                except BlockingIOError:
                    continue
            reply = self._read(process, deadline)
        except (OSError, ValueError, RuntimeError):
            # The pipe may be out of sync; the next request respawns.
            self._discard()
            raise
        if reply.get("event") != "result" or not isinstance(reply.get("text"), str):
            raise RuntimeError("The Core ML worker could not complete the audio request.")
        return reply["text"].strip()

    def transcribe_pcm(self, samples, source_lang, target_lang):
        # Split long segments into equal parts. A fixed 30 s split can leave a
        # tail below FluidAudio's 0.3 s minimum, which fails the whole segment.
        count = -(-len(samples) // MAX_SAMPLES)
        if count == 0:
            return ""
        size = -(-len(samples) // count)
        chunks = (self._exchange({"pcm": self._pcm(samples[offset:offset + size])})
                  for offset in range(0, len(samples), size))
        return " ".join(filter(None, chunks))

    def _discard(self):
        """Stop the current worker; the next request starts a fresh one."""
        with self._guard:
            process, self.process = self.process, None
            self._pending.clear()
        if process is not None:
            self._reap(process)

    def close(self):
        with self._guard:
            self._closed = True
        self._discard()

    @staticmethod
    def _reap(process):
        try:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        finally:
            process.stdin.close()
            process.stdout.close()


class NemotronCoreMLModel(ParakeetCoreMLModel):
    supports_streaming = True
    supports_forced_language = True
    chunk_size_ms = 2240

    def init_streaming(self, language=None):
        if language is None:
            import state
            language = state.source_lang
        self._exchange({"command": "start", "language": language})

    def stream_chunk(self, samples, *, is_final=False):
        return self._exchange({"command": "chunk", "pcm": self._pcm(samples)})

    def finalize_streaming(self):
        return self._exchange({"command": "finish"})

    def transcribe_pcm(self, samples, source_lang, target_lang):
        self.init_streaming(source_lang)
        step = self.chunk_size_ms * 16
        for offset in range(0, len(samples), step):
            self.stream_chunk(samples[offset:offset + step])
        return self.finalize_streaming()
