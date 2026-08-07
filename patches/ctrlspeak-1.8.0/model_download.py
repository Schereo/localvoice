"""Report first-run model downloads in the native pill.

mlx-whisper pulls its weights through huggingface_hub's snapshot_download,
which writes its progress bars to stderr — invisible under a LaunchAgent, and
a 1.6-GB download otherwise looks like ctrlSPEAK is simply hanging on startup.

Rather than hooking into hub internals, this watches the blob directory the
download writes into. Partial files carry an ".incomplete" suffix and are
counted too, so the bar tracks bytes actually on disk.
"""

import logging
import threading
import time
from collections import deque
from contextlib import contextmanager
from pathlib import Path

from overlay import FifoStatusOverlay, StatusOverlay, close_startup_pill

logger = logging.getLogger("ctrlspeak.model_download")

POLL_SECONDS = 0.25


def _repo_cache_dir(repo_id):
    """Return the blob directory huggingface_hub uses for this repo."""
    from huggingface_hub.constants import HF_HUB_CACHE

    return Path(HF_HUB_CACHE) / f"models--{repo_id.replace('/', '--')}" / "blobs"


def is_cached(repo_id):
    """True when the repo is complete on disk and no download will happen."""
    try:
        from huggingface_hub import snapshot_download

        snapshot_download(repo_id=repo_id, local_files_only=True)
        return True
    except Exception:
        return False


def _remote_total_bytes(repo_id):
    """Total size of the repo, or None when the metadata call fails."""
    try:
        from huggingface_hub import HfApi

        info = HfApi().model_info(repo_id, files_metadata=True)
        total = sum((getattr(sibling, "size", None) or 0) for sibling in info.siblings or [])
        return total or None
    except Exception as exc:
        logger.debug(f"Could not read remote size for {repo_id}: {exc}")
        return None


def _local_bytes(blob_dir):
    """Bytes on disk for this repo, counting in-flight ".incomplete" blobs."""
    total = 0
    try:
        for entry in blob_dir.iterdir():
            try:
                total += entry.stat().st_size
            except OSError:
                continue
    except OSError:
        return 0

    return total


def _format_size(num_bytes):
    if num_bytes >= 1_000_000_000:
        return f"{num_bytes / 1_000_000_000:.1f} GB"
    if num_bytes >= 1_000_000:
        return f"{num_bytes / 1_000_000:.0f} MB"
    return f"{num_bytes / 1_000:.0f} KB"


def _watch(repo_id, overlay, stop_event):
    """Feed download progress to the pill until the download finishes.

    The filesystem is a bursty witness: the Xet backend materialises the file
    in chunk batches of tens of MB, so raw samples sit still and then leap.
    What the pill shows is therefore a modelled counter — it advances every
    tick at the estimated rate and is gently pulled toward the latest sample,
    never backward and never more than a few seconds ahead of the evidence.
    """
    blob_dir = _repo_cache_dir(repo_id)

    # Fetched here rather than by the caller so a slow or offline metadata
    # lookup never delays the download itself.
    total = _remote_total_bytes(repo_id)
    model_label = repo_id.split("/")[-1]

    samples = deque()
    first_raw = None
    displayed = None
    rate = 0.0
    last_tick = None

    while not stop_event.is_set():
        raw = _local_bytes(blob_dir)
        now = time.monotonic()

        if first_raw is None:
            first_raw = raw
            displayed = float(raw)

        samples.append((now, raw))
        while len(samples) > 2 and now - samples[0][0] > 20.0:
            samples.popleft()

        # Rate over the whole 20 s window, then an EMA on top: the window
        # bridges the gaps between chunk batches, the EMA irons out the edge
        # where a batch enters or leaves the window.
        window_elapsed = now - samples[0][0]
        if window_elapsed >= 1.0:
            window_rate = max(0.0, (raw - samples[0][1]) / window_elapsed)
            rate = window_rate if rate == 0.0 else rate * 0.85 + window_rate * 0.15

        if last_tick is not None:
            advanced = displayed + rate * (now - last_tick)
            corrected = advanced + (raw - advanced) * 0.03
            bounded = min(corrected, raw + rate * 4.0)
            displayed = max(displayed, bounded)
        last_tick = now

        # Shown steadily rather than gated on recent movement — an EMA fades
        # over seconds during a real stall instead of flickering per sample.
        rate_text = f" · {rate / 1_000_000:.1f} MB/s" if rate >= 200_000 else ""

        if total:
            displayed = min(displayed, float(total))
            overlay.set_progress(displayed / total)
            overlay.set_detail(f"{_format_size(int(displayed))} of {_format_size(total)}{rate_text}")
        else:
            overlay.set_progress(None)
            gained = max(0, int(displayed) - first_raw)
            overlay.set_detail(f"{model_label} · {_format_size(gained)}{rate_text}")

        stop_event.wait(POLL_SECONDS)


@contextmanager
def download_progress(repo_id, language="de"):
    """Show a download pill while the wrapped block fetches the model."""
    if is_cached(repo_id):
        # The wrapper may have opened a startup pill on a stale cache check;
        # nothing will feed it, so dismiss it.
        close_startup_pill()
        yield
        return

    logger.info(f"{repo_id} is not cached; showing download progress")

    # Prefer the pill the service wrapper already has on screen; only spawn a
    # fresh one when there is none (e.g. the model vanished mid-session).
    overlay = FifoStatusOverlay().start() or StatusOverlay("download", language).start()
    stop_event = threading.Event()
    watcher = threading.Thread(
        target=_watch,
        args=(repo_id, overlay, stop_event),
        name="ctrlspeak-download-progress",
        daemon=True,
    )
    watcher.start()

    try:
        yield
    finally:
        stop_event.set()
        watcher.join(timeout=POLL_SECONDS * 4)
        overlay.close()
