
import time
import os
import tempfile
import logging
import warnings
import numpy as np
import soundfile as sf
import state
from utils.audio import SAMPLE_RATE

# Suppress tqdm multiprocessing warnings (they're non-fatal but noisy)
# See TQDM_ISSUE_ANALYSIS.md for detailed explanation
warnings.filterwarnings('ignore', category=RuntimeWarning, module='tqdm')

logger = logging.getLogger("ctrlspeak")

# Marker for live-preview jobs on the transcription queue: a snapshot of the
# still-open segment, decoded only to feed the pill's dimmed guess. Real
# segments stay plain numpy arrays, so the queue format is unchanged for them.
PREVIEW_JOB = "live-preview"


def _transcribe_file(model, audio_data, temp_file_path):
    """Write one audio array to the temp WAV and decode it. Returns text or None."""
    if audio_data.dtype != np.float32:
        audio_data = audio_data.astype(np.float32)
    sf.write(temp_file_path, audio_data, SAMPLE_RATE)

    results = model.transcribe_batch(
        [temp_file_path],
        source_lang=state.source_lang,
        target_lang=state.target_lang,
    )
    if results and isinstance(results, list):
        return results[0]
    return None


def _handle_preview_job(model, audio_data, generation):
    """Decode a snapshot of the open segment and show it as the pill's guess.

    The generation stamp is the segment counter at snapshot time: once the
    audio manager has finalized that audio into a real segment, the snapshot
    is stale and decoding (or showing) it would race the confirmed line.
    Checked before the decode to skip wasted work, and again after, because
    the segment can close while the model runs.
    """
    manager = state.audio_manager

    def _stale():
        return (
            manager is None
            or not manager.is_collecting
            or generation != manager.segments_queued
            or not state.live_preview_active
        )

    if _stale():
        return

    temp_file_path = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            temp_file_path = tmp.name
        text = _transcribe_file(model, audio_data, temp_file_path)
    except Exception as exc:
        if "fds_to_keep" not in str(exc):
            logger.warning(f"Live preview decode failed: {exc}")
        return
    finally:
        if temp_file_path and os.path.exists(temp_file_path):
            try:
                os.unlink(temp_file_path)
            except OSError:
                pass

    if text and not _stale():
        from hotkeys import set_overlay_transcript

        set_overlay_transcript(partial=text)


def transcription_worker(model, work_queue, results_list, source_lang, target_lang):
    """
    Pulls audio data from queue, transcribes using the real model (via temp file),
    adds text to results_list. Runs in a separate thread until None is received.
    """
    logger.debug("Transcription worker thread started.")

    # MLX 0.32 streams are thread-local. Inference happens here, so model
    # weights are loaded in this worker to keep the MLX graph and stream on
    # the same thread.
    if model.__class__.__name__ in {"ParakeetMLXModel", "WhisperMLXModel"}:
        logger.info("Initializing MLX model in the transcription worker thread...")
        model.load_model()
        state.model_loaded = True
        logger.info("MLX worker-thread initialization complete. Ready to record.")

    while True:
        audio_data = None
        temp_file_path = None
        try:
            audio_data = work_queue.get()

            if audio_data is None:
                logger.info("Worker received None sentinel. Exiting loop.")
                work_queue.task_done()
                logger.debug("Worker thread loop terminating.")
                break

            if (
                isinstance(audio_data, tuple)
                and len(audio_data) == 3
                and audio_data[0] == PREVIEW_JOB
            ):
                _, preview_audio, generation = audio_data
                _handle_preview_job(model, preview_audio, generation)
                work_queue.task_done()
                continue

            logger.debug(f"Worker received chunk of type {type(audio_data)} and shape {getattr(audio_data, 'shape', 'N/A')}")

            if len(audio_data) == 0:
                 logger.warning("Worker received empty audio data array, skipping.")
                 work_queue.task_done()
                 continue

            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                temp_file_path = tmp.name
            logger.debug(f"Worker created temp file: {temp_file_path}")

            try:
                if audio_data.dtype != np.float32:
                    logger.warning(f"Audio data was {audio_data.dtype}, attempting conversion to float32 for sf.write")
                    audio_data = audio_data.astype(np.float32)

                sf.write(temp_file_path, audio_data, SAMPLE_RATE)
                logger.debug(f"Worker successfully wrote {len(audio_data)} samples to {temp_file_path}")
            except Exception as write_e:
                logger.error(f"Worker failed to write temp WAV file {temp_file_path}: {write_e}", exc_info=True)
                work_queue.task_done()
                if temp_file_path and os.path.exists(temp_file_path):
                     try: os.unlink(temp_file_path)
                     except Exception: pass
                continue

            logger.debug(f"Worker calling model.transcribe() for {temp_file_path}...")
            transcription_start_time = time.time()
            try:
                 active_source_lang = state.source_lang
                 active_target_lang = state.target_lang
                 logger.info(f"Transcribing with forced language: {active_source_lang}")
                 results = model.transcribe_batch(
                     [temp_file_path],
                     source_lang=active_source_lang,
                     target_lang=active_target_lang,
                 )
                 if results and isinstance(results, list):
                      text = results[0]
                 else:
                      text = None
                      logger.warning(f"Worker received unexpected result type from transcribe_batch: {type(results)}")
                 transcription_duration = time.time() - transcription_start_time
                 logger.info(f"Worker transcribed chunk in {transcription_duration:.2f}s: {text[:30]}...")
            except Exception as transcribe_e:
                 # Suppress tqdm multiprocessing errors (non-fatal, see TQDM_ISSUE_ANALYSIS.md)
                 if "fds_to_keep" not in str(transcribe_e):
                     logger.error(f"Worker: Error during model transcription: {transcribe_e}", exc_info=True)
                 text = None

            if text:
                state.console.print(f"\n[dim]{text}[/dim]")
                results_list.append(text)

                # While the recording is still open, the pill mirrors what is
                # settled so far; the dimmed guess is cleared because its
                # audio is part of the confirmed line now. After stop the pill
                # is already in the processing state — nothing to mirror.
                if (
                    state.live_preview_active
                    and state.audio_manager is not None
                    and state.audio_manager.is_collecting
                ):
                    from hotkeys import set_overlay_transcript

                    set_overlay_transcript(
                        final=" ".join(results_list).strip(), partial=""
                    )

            work_queue.task_done()

        except Exception as e:
            logger.error(f"Unexpected error in transcription worker loop (before finally): {e}", exc_info=True)
            if audio_data is not None:
                try:
                    work_queue.task_done()
                except ValueError:
                    pass
            time.sleep(0.1)
        finally:
            if temp_file_path and os.path.exists(temp_file_path):
                try:
                    os.unlink(temp_file_path)
                    logger.debug(f"Worker deleted temp file: {temp_file_path}")
                except Exception as del_e:
                     logger.error(f"Worker failed to delete temp file {temp_file_path}: {del_e}")

    logger.info("Transcription worker thread finished normally.")
