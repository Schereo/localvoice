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
from contextlib import contextmanager
from pathlib import Path

from overlay import StatusOverlay

logger = logging.getLogger("ctrlspeak.model_download")

POLL_SECONDS = 0.5


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
    """Feed download progress to the pill until the download finishes."""
    blob_dir = _repo_cache_dir(repo_id)
    baseline = _local_bytes(blob_dir)

    # Fetched here rather than by the caller so a slow or offline metadata
    # lookup never delays the download itself.
    total = _remote_total_bytes(repo_id)
    model_label = repo_id.split("/")[-1]

    while not stop_event.is_set():
        downloaded = _local_bytes(blob_dir)

        if total:
            overlay.set_progress(downloaded / total)
            overlay.set_detail(f"{model_label} · {_format_size(downloaded)} of {_format_size(total)}")
        else:
            overlay.set_progress(None)
            overlay.set_detail(f"{model_label} · {_format_size(max(0, downloaded - baseline))} downloaded")

        stop_event.wait(POLL_SECONDS)


@contextmanager
def download_progress(repo_id, language="de"):
    """Show a download pill while the wrapped block fetches the model."""
    if is_cached(repo_id):
        yield
        return

    logger.info(f"{repo_id} is not cached; showing download progress")

    overlay = StatusOverlay("download", language).start()
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
