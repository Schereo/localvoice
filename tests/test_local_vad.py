import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


SOURCE = Path(__file__).resolve().parents[1] / "patches/ctrlspeak-1.8.0/utils/localvoice_vad.py"
SPEC = importlib.util.spec_from_file_location("localvoice_vad", SOURCE)
vad = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vad)


class LocalVADTests(unittest.TestCase):
    def test_read_verified_asset_without_hub(self):
        data = b"verified fixture"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "silero_vad.jit"
            path.write_bytes(data)
            torch = Mock()
            with (
                patch.dict(os.environ, {"LOCALVOICE_VAD_PATH": str(path)}),
                patch.object(vad, "SILERO_BYTES", len(data)),
                patch.object(vad, "SILERO_SHA256", hashlib.sha256(data).hexdigest()),
            ):
                model = vad.load_local_vad(torch)
                self.assertIs(model, torch.jit.load.return_value.eval.return_value)
                asset = torch.jit.load.call_args.args[0]
                self.assertEqual(asset.getvalue(), data)
                torch.hub.get_dir.assert_not_called()
                torch.hub.load.assert_not_called()

    def test_reject_asset_before_deserialization(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "silero_vad.jit"
            path.write_bytes(b"x")
            torch = Mock()
            with (
                patch.dict(os.environ, {"LOCALVOICE_VAD_PATH": str(path)}),
                patch.object(vad, "SILERO_BYTES", 1),
                self.assertRaises(ValueError),
            ):
                vad.load_local_vad(torch)
            torch.jit.load.assert_not_called()
