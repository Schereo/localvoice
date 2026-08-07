"""MLX Whisper backend with explicit language selection for Apple Silicon."""

import logging
from typing import List

from models.base_model import BaseSTTModel

logger = logging.getLogger("whisper_mlx_model")


class WhisperMLXModel(BaseSTTModel):
    """Run Whisper Large V3 Turbo locally through Apple's MLX framework."""

    SUPPORTED_LANGUAGES = {"de", "en"}
    AUTOMATIC = "auto"

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

    def detect_language(self, audio_path: str) -> str:
        """Choose between German and English for one recording.

        Whisper's own detection ranks all 99 languages it knows, and readily
        returns Dutch or Afrikaans for German speech — which then decodes as
        nonsense. Comparing only the two probabilities this setup supports
        keeps a wrong guess from leaving the pair.
        """
        import mlx.core as mx
        from mlx_whisper.audio import (
            N_FRAMES,
            N_SAMPLES,
            load_audio,
            log_mel_spectrogram,
            pad_or_trim,
        )

        model = self.model if self.model is not None else self.load_model()

        mel = log_mel_spectrogram(
            load_audio(audio_path),
            n_mels=model.dims.n_mels,
            padding=N_SAMPLES,
        )
        # The spectrogram is (frames, n_mels); trim on the time axis, the same
        # way transcribe.py does internally.
        segment = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
        _, probabilities = model.detect_language(segment)

        scores = {code: float(probabilities.get(code, 0.0)) for code in self.SUPPORTED_LANGUAGES}
        detected = max(scores, key=scores.get)
        logger.info(
            "Detected language: %s (%s)",
            detected,
            ", ".join(f"{code}={score:.3f}" for code, score in sorted(scores.items())),
        )
        return detected

    def transcribe_batch(
        self,
        audio_paths: List[str],
        source_lang: str = "de",
        target_lang: str = "de",
        **kwargs,
    ) -> List[str]:
        """Transcribe audio with German, English, or automatic decoding."""
        if not audio_paths:
            return []

        source_lang = source_lang.lower()
        target_lang = target_lang.lower()

        if source_lang not in self.SUPPORTED_LANGUAGES | {self.AUTOMATIC}:
            raise ValueError("MLX Whisper language must be 'de', 'en' or 'auto'.")
        if target_lang != source_lang:
            raise ValueError("Translation is disabled; target language must match source language.")

        if self.model is None:
            self.load_model()

        import mlx_whisper

        import state

        transcriptions = []
        for audio_path in audio_paths:
            if source_lang == self.AUTOMATIC:
                language = self.detect_language(audio_path)
            else:
                language = source_lang

            # The pill reports this back, so automatic mode is not a black box.
            state.last_detected_language = language

            result = mlx_whisper.transcribe(
                audio_path,
                path_or_hf_repo=self.model_name,
                language=language,
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
