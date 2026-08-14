"""Microphone capture, isolated in its own process.

CoreAudio's HAL deadlocks in the stream teardown path, and a mutex wedged
inside our own process cannot be broken from Python — that is what repeatedly
took dictation down for good. Owning the stream in a child process turns the
problem into a solved one: releasing the microphone becomes killing a process,
which the kernel always honours, immediately and without a teardown of our own.

The child does nothing but capture. Silence detection, buffering and the onset
roll stay in the parent, fed by the raw frames this writes to stdout.

Usage: mic_capture.py <samplerate> <channels> <blocksize> [device]
Frames are little-endian float32, blocksize * channels values per block.
"""

import queue
import sys
import threading


def main():
    samplerate = int(sys.argv[1])
    channels = int(sys.argv[2])
    blocksize = int(sys.argv[3])
    device = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] != "-" else None
    if device is not None:
        try:
            device = int(device)
        except ValueError:
            pass

    import numpy as np
    import sounddevice as sd

    # The audio callback must never block, so it hands blocks to a writer
    # thread. Bounded, because a stalled reader must cost us the oldest audio
    # rather than unbounded memory.
    blocks = queue.Queue(maxsize=256)

    def callback(indata, frames, time_info, status):
        if status:
            print(f"status: {status}", file=sys.stderr, flush=True)
        try:
            blocks.put_nowait(bytes(indata))
        except queue.Full:
            pass

    def writer():
        out = sys.stdout.buffer
        while True:
            block = blocks.get()
            if block is None:
                return
            try:
                out.write(block)
                out.flush()
            except (BrokenPipeError, ValueError):
                # Parent is gone; nothing left to capture for.
                return

    try:
        stream = sd.InputStream(
            device=device,
            samplerate=samplerate,
            channels=channels,
            blocksize=blocksize,
            dtype=np.float32,
            callback=callback,
        )
        stream.start()
    except Exception as exc:
        print(f"open-failed: {exc}", file=sys.stderr, flush=True)
        return 1

    # Announced on stderr so the parent can tell "capturing" from "still
    # opening" without guessing from the frame stream.
    print("ready", file=sys.stderr, flush=True)

    thread = threading.Thread(target=writer, name="mic-writer", daemon=True)
    thread.start()
    thread.join()
    return 0


if __name__ == "__main__":
    sys.exit(main())
