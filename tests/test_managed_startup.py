from contextlib import ExitStack
import importlib.util
import os
from pathlib import Path
import queue
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch


PATCH = Path(__file__).resolve().parents[1] / "patches" / "ctrlspeak-1.8.0"


def stub(name, **attributes):
    module = ModuleType(name)
    module.__dict__.update(attributes)
    return module


def load_patch(name):
    spec = importlib.util.spec_from_file_location(name, PATCH / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class ManagedStartupTests(unittest.TestCase):
    def setUp(self):
        contexts = ExitStack()
        self.addCleanup(contexts.close)
        temp = Path(contexts.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.model_path = temp / "verified"
        self.model_path.mkdir()
        self.ready = temp / "ready"
        contexts.enter_context(patch.dict(os.environ, {
            "LOCALVOICE_MODEL_ID": "whisper-turbo-q4",
            "LOCALVOICE_READY_FILE": str(self.ready),
            "LOCALVOICE_PERMISSIONS_PREFLIGHT": "0",
            "HF_HUB_OFFLINE": "0",
        }))
        self.events = []
        self.args = SimpleNamespace(
            model="ignored-legacy-model", debug=False, check_only=False,
            source_lang="de", target_lang="de", no_history=True, history_db=None,
            check_compatibility=False, list_models=False,
        )

        self.state = stub(
            "state", console=Mock(), KNOWN_MODELS=(), transcription_queue=queue.Queue(),
            audio_manager=None, keyboard_manager=None, transcription_worker_thread=None,
            transcribed_chunks=[], model_loaded=False, stt_model=None, main_loop_active=True,
        )
        self.resolve_model = Mock(side_effect=self._resolve_model)
        self.permissions = Mock(side_effect=self._permissions)
        self.set_preferred_model = Mock()
        self.audio = Mock(is_collecting=False)
        self.start_listening = Mock(side_effect=self._start_listening)
        self.listener_wait = Mock(side_effect=self._listener_wait)
        self.keyboard = Mock(
            start_listening=self.start_listening,
            key_listener=Mock(wait=self.listener_wait, is_alive=Mock(return_value=True)),
            hotkey_listener=None,
        )
        self.whisper = Mock(side_effect=self._whisper)
        self.parakeet_worker = Mock(return_value=temp / "localvoice-parakeet")
        self.worker = Mock(side_effect=self._worker)
        self.app_control = stub(
            "app_control", enabled=lambda: os.environ.get("LOCALVOICE_HOTKEYS") == "app",
            listen=Mock(side_effect=lambda *_, **__: self.events.append("app listen")),
            start=Mock(side_effect=lambda *_, **__: self.events.append("app channel")),
            publish_recording=Mock(),
        )
        contexts.enter_context(patch.dict(sys.modules, {
            # Forbid any dependency on the legacy path or heavyweight libraries.
            **dict.fromkeys(("models.factory", "models.registry", "huggingface_hub", "torch", "mlx", "ui")),
            "state": self.state,
            "rich": stub("rich", __path__=[]),
            "rich.console": stub("rich.console", Console=Mock),
            "rich.panel": stub("rich.panel", Panel=Mock()),
            "cli": stub("cli", parse_args_only=lambda: self.args),
            "environment": stub("environment", save_environment_variables=dict,
                                restore_environment_variables=lambda _: None),
            "logging_config": stub("logging_config", setup_logging=lambda: None,
                                   setup_logging_for_mode=lambda _: None),
            "permissions": stub("permissions", check_permissions=self.permissions),
            "utils": stub("utils", __path__=[], localvoice_config=SimpleNamespace(
                 ensure_config_file=Mock(), language=lambda: "de", model_language=lambda _: "auto",
                effective=lambda _: "system", as_bool=lambda _: False,
            )),
            "utils.config": stub("utils.config", is_first_run=Mock(), mark_first_run_complete=Mock(),
                                 set_preferred_model=self.set_preferred_model),
            "utils.tqdm_lock": stub("utils.tqdm_lock", ensure_tqdm_thread_lock=lambda: None),
            "utils.audio": stub("utils.audio", AudioManager=Mock(return_value=self.audio),
                                resolve_input_device=lambda _: None),
            "utils.keyboard_shortcuts": stub(
                "utils.keyboard_shortcuts", KeyboardShortcutManager=Mock(return_value=self.keyboard),
            ),
            "transcription": stub("transcription", transcription_worker=self.worker),
            "app_control": self.app_control,
            "hotkeys": stub("hotkeys", on_activate=Mock(), is_recording=Mock(),
                            cancel_recording=Mock(), finish_recording=Mock(), open_config=Mock()),
            "localvoice_models": stub("localvoice_models", resolve_model=self.resolve_model,
                                      parakeet_worker_path=self.parakeet_worker),
            "models.whisper_mlx": stub("models.whisper_mlx", WhisperMLXModel=self.whisper),
        }))
        load_patch("model_loader")
        self.app = load_patch("ctrlspeak")
        self.app._acquire_single_instance_lock = lambda: True
        self.app._hide_from_dock = Mock()

        def start_watcher():
            # End the (normally indefinite) headless loop after readiness.
            self.events.append("watcher")

        self.app._start_config_watcher = start_watcher
        original_write = self.app._write_ready_file

        def write_ready(path):
            self.events.append("ready")
            original_write(path)
            self.state.main_loop_active = False

        self.app._write_ready_file = write_ready

    def _resolve_model(self, model_id):
        self.events.append("verify")
        self.assertEqual(os.environ["HF_HUB_OFFLINE"], "1")
        self.assertIn(model_id, {"whisper-turbo-fp16", "whisper-turbo-q4", "parakeet-v3"})
        return self.model_path

    def _permissions(self):
        self.events.append("permissions")
        return True

    def _whisper(self, **_):
        self.events.append("create")
        return object()

    def _worker(self, model, work_queue, *_):
        self.events.append("load")
        self.state.model_loaded = True
        work_queue.get(timeout=2)

    def _start_listening(self):
        self.events.append("hotkeys")
        return True

    def _listener_wait(self):
        self.events.append("event tap")

    def test_managed_load_publishes_pid_after_listener_readiness(self):
        # Managed mode stays headless even when launched from a terminal.
        with patch.object(sys.stdout, "isatty", return_value=True):
            self.assertIsNone(self.app.main())
        self.assertEqual(self.events, [
            "verify", "create", "load", "permissions", "hotkeys", "event tap", "watcher", "ready",
        ])
        self.resolve_model.assert_called_once_with("whisper-turbo-q4")
        self.whisper.assert_called_once_with(model_name=str(self.model_path), verbose=False)
        self.assertEqual(self.state.model_type, "whisper-turbo-q4")
        self.assertEqual((self.state.source_lang, self.state.target_lang), ("auto", "auto"))
        self.assertFalse(self.state.history_enabled)
        self.assertEqual(self.ready.read_text(), f"{os.getpid()}\n")
        self.assertEqual(set(self.ready.parent.iterdir()), {self.model_path, self.ready})
        self.set_preferred_model.assert_not_called()
        self.audio.open_input_stream.assert_not_called()

    def test_parakeet_routes_to_coreml_and_keeps_language_automatic(self):
        test = self

        class ParakeetFixture:
            def __init__(self, model_id, model_path, worker):
                test.assertEqual((model_id, model_path, worker), (
                    "parakeet-v3", test.model_path, test.parakeet_worker.return_value,
                ))
                self.closed = False

            def close(self):
                self.closed = True

        os.environ["LOCALVOICE_MODEL_ID"] = "parakeet-v3"
        with patch("models.parakeet_coreml.ParakeetCoreMLModel", ParakeetFixture):
            self.assertIsNone(self.app.main())
        self.parakeet_worker.assert_called_once_with("parakeet-v3")
        self.whisper.assert_not_called()
        self.assertEqual((self.state.source_lang, self.state.target_lang), ("auto", "auto"))
        self.assertEqual(self.ready.read_text(), f"{os.getpid()}\n")
        self.assertTrue(self.state.stt_model.closed)

    def test_invalid_store_result_is_permanent_and_never_opens_mic(self):
        for result in (Path("relative"), self.ready, ValueError("invalid model ID")):
            with self.subTest(result=result):
                if isinstance(result, Exception):
                    self.resolve_model.side_effect = result
                else:
                    self.resolve_model.side_effect = None
                    self.resolve_model.return_value = result
                self.assertEqual(self.app.main(), 78)
        self.whisper.assert_not_called()
        self.worker.assert_not_called()
        self.permissions.assert_not_called()
        self.start_listening.assert_not_called()
        self.audio.open_input_stream.assert_not_called()
        self.assertFalse(self.ready.exists())

    def test_unloadable_weights_are_permanent_and_never_open_mic(self):
        self.worker.side_effect = None  # worker exits before setting model_loaded
        self.assertEqual(self.app.main(), 78)
        self.permissions.assert_not_called()
        self.start_listening.assert_not_called()
        self.audio.open_input_stream.assert_not_called()
        self.assertFalse(self.ready.exists())

    def test_missing_permissions_preserve_orderly_exit(self):
        self.permissions.side_effect = SystemExit(1)
        self.assertEqual(self.app.main(), 0)
        self.start_listening.assert_not_called()
        self.assertFalse(self.ready.exists())

    def test_native_permission_preflight_does_not_open_the_legacy_prompt(self):
        os.environ["LOCALVOICE_PERMISSIONS_PREFLIGHT"] = "1"
        self.assertIsNone(self.app.main())
        self.permissions.assert_not_called()
        self.audio.open_input_stream.assert_not_called()
        self.start_listening.assert_called_once()
        self.assertTrue(self.ready.is_file())

    def test_failed_hotkey_start_does_not_publish_readiness(self):
        self.start_listening.side_effect = None
        self.start_listening.return_value = False
        self.assertEqual(self.app.main(), 1)
        self.listener_wait.assert_not_called()
        self.assertFalse(self.ready.exists())

    def test_dead_listener_does_not_publish_readiness(self):
        self.keyboard.key_listener.is_alive.return_value = False
        self.assertEqual(self.app.main(), 1)
        self.assertFalse(self.ready.exists())

    def test_app_owned_shortcuts_replace_the_listener(self):
        os.environ["LOCALVOICE_HOTKEYS"] = "app"
        keyboard_manager = sys.modules["utils.keyboard_shortcuts"].KeyboardShortcutManager
        self.assertIsNone(self.app.main())
        # EOF is heard from before the model loads, commands only once ready.
        self.assertEqual(self.events[0], "app listen")
        self.assertEqual(self.events[1:], [
            "verify", "create", "load", "permissions", "app channel", "watcher", "ready",
        ])
        keyboard_manager.assert_not_called()
        self.assertIsNone(self.state.keyboard_manager)
        commands = self.app_control.start.call_args.args[0]
        self.assertEqual(set(commands), {"toggle", "finish", "discard", "quit"})
        self.assertIs(self.audio.on_collecting_changed, self.app_control.publish_recording)
        self.assertTrue(self.ready.is_file())

    def test_unusable_app_channel_does_not_publish_readiness(self):
        os.environ["LOCALVOICE_HOTKEYS"] = "app"
        self.app_control.start.side_effect = OSError("not a socket")
        self.assertEqual(self.app.main(), 1)
        self.assertFalse(self.ready.exists())

    def test_ready_file_is_optional(self):
        os.environ.pop("LOCALVOICE_READY_FILE")
        self.app._start_config_watcher = lambda: setattr(self.state, "main_loop_active", False)
        self.assertIsNone(self.app.main())
        self.start_listening.assert_called_once()
        self.assertFalse(self.ready.exists())

    def test_managed_check_only_validates_without_loading(self):
        self.args.check_only = True
        os.environ["LOCALVOICE_MODEL_ID"] = "whisper-turbo-fp16"
        self.assertEqual(self.app.main(), 0)
        self.resolve_model.assert_called_once_with("whisper-turbo-fp16")
        self.whisper.assert_not_called()
        self.permissions.assert_not_called()
        self.assertFalse(self.ready.exists())


if __name__ == "__main__":
    unittest.main()
