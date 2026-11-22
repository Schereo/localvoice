
import time
import logging
import state

logger = logging.getLogger("ctrlspeak")

class ModelLoadError(Exception):
    """Exception raised when model loading fails with user-friendly message."""
    pass


class ManagedModelUnavailable(ModelLoadError):
    """The selected model is not available in the verified local store."""


def resolve_managed_model(model_id):
    """Verify the installed model without importing an inference backend."""
    try:
        from localvoice_models import resolve_model

        path = resolve_model(model_id)
        if not path.is_absolute() or not path.is_dir():
            raise ValueError("model store did not return an existing absolute directory")
        return path
    except Exception as exc:
        raise ManagedModelUnavailable(f"{model_id!r}: {exc}") from exc


def get_model(*, managed_model_path=None):
    """
    Load model with progress tracking.

    Returns:
        The loaded model instance

    Raises:
        ModelLoadError: If model fails to load, with user-friendly error message
    """

    if managed_model_path is not None:
        from models.parakeet_coreml import NEMOTRON, NemotronCoreMLModel, ParakeetCoreMLModel, VARIANTS

        if state.model_type in VARIANTS or state.model_type == NEMOTRON:
            from localvoice_models import parakeet_worker_path

            model_class = NemotronCoreMLModel if state.model_type == NEMOTRON else ParakeetCoreMLModel
            state.stt_model = model_class(
                state.model_type, managed_model_path, worker=parakeet_worker_path(state.model_type)
            )
        else:
            # Never pass the stable ID (or a Hub repo ID) to Whisper.
            from models.whisper_mlx import WhisperMLXModel

            state.stt_model = WhisperMLXModel(
                model_name=str(managed_model_path), verbose=state.DEBUG_MODE
            )
        state.model_loaded = False
        return state.stt_model

    if state.stt_model is not None:
        return state.stt_model

    from models.factory import ModelFactory

    state.console.print("\n[bold yellow]Loading model... please wait[/bold yellow]")
    start_time = time.time()

    try:
        logger.info(f"Step 1: Creating {state.model_type} model instance...")
        try:
            state.stt_model = ModelFactory.get_model(model_type=state.model_type, device=state.device, verbose=state.DEBUG_MODE)
            logger.info("Model instance created successfully")
        except Exception as e:
            error_msg = str(e)
            logger.error(f"Error creating model instance: {error_msg}")
            state.console.print(f"[bold red]Error creating model instance: {error_msg}[/bold red]")
            if state.DEBUG_MODE:
                import traceback
                traceback.print_exc()
            raise ModelLoadError(error_msg)

        # MLX 0.32 streams are thread-local. MLX inference happens in
        # ctrlSPEAK's transcription worker, so weights must be loaded in that
        # same worker rather than here on the main thread.
        if state.stt_model.__class__.__name__ in {"ParakeetMLXModel", "WhisperMLXModel"}:
            logger.info("Deferring MLX weight loading to the transcription worker thread.")
            state.model_loaded = False
            return state.stt_model

        logger.info("Step 2: Loading model weights...")
        try:
            state.stt_model.load_model()
            logger.info("Model weights loaded successfully")
        except Exception as e:
            error_msg = str(e)
            logger.error(f"Error loading model weights: {error_msg}")
            state.console.print(f"[bold red]Error loading model weights: {error_msg}[/bold red]")
            if state.DEBUG_MODE:
                import traceback
                traceback.print_exc()
            raise ModelLoadError(error_msg)

        end_time = time.time()
        state.model_loaded = True
        state.console.print(f"[bold green]Model loaded in {end_time - start_time:.2f} seconds. Ready to record![/bold green]")

        return state.stt_model
    except ModelLoadError:
        # Re-raise ModelLoadError as-is
        raise
    except Exception as e:
        error_msg = str(e)
        logger.error(f"Unexpected error in get_model: {error_msg}")
        state.console.print(f"[bold red]Unexpected error in get_model: {error_msg}[/bold red]")
        if state.DEBUG_MODE:
            import traceback
            traceback.print_exc()
        raise ModelLoadError(error_msg)
