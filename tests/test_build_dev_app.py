"""Offline tests for the portable app build's updater pieces; nothing is built."""

import base64
import importlib.util
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "build_dev_app", Path(__file__).resolve().parents[1] / "scripts/build-dev-app.py"
)
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


def framework(root):
    """Sparkle.framework as its release ships it: versioned, with top-level links."""
    source = root / "sparkle"
    version = source / "Sparkle.framework/Versions/B"
    for folder in ("Resources", "XPCServices/Installer.xpc", "Headers", "PrivateHeaders", "Modules",
                   "Updater.app/Contents/MacOS"):
        (version / folder).mkdir(parents=True)
    (version / "Sparkle").write_bytes(b"binary")
    (version / "Autoupdate").write_bytes(b"binary")
    (version / "Resources/Info.plist").write_bytes(b"plist")
    (version / "Headers/Sparkle.h").write_text("header")
    (source / "Sparkle.framework/Versions/Current").symlink_to("B")
    for name in ("Sparkle", "Autoupdate", "Updater.app", "Resources", "XPCServices", "Headers",
                 "PrivateHeaders", "Modules"):
        (source / "Sparkle.framework" / name).symlink_to(f"Versions/Current/{name}")
    return source


class SparkleEmbeddingTests(unittest.TestCase):
    def test_embeds_the_runtime_parts_only(self):
        root = Path(tempfile.mkdtemp())
        embedded = build.embed_sparkle(framework(root), root / "App.app/Contents/Frameworks")
        names = sorted(path.name for path in embedded.iterdir())
        self.assertEqual(names, ["Autoupdate", "Resources", "Sparkle", "Updater.app", "Versions"])
        self.assertEqual(sorted(path.name for path in (embedded / "Versions/B").iterdir()),
                         ["Autoupdate", "Resources", "Sparkle", "Updater.app"])
        self.assertTrue((embedded / "Versions/Current").is_symlink())
        self.assertTrue((embedded / "Sparkle").is_symlink())


class UpdateKeyTests(unittest.TestCase):
    def test_no_feed_no_updater(self):
        self.assertEqual(build.update_keys(None), {})

    def test_feed_turns_on_the_updater(self):
        keys = build.update_keys("https://github.com/Schereo/localvoice/releases/latest/download/appcast.xml")
        self.assertEqual(keys["SUPublicEDKey"], build.SPARKLE_PUBLIC_KEY)
        self.assertFalse(keys["SUEnableSystemProfiling"])
        # On by default: Sparkle checks daily without asking first.
        self.assertIs(keys["SUEnableAutomaticChecks"], True)

    def test_public_key_is_an_ed25519_key(self):
        self.assertEqual(len(base64.b64decode(build.SPARKLE_PUBLIC_KEY, validate=True)), 32)


if __name__ == "__main__":
    unittest.main()
