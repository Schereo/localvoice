from contextlib import contextmanager
import logging
import queue
import sys
import tempfile
import threading
import warnings

import numpy as np
import soundfile as sf

import state
from utils.audio import SAMPLE_RATE

warnings.filterwarnings('ignore', category=RuntimeWarning, module='tqdm')
logger = logging.getLogger("ctrlspeak")


@contextmanager
def quiet_content_logger(target):
    """Suppress an upstream logger on this thread, not on unrelated threads."""
    if not isinstance(target, logging.Logger):
        yield
        return

    thread_id = threading.get_ident()

    def other_threads_only(_record):
        return threading.get_ident() != thread_id

    target.addFilter(other_threads_only)
    try:
        yield
    finally:
        target.removeFilter(other_threads_only)


def discard_pending_jobs(work_queue):
    """Drop waiting jobs after all producers have stopped; keep shutdown intact."""
    while True:
        try:
            job = work_queue.get_nowait()
        except queue.Empty:
            return
        try:
            if job is None:
                work_queue.put(None)
                return
        finally:
            work_queue.task_done()


def _transcribe_audio(model, audio):
    if not len(audio):
        return None
    samples = audio.astype(np.float32, copy=False)
    # The capture pipe exposes mono frames as (frames, 1). In-memory ASR
    # consumes (frames,), unlike the old WAV writer which accepted both.
    if samples.ndim == 2 and samples.shape[1] == 1:
        samples = samples[:, 0]
    if samples.ndim != 1:
        raise ValueError("Transcription requires mono PCM.")
    transcribe_pcm = getattr(model, "transcribe_pcm", None)
    if callable(transcribe_pcm):
        return transcribe_pcm(samples, state.source_lang, state.target_lang)
    # The context owns cleanup on success, failure, and a cancelled decode.
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        sf.write(tmp.name, samples, SAMPLE_RATE)
        results = model.transcribe_batch(
            [tmp.name], source_lang=state.source_lang, target_lang=state.target_lang
        )
        if results and isinstance(results, list):
            return results[0]
    return None


def _is_current(manager, job):
    if job.recording_id != manager.recording_id:
        return False
    if job.kind == "preview":
        # Also runs without the live preview: a decode at the speaker's
        # pause that the segment may reuse (hotkeys._segment_ticker).
        return manager.is_collecting and job.preview_segment == manager.segments_queued
    return True


def _run_job(model, job, results_list):
    manager = state.audio_manager
    if manager is None:
        return

    with manager.capture_lock:
        if not _is_current(manager, job):
            return

    language = state.source_lang
    backend = job.backend if job.backend is not None else model
    # Legacy upstream backends may log raw results and exception payloads.
    module = type(backend).__module__
    backend_logger = None
    if module.startswith("models.") and module != "models.whisper_mlx":
        backend_logger = getattr(sys.modules.get(module), "logger", None)
    with quiet_content_logger(backend_logger):
        if job.kind == "stream-start":
            backend.init_streaming()
            return
        if job.kind == "resolved":
            text = job.text
        elif job.kind == "stream-finish":
            text = backend.finalize_streaming()
        elif job.kind == "stream":
            text = backend.stream_chunk(job.audio, is_final=job.is_final)
        else:
            text = _transcribe_audio(backend, job.audio)

    # Checking and publishing together prevents Esc or the next recording
    # from landing between the check and a late result/preview update.
    with manager.capture_lock:
        if (job.kind == "preview" and job.preview_chunks >= 0
                and job.recording_id == manager.recording_id
                and job.preview_segment == manager.segments_queued
                and language == state.source_lang):
            # Kept even when stop froze capture mid-decode: this may be the
            # finished transcript of the segment (AudioManager._queue_segment).
            state.last_preview = (job.recording_id, job.preview_segment, job.preview_chunks, text or "")
        if not _is_current(manager, job):
            return
        if job.kind == "preview":
            if text and state.live_preview_active:
                from hotkeys import set_overlay_transcript

                set_overlay_transcript(partial=text)
        elif job.kind == "stream-finish":
            results_list[:] = [text] if text else []
        elif job.kind == "stream":
            if text:
                results_list[:] = [text]
                if getattr(state, "app_state_ref", None):
                    state.app_state_ref.accumulated_text = text
                if manager.is_collecting and state.live_preview_active:
                    from hotkeys import set_overlay_transcript

                    set_overlay_transcript(partial=text)
        elif text:
            results_list.append(text)
            if manager.is_collecting and state.live_preview_active:
                from hotkeys import set_overlay_transcript

                set_overlay_transcript(final=" ".join(results_list).strip(), partial="")


def transcription_worker(model, work_queue, results_list, source_lang, target_lang):
    """Decode queued audio until shutdown. Each dequeued job is counted once."""
    # MLX streams are thread-local; load weights in the inference thread.
    if (model.__class__.__name__ in {"ParakeetMLXModel", "WhisperMLXModel"}
            or getattr(model, "deferred_load", False) is True):
        logger.info("Initializing model in the transcription worker thread...")
        model.load_model()
        state.model_loaded = True
        logger.info("Worker model initialization complete. Ready to record.")

    while True:
        job = work_queue.get()
        try:
            if job is None:
                return
            _run_job(model, job, results_list)
        except Exception as exc:
            logger.error("Transcription job failed (%s).", type(exc).__name__)
            manager = state.audio_manager
            if manager is not None and job.kind != "preview":
                with manager.capture_lock:
                    if _is_current(manager, job):
                        state.failed_recording_id = job.recording_id
        finally:
            work_queue.task_done()
            job = None  # Do not keep the last audio alive while idle.
