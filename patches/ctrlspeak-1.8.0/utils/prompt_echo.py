"""Shared filter for transcripts that read a vocabulary prompt back."""

import re


def suppress_prompt_echo(text, vocabulary):
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
