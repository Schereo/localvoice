"""Measure a verified local Whisper model without starting LocalVoice or its mic."""

import argparse
import json
import os
from pathlib import Path
import re
import resource
import statistics
import sys
import time


def words(text):
    return re.findall(r"\w+", text.casefold())


def word_errors(reference, actual):
    row = list(range(len(actual) + 1))
    for index, expected in enumerate(reference, start=1):
        previous = row
        row = [index]
        for column, result in enumerate(actual, start=1):
            row.append(min(
                previous[column] + 1,
                row[column - 1] + 1,
                previous[column - 1] + (expected != result),
            ))
    return row[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", choices=["whisper-turbo-fp16", "whisper-turbo-q4"])
    parser.add_argument(
        "--manifest", type=Path,
        help="JSON array of {path, language, reference} clips (DE/EN, paths relative to the manifest). "
             "Without it, run a synthetic silence smoke test.",
    )
    args = parser.parse_args()

    os.environ["HF_HUB_OFFLINE"] = "1"
    patch_path = Path(__file__).resolve().parents[1] / "patches/ctrlspeak-1.8.0"
    sys.path.insert(0, str(patch_path))
    from localvoice_models import ModelStoreError, resolve_model

    try:
        directory = resolve_model(args.model)
    except ModelStoreError as error:
        parser.exit(2, f"{error}\n")

    import mlx.core as mx
    import mlx_whisper
    from mlx_whisper.audio import load_audio
    from mlx_whisper.transcribe import ModelHolder
    import numpy as np

    if args.manifest:
        entries = json.loads(args.manifest.read_text(encoding="utf-8"))
        if not entries:
            parser.error("the manifest must have at least one clip")
        clips = []
        for entry in entries:
            language = entry["language"]
            if language not in {"de", "en"}:
                parser.error("manifest languages must be de or en")
            path = args.manifest.parent / entry["path"]
            clips.append((load_audio(str(path)), language, words(entry["reference"])))
    else:
        clips = [(np.zeros(16_000, dtype=np.float32), "de", [])]

    started = time.perf_counter()
    ModelHolder.get_model(str(directory), mx.float16)
    load_seconds = time.perf_counter() - started
    durations = []
    errors = 0
    reference_words = 0
    spurious_words = 0
    for samples, language, reference in clips:
        started = time.perf_counter()
        result = mlx_whisper.transcribe(
            samples, path_or_hf_repo=str(directory), language=language, verbose=None,
        )
        durations.append(time.perf_counter() - started)
        actual = words(result["text"])
        if reference:
            reference_words += len(reference)
            errors += word_errors(reference, actual)
        else:
            spurious_words += len(actual)

    print(json.dumps({
        "model": args.model,
        "clips": len(clips),
        "load_seconds": round(load_seconds, 3),
        "decode_median_seconds": round(statistics.median(durations), 3),
        "decode_max_seconds": round(max(durations), 3),
        "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "peak_mlx_bytes": mx.get_peak_memory(),
        "normalized_word_error_rate": round(errors / reference_words, 4) if reference_words else None,
        "words_from_empty_reference": spurious_words,
    }, indent=2))


if __name__ == "__main__":
    main()
