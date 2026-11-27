import importlib.util
import os
from pathlib import Path
import socket
import sys
import threading
import unittest
from unittest.mock import patch


PATCH = Path(__file__).resolve().parents[1] / "patches" / "ctrlspeak-1.8.0"


def load_app_control():
    spec = importlib.util.spec_from_file_location("app_control", PATCH / "app_control.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AppControlTests(unittest.TestCase):
    def setUp(self):
        self.control = load_app_control()
        self.app, service = socket.socketpair()
        self.addCleanup(self.app.close)
        self.service_fd = service.detach()
        self.addCleanup(os.close, self.service_fd)
        self.app.settimeout(2)
        self.replies = self.app.makefile("rb")
        self.addCleanup(self.replies.close)

    def test_enabled_only_when_the_app_owns_the_shortcuts(self):
        with patch.dict(os.environ, {"LOCALVOICE_HOTKEYS": "app"}):
            self.assertTrue(self.control.enabled())
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(self.control.enabled())

    def test_commands_run_in_order_and_unknown_lines_are_ignored(self):
        calls, done, gone = [], threading.Event(), threading.Event()
        commands = {
            "toggle": lambda: calls.append("toggle"),
            "discard": lambda: calls.append("discard"),
            "finish": lambda: (calls.append("finish"), done.set()),
        }
        self.control.start(commands, on_eof=gone.set, fd=self.service_fd)
        self.assertEqual(self.replies.readline(), b"ready\n")
        self.app.sendall(b"toggle\nptt-down\n\ndiscard\r\nfin")
        self.app.sendall(b"ish\n")
        self.assertTrue(done.wait(2))
        self.assertEqual(calls, ["toggle", "discard", "finish"])
        self.assertFalse(gone.is_set())

    def test_failing_command_does_not_stop_the_channel(self):
        done = threading.Event()

        def broken():
            raise RuntimeError("boom")

        self.control.start({"toggle": broken, "finish": done.set}, on_eof=lambda: None, fd=self.service_fd)
        with self.assertLogs("ctrlspeak.app_control", "ERROR"):
            self.app.sendall(b"toggle\nfinish\n")
            self.assertTrue(done.wait(2))

    def test_recording_state_reaches_the_app_after_ready(self):
        self.control.publish_recording(True)  # before start: nobody to tell
        self.control.start({}, on_eof=lambda: None, fd=self.service_fd)
        self.control.publish_recording(True)
        self.control.publish_recording(False)
        self.assertEqual([self.replies.readline() for _ in range(3)],
                         [b"ready\n", b"recording 1\n", b"recording 0\n"])

    def test_app_closing_its_end_reports_eof(self):
        gone = threading.Event()
        self.control.start({}, on_eof=gone.set, fd=self.service_fd)
        self.replies.close()
        self.app.close()
        self.assertTrue(gone.wait(2))

    def test_eof_is_heard_before_the_commands_are_served(self):
        # The app can quit while the model still loads.
        gone = threading.Event()
        self.control.listen(on_eof=gone.set, fd=self.service_fd)
        self.app.sendall(b"toggle\n")  # nothing to run it yet: dropped
        self.replies.close()
        self.app.close()
        self.assertTrue(gone.wait(2))

    def test_start_after_listen_serves_on_the_same_socket(self):
        done, gone = threading.Event(), threading.Event()
        self.control.listen(on_eof=gone.set, fd=self.service_fd)
        self.control.start({"finish": done.set}, on_eof=lambda: None, fd=self.service_fd)
        self.assertEqual(self.replies.readline(), b"ready\n")
        self.app.sendall(b"finish\n")
        self.assertTrue(done.wait(2))
        self.replies.close()
        self.app.close()
        self.assertTrue(gone.wait(2))  # the first on_eof stays in charge

    def test_a_pipe_is_refused(self):
        read, write = os.pipe()
        self.addCleanup(os.close, read)
        self.addCleanup(os.close, write)
        with self.assertRaises(OSError):
            self.control.start({}, on_eof=lambda: None, fd=read)


if __name__ == "__main__":
    unittest.main()
