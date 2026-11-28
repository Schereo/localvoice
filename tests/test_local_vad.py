import hashlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile


SOURCE = Path(__file__).resolve().parents[1] / "patches/ctrlspeak-1.8.0/utils/localvoice_vad.py"
SPEC = importlib.util.spec_from_file_location("localvoice_vad", SOURCE)
vad = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vad)


class LocalVADTests(unittest.TestCase):
    def test_read_verified_asset_without_torch_or_hub(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as archive:
            for _name, entry, shape in vad._TENSOR_SPECS:
                count = 1
                for dim in shape:
                    count *= dim
                archive.writestr(vad._ARCHIVE_PREFIX + entry, b"\x00" * (count * 4))
        data = buf.getvalue()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "silero_vad.jit"
            path.write_bytes(data)
            with (
                patch.dict(os.environ, {"LOCALVOICE_VAD_PATH": str(path)}),
                patch.object(vad, "SILERO_BYTES", len(data)),
                patch.object(vad, "SILERO_SHA256", hashlib.sha256(data).hexdigest()),
                patch.object(vad, "_extract_weights", return_value={"stub": True}) as extract,
                patch.object(vad, "SileroVAD", return_value="numpy-vad") as ctor,
            ):
                model = vad.load_local_vad()
                self.assertEqual(model, "numpy-vad")
                extract.assert_called_once_with(data)
                ctor.assert_called_once_with({"stub": True})

    def test_reject_asset_before_deserialization(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "silero_vad.jit"
            path.write_bytes(b"x")
            with (
                patch.dict(os.environ, {"LOCALVOICE_VAD_PATH": str(path)}),
                patch.object(vad, "SILERO_BYTES", 1),
                patch.object(vad, "_extract_weights") as extract,
                self.assertRaises(ValueError),
            ):
                vad.load_local_vad()
            extract.assert_not_called()
