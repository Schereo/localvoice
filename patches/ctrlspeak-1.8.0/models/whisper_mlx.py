"""MLX Whisper backend with explicit language selection for Apple Silicon."""

import logging
import re
from typing import List

from models.base_model import BaseSTTModel

logger = logging.getLogger("whisper_mlx_model")


class WhisperMLXModel(BaseSTTModel):
    """Run Whisper Large V3 Turbo locally through Apple's MLX framework."""

    SUPPORTED_LANGUAGES = {"de", "en"}
    AUTOMATIC = "auto"

    # Whisper's standard fallback ladder. A single fixed temperature would
    # disable the compression-ratio retry, and that retry is what breaks the
    # decoder's pathological loops — with a vocabulary prompt and near-silent
    # audio, greedy decoding happily emits the word list forever.
    DECODE_TEMPERATURES = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)

    # Segments the model itself scores as probable non-speech are dropped
    # outright. Upstream only skips them when the decode is *also* low
    # confidence — but a hallucinated echo of the vocabulary prompt is a
    # perfectly confident decode of nothing.
    NO_SPEECH_MAX = 0.6

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
        from utils import localvoice_config

        # The user's vocabulary rides in as Whisper's initial prompt: the
        # decoder conditions on it as if those words had just been said, and
        # then reuses their spelling. Read per call, so an edited word list
        # applies from the very next recording. Whisper itself truncates the
        # prompt to its context budget (the last ~224 tokens), so an oversized
        # list degrades gracefully instead of failing.
        vocabulary = localvoice_config.vocabulary()
        initial_prompt = ", ".join(vocabulary) if vocabulary else None

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
                temperature=self.DECODE_TEMPERATURES,
                # Whisper's default, and what carries the vocabulary past the
                # first 30-second window: the prompt buffer keeps the initial
                # prompt plus the decoded text, so later windows still see the
                # taught spellings — reinforced by the correctly spelled text
                # itself. The repetition loops this used to risk are handled
                # by the temperature ladder: any fallback above 0.5 makes
                # mlx_whisper reset the prompt buffer for the next window.
                condition_on_previous_text=True,
                initial_prompt=initial_prompt,
                verbose=None,
            )

            text = self._clean_text(self._assemble_text(result))
            suppressed = self._suppress_prompt_echo(text, vocabulary)
            if suppressed != text:
                logger.info(
                    "Suppressed vocabulary echo in transcript: %r -> %r",
                    text[:120],
                    suppressed[:120],
                )
            transcriptions.append(suppressed)

        return transcriptions

    def _assemble_text(self, result):
        """Join the result's segments, dropping probable non-speech.

        result["text"] would include every segment; filtering here catches the
        case where a stray noise burst decodes — confidently — into words that
        were never spoken.
        """
        segments = result.get("segments")
        if not segments:
            return result.get("text", "")

        kept = []
        for segment in segments:
            no_speech = float(segment.get("no_speech_prob") or 0.0)
            if no_speech > self.NO_SPEECH_MAX:
                logger.info(
                    "Dropped non-speech segment (no_speech_prob=%.2f): %r",
                    no_speech,
                    str(segment.get("text", ""))[:80],
                )
                continue
            kept.append(str(segment.get("text", "")).strip())

        return " ".join(part for part in kept if part)

    @staticmethod
    def _suppress_prompt_echo(text, vocabulary):
        """Strip hallucinated read-backs of the vocabulary prompt.

        Two shapes survive the decode-time defenses: a vocabulary word
        stuttered in a row (collapsed to one), and a transcript consisting of
        nothing but vocabulary words — the prompt echoed at a moment with no
        real speech to transcribe, which becomes empty rather than pasted.
        A single vocabulary word alone is kept: that can be a real dictation.
        """
        if not text or not vocabulary:
            return text

        for word in vocabulary:
            escaped = re.escape(word)
            text = re.sub(
                rf"(?:{escaped}[\s,.;:!?]+){{2,}}({escaped})",
                r"\1",
                text,
                flags=re.IGNORECASE,
            )

        tokens = [token for token in re.split(r"[\s,.;:!?]+", text) if token]
        vocabulary_tokens = {
            part.lower()
            for word in vocabulary
            for part in re.split(r"\s+", word)
            if part
        }
        if len(tokens) >= 2 and all(token.lower() in vocabulary_tokens for token in tokens):
            return ""

        return text

    @property
    def name(self):
        return f"WhisperMLX-{self.model_name.split('/')[-1]}"
