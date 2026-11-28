from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch


PATCH = Path(__file__).resolve().parents[1] / "patches" / "ctrlspeak-1.8.0"


def stub(name, **attributes):
    module = ModuleType(name)
    module.__dict__.update(attributes)
    return module


class Window:
    """Stands in for an mx.array: shape, dtype and value equality."""

    def __init__(self, value, shape=(1, 3000, 128), dtype="float16"):
        self.value, self.shape, self.dtype = value, shape, dtype


class Encoder:
    def __init__(self):
        self.calls = []

    def __call__(self, x):
        self.calls.append(x.value)
        return f"encoded {x.value}"


class ReusedEncodingTests(unittest.TestCase):
    def setUp(self):
        mx = stub("mlx.core", array_equal=lambda a, b: SimpleNamespace(item=lambda: a.value == b.value))
        modules = {
            "mlx": stub("mlx", __path__=[], core=mx),
            "mlx.core": mx,
            "models": stub("models", __path__=[str(PATCH / "models")]),
            "models.base_model": stub("models.base_model", BaseSTTModel=object),
        }
        context = patch.dict(sys.modules, modules)
        context.start()
        self.addCleanup(context.stop)
        sys.modules.pop("models.whisper_mlx", None)
        from models import whisper_mlx

        self.whisper = whisper_mlx

    def test_transcribe_reuses_the_detection_encoding_for_its_first_window(self):
        encoder = Encoder()
        window = Window("first")
        with self.whisper._reused_encoding(encoder, window, "kept features"):
            # transcribe() asks again for the same window, and once per fallback temperature.
            self.assertEqual(encoder(Window("first")), "kept features")
            self.assertEqual(encoder(Window("first")), "kept features")
            # Other windows, shapes or dtypes are encoded for real.
            self.assertEqual(encoder(Window("second")), "encoded second")
            self.assertEqual(encoder(Window("first", shape=(1, 3000, 80))), "encoded first")
            self.assertEqual(encoder(Window("first", dtype="float32")), "encoded first")
        self.assertEqual(encoder.calls, ["second", "first", "first"])
        # Outside the context the encoder is untouched.
        self.assertEqual(encoder(Window("first")), "encoded first")
        self.assertIs(type(encoder).__call__, Encoder.__dict__["__call__"])

    def test_encoder_is_restored_when_transcribe_raises(self):
        encoder = Encoder()
        with self.assertRaises(RuntimeError):
            with self.whisper._reused_encoding(encoder, Window("first"), "kept"):
                raise RuntimeError("decode failed")
        self.assertEqual(encoder(Window("first")), "encoded first")

    def test_transcribe_reuses_mel_spectrogram_for_same_audio(self):
        encoder = Encoder()
        audio = object()
        other_audio = object()
        mel_calls = []

        def fake_mel(inp, *args, **kwargs):
            mel_calls.append(inp)
            return "computed-mel"

        transcribe_stub = stub("mlx_whisper.transcribe", log_mel_spectrogram=fake_mel)
        with patch.dict(sys.modules, {
            "mlx_whisper": stub("mlx_whisper", __path__=[]),
            "mlx_whisper.transcribe": transcribe_stub,
        }):
            with self.whisper._reused_encoding(
                encoder, Window("first"), "kept features", audio=audio, mel="cached-mel"
            ):
                self.assertEqual(transcribe_stub.log_mel_spectrogram(audio), "cached-mel")
                self.assertEqual(transcribe_stub.log_mel_spectrogram(other_audio), "computed-mel")
            self.assertIs(transcribe_stub.log_mel_spectrogram, fake_mel)
        self.assertEqual(mel_calls, [other_audio])


if __name__ == "__main__":
    unittest.main()
