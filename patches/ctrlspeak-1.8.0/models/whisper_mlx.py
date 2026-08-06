"""MLX Whisper backend with explicit language selection for Apple Silicon."""

import logging
from typing import List

from models.base_model import BaseSTTModel

logger = logging.getLogger("whisper_mlx_model")


class WhisperMLXModel(BaseSTTModel):
    """Run Whisper Large V3 Turbo locally through Apple's MLX framework."""

    SUPPORTED_LANGUAGES = {"de", "en"}

    def __init__(
        self,
        model_name="mlx-community/whisper-large-v3-turbo",
        device=None,
        verbose=False,
    ):
        super().__init__(device=None, verbose=verbose)
        self.model_name = model_name
        self.model = None

    def load_model(self):
        """Load and cache the MLX model in the transcription worker thread."""
        if self.model is not None:
            return self.model

        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder

        import state
        from model_download import download_progress

        logger.info(f"Loading {self.model_name}...")
        # On a cold cache this call blocks for a 1.6-GB download, so the pill
        # reports progress instead of leaving the user with a silent startup.
        with download_progress(self.model_name, getattr(state, "source_lang", "de")):
            self.model = ModelHolder.get_model(self.model_name, mx.float16)
        logger.info("MLX Whisper model loaded successfully.")
        return self.model

    def transcribe_batch(
        self,
        audio_paths: List[str],
        source_lang: str = "de",
        target_lang: str = "de",
        **kwargs,
    ) -> List[str]:
        """Transcribe audio while forcing either German or English decoding."""
        if not audio_paths:
            return []

        source_lang = source_lang.lower()
        target_lang = target_lang.lower()

        if source_lang not in self.SUPPORTED_LANGUAGES:
            raise ValueError("MLX Whisper language must be 'de' or 'en'.")
        if target_lang != source_lang:
            raise ValueError("Translation is disabled; target language must match source language.")

        if self.model is None:
            self.load_model()

        import mlx_whisper

        transcriptions = []
        for audio_path in audio_paths:
            result = mlx_whisper.transcribe(
                audio_path,
                path_or_hf_repo=self.model_name,
                language=source_lang,
                task="transcribe",
                temperature=0.0,
                condition_on_previous_text=False,
                verbose=None,
            )
            transcriptions.append(self._clean_text(result.get("text", "")))

        return transcriptions

    @property
    def name(self):
        return f"WhisperMLX-{self.model_name.split('/')[-1]}"
