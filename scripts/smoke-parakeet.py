"""Use the app's model store and Python/Core ML bridge on an offline WAV."""

import argparse
import array
import json
from pathlib import Path
import sys
import time
import wave


class Samples:
    ndim = 1

    def __init__(self, values):
        self.values = values

    def __len__(self):
        return len(self.values)

    def __getitem__(self, index):
        return Samples(self.values[index])

    def astype(self, dtype, *, copy):
        assert dtype == "<f4" and sys.byteorder == "little"
        return self

    def tobytes(self):
        return self.values.tobytes()


def main():
    patch_dir = Path(__file__).resolve().parents[1] / "patches/ctrlspeak-1.8.0"
    sys.path.insert(0, str(patch_dir))
    from localvoice_models import resolve_model
    from models.parakeet_coreml import NEMOTRON, NemotronCoreMLModel, ParakeetCoreMLModel, VARIANTS

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", choices=[*VARIANTS, NEMOTRON])
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--wav", type=Path, action="append", required=True, help="16 kHz mono PCM16 WAV (repeatable)")
    parser.add_argument("--expect", action="append", help="Expected phrase per WAV, case-insensitive")
    parser.add_argument("--language", action="append", choices=["auto", "de", "en"],
                        help="Language per WAV for Nemotron (default: auto)")
    args = parser.parse_args()

    if args.expect and len(args.expect) != len(args.wav):
        parser.error("pass one --expect per --wav, or omit all expectations")
    if args.language and (args.model != NEMOTRON or len(args.language) != len(args.wav)):
        parser.error("--language is for Nemotron only; pass one per WAV")
    clips = []
    for path in args.wav:
        with wave.open(str(path), "rb") as speech:
            if (speech.getframerate(), speech.getnchannels(), speech.getsampwidth()) != (16000, 1, 2):
                parser.error("expected a 16 kHz mono PCM16 WAV")
            pcm = array.array("h")
            pcm.frombytes(speech.readframes(speech.getnframes()))
        if not pcm:
            parser.error("the audio file is empty")
        clips.append(Samples(array.array("f", (i / 32768 for i in pcm))))

    provider = NemotronCoreMLModel if args.model == NEMOTRON else ParakeetCoreMLModel
    decoder = provider(args.model, resolve_model(args.model), worker=args.worker.resolve())
    started = time.monotonic()
    try:
        decoder.load_model()
        loaded = time.monotonic()
        results = []
        for index, samples in enumerate(clips):
            before = time.monotonic()
            partials = 0
            if decoder.supports_streaming:
                decoder.init_streaming((args.language or ["auto"] * len(clips))[index])
                step = decoder.chunk_size_ms * 16
                for start in range(0, len(samples), step):
                    partials += bool(decoder.stream_chunk(samples[start:start + step]))
                text = decoder.finalize_streaming()
                if not partials:
                    parser.exit(1, f"Nemotron returned no live text in clip {index + 1}.\n")
            else:
                text = decoder.transcribe_pcm(samples, "auto", "auto")
            if not text or (args.expect and args.expect[index].casefold() not in text.casefold()):
                parser.exit(1, f"The expected speech was not recognized in clip {index + 1}.\n")
            results.append({"text": text, "decode_seconds": round(time.monotonic() - before, 3),
                            "nonempty_partials": partials})
    finally:
        decoder.close()
    print(json.dumps({"model": args.model, "load_seconds": round(loaded - started, 3),
                      "clips": results}, ensure_ascii=False))


if __name__ == "__main__":
    main()
