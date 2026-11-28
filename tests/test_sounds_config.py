import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


PATCH = Path(__file__).resolve().parents[1] / "patches" / "ctrlspeak-1.8.0"


class SoundsConfigTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        home = Path(directory.name)
        environment = patch.dict(os.environ, {"LOCALVOICE_CONFIG_DIR": str(home / "localvoice"),
                                              "HOME": str(home)})
        environment.start()
        self.addCleanup(environment.stop)
        spec = importlib.util.spec_from_file_location(
            "localvoice_config_under_test", PATCH / "utils" / "localvoice_config.py")
        self.config = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.config)
        self.config.CONFIG_DIR.mkdir(parents=True)

    def test_sounds_are_on_unless_switched_off(self):
        for text, expected in [("", True), ("sounds = on\n", True), ("sounds = OFF\n", False),
                               ("sounds = no\n", False), ("sounds = onn\n", True)]:
            with self.subTest(text=text):
                self.config.CONFIG_FILE.write_text(text, encoding="utf-8")
                self.assertEqual(self.config.sounds(), expected)


if __name__ == "__main__":
    unittest.main()
