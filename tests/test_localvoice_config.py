import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


PATCH = Path(__file__).resolve().parents[1] / "patches" / "ctrlspeak-1.8.0"


class HotkeyConfigTests(unittest.TestCase):
    """The service's own listener (standalone fallback) and the app read one file."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        environment = patch.dict(os.environ, {"LOCALVOICE_CONFIG_DIR": str(self.home / "localvoice"),
                                              "HOME": str(self.home)})
        environment.start()
        self.addCleanup(environment.stop)
        spec = importlib.util.spec_from_file_location(
            "localvoice_config_under_test", PATCH / "utils" / "localvoice_config.py")
        self.config = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.config)
        self.config.CONFIG_DIR.mkdir(parents=True)

    def write(self, text):
        self.config.CONFIG_FILE.write_text(text, encoding="utf-8")

    def test_dictate_tap_gesture_wins_over_hotkey(self):
        self.write("hotkey = cmd,2\ndictate = alt,3\n")
        self.assertEqual(self.config.hotkey(), ("alt", 3))

    def test_key_combination_leaves_the_listener_on_hotkey(self):
        self.write("hotkey = cmd,2\ndictate = alt+space\n")
        self.assertEqual(self.config.hotkey(), ("cmd", 2))

    def test_default_without_either(self):
        self.write("")
        self.assertEqual(self.config.hotkey(), ("ctrl", 3))

    def test_upgrade_never_adds_a_dictate_key_that_would_override_hotkey(self):
        self.write("hotkey = cmd,2\n")
        self.config.ensure_config_file()
        self.assertNotIn("dictate", self.config.load())
        self.assertEqual(self.config.hotkey(), ("cmd", 2))


if __name__ == "__main__":
    unittest.main()
