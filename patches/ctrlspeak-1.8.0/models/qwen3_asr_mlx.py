"""Qwen3-ASR on Apple Silicon through MLX (mlx-qwen3-asr), local weights only."""

import logging
from pathlib import Path

logger = logging.getLogger("qwen3_asr_mlx_model")


class Qwen3ASRMLXModel:
    """Run a verified local Qwen3-ASR checkpoint in the transcription worker."""

    supports_streaming = False
    supports_forced_language = True
    # MLX streams are thread-local: the transcription worker loads the weights.
    deferred_load = True

    AUTOMATIC = "auto"
    # LocalVoice's language codes -> the names Qwen3-ASR expects.
    LANGUAGES = {"de": "German", "en": "English"}

    def __init__(self, model_path):
        self.model_path = Path(model_path)
        self.session = None

    def _checked_path(self):
        # mlx-qwen3-asr treats anything that is not a local model directory as
        # a Hub repo ID. A managed path may never take that fallback.
        if not self.model_path.is_absolute() or not (self.model_path / "config.json").is_file():
            raise FileNotFoundError("Managed Qwen3-ASR model directory is unavailable.")
        return str(self.model_path)

    def load_model(self):
        if self.session is not None:
            return self.session

        from mlx_qwen3_asr import Session

        logger.info("Loading managed local Qwen3-ASR weights...")
        self.session = Session(self._checked_path())
        logger.info("Qwen3-ASR model loaded successfully.")
        return self.session

    def transcribe_pcm(self, samples, source_lang, target_lang):
        """Decode the recorder's mono 16 kHz float PCM without writing it to disk."""
        source_lang = str(source_lang).lower()
        if source_lang not in self.LANGUAGES and source_lang != self.AUTOMATIC:
            raise ValueError("Qwen3-ASR language must be 'de', 'en' or 'auto'.")
        if str(target_lang).lower() != source_lang:
            raise ValueError("Translation is disabled; target language must match source language.")
        if not len(samples):
            return ""

        import mlx.core as mx

        from utils import localvoice_config
        from utils.prompt_echo import suppress_prompt_echo

        session = self.load_model()
        # The user's vocabulary becomes Qwen's context prompt, which biases the
        # decoder toward those spellings. Read per call so edits apply at once.
        vocabulary = localvoice_config.vocabulary()
        try:
            result = session.transcribe(
                samples,
                language=self.LANGUAGES.get(source_lang),
                context=", ".join(vocabulary),
            )
        finally:
            # MLX keeps freed buffers for reuse; hand them back after each
            # decode, as the Whisper backend does, so the cache cannot grow.
            mx.clear_cache()
        text = (result.text or "").strip()
        # A context prompt can be read back on near-silent audio.
        return suppress_prompt_echo(text, vocabulary)

    def transcribe_batch(self, audio_paths, source_lang="de", target_lang="de", **kwargs):
        import soundfile as sf

        transcripts = []
        for path in audio_paths:
            samples, rate = sf.read(str(path), dtype="float32")
            if rate != 16_000 or samples.ndim != 1:
                raise ValueError("Qwen3-ASR expects mono 16 kHz audio.")
            transcripts.append(self.transcribe_pcm(samples, source_lang, target_lang))
        return transcripts

    def unload_model(self):
        """Release loaded MLX Qwen3-ASR weights and clear Metal buffer cache."""
        if self.session is None:
            return
        self.session = None
        import gc
        import mlx.core as mx
        gc.collect()
        mx.clear_cache()

    @property
    def name(self):
        return f"Qwen3ASR-{self.model_path.name}"
