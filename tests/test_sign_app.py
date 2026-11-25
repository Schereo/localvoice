"""Offline tests for the Developer ID signing planner; nothing is signed."""

import importlib.util
import plistlib
import struct
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "sign_app", Path(__file__).resolve().parents[1] / "scripts/sign-app.py"
)
sign = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sign)


def thin(filetype):
    """A minimal little-endian 64-bit Mach-O header."""
    return b"\xcf\xfa\xed\xfe" + struct.pack("<III", 0x0100000C, 0, filetype) + b"\0" * 16


def fat(filetype, offset=4096):
    header = b"\xca\xfe\xba\xbe" + struct.pack(">I", 1) + struct.pack(">IIIII", 0x0100000C, 0, offset, 32, 12)
    return header.ljust(offset, b"\0") + thin(filetype)


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


class MachOTypeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())

    def test_thin_and_fat_binaries(self):
        self.assertEqual(sign.macho_type(write(self.root / "a", thin(sign.MH_EXECUTE))), sign.MH_EXECUTE)
        self.assertEqual(sign.macho_type(write(self.root / "b.so", thin(sign.MH_BUNDLE))), sign.MH_BUNDLE)
        self.assertEqual(sign.macho_type(write(self.root / "c.dylib", fat(sign.MH_DYLIB))), sign.MH_DYLIB)

    def test_non_macho_files(self):
        java = b"\xca\xfe\xba\xbe" + struct.pack(">HH", 0, 52) + b"\0" * 24  # class file, major 52
        self.assertIsNone(sign.macho_type(write(self.root / "A.class", java)))
        self.assertIsNone(sign.macho_type(write(self.root / "run.sh", b"#!/bin/bash\necho hi\n")))
        self.assertIsNone(sign.macho_type(write(self.root / "short", b"\xcf\xfa")))
        self.assertIsNone(sign.macho_type(self.root / "missing"))


class PlanTests(unittest.TestCase):
    def app(self):
        app = Path(tempfile.mkdtemp()) / "LocalVoice.app"
        write(app / "Contents/Info.plist", plistlib.dumps({"CFBundleExecutable": "LocalVoice"}))
        write(app / "Contents/MacOS/LocalVoice", thin(sign.MH_EXECUTE))
        write(app / "Contents/Helpers/ctrlspeak-overlay", thin(sign.MH_EXECUTE))
        write(app / "Contents/Resources/runtime/bin/python3.11", thin(sign.MH_EXECUTE))
        write(app / "Contents/Resources/runtime/lib/libpython3.11.dylib", thin(sign.MH_DYLIB))
        write(app / "Contents/Resources/runtime/lib/python3.11/site-packages/x/_x.so", fat(sign.MH_BUNDLE))
        write(app / "Contents/Resources/runtime/lib/python3.11/site-packages/x/stub.o", thin(1))
        write(app / "Contents/Resources/run-ctrlspeak", b"#!/bin/bash\n")
        (app / "Contents/Resources/runtime/bin/python3").symlink_to("python3.11")
        return app

    def test_entitlements_by_location(self):
        app = self.app()
        nested, skipped, bundle = sign.plan(app)
        entitlements = {str(path.relative_to(app)): value and value.name for path, value in nested}
        self.assertEqual(entitlements, {
            "Contents/Helpers/ctrlspeak-overlay": None,
            "Contents/Resources/runtime/bin/python3.11": "python.plist",
            "Contents/Resources/runtime/lib/libpython3.11.dylib": None,
            "Contents/Resources/runtime/lib/python3.11/site-packages/x/_x.so": None,
        })
        self.assertEqual([path.name for path in skipped], ["stub.o"])
        self.assertEqual(bundle, (app, sign.ENTITLEMENTS / "app.plist"))

    def test_nested_bundles_are_refused(self):
        app = self.app()
        (app / "Contents/Resources/Other.app").mkdir()
        with self.assertRaises(SystemExit):
            sign.plan(app)

    def test_entitlement_files_are_valid_plists(self):
        for name in ("app.plist", "python.plist"):
            values = plistlib.loads((sign.ENTITLEMENTS / name).read_bytes())
            self.assertTrue(values["com.apple.security.device.audio-input"])


if __name__ == "__main__":
    unittest.main()
