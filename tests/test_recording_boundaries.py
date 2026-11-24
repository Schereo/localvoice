from contextlib import ExitStack, redirect_stdout
import fcntl
import io
import logging
import os
from pathlib import Path
import sys
import tempfile
import threading
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch


PATCH = Path(__file__).resolve().parents[1] / "patches" / "ctrlspeak-1.8.0"


def stub(name, **attributes):
    module = ModuleType(name)
    module.__dict__.update(attributes)
    return module


class Samples(list):
    ndim = 1
    dtype = float

    def copy(self):
        return Samples(self)

    def __pow__(self, exponent):
        return Samples(x ** exponent for x in self)

    def __getitem__(self, index):
        result = super().__getitem__(index)
        return Samples(result) if isinstance(index, slice) else result

    def flatten(self):
        return self

    def astype(self, *_args, **_kwargs):
        return self

    def tolist(self):
        return list(self)


def concatenate(chunks):
    return Samples(x for chunk in chunks for x in chunk)


class RecordingBoundaryTests(unittest.TestCase):
    def setUp(self):
        contexts = ExitStack()
        self.addCleanup(contexts.close)
        contexts.enter_context(patch.object(sys, "path", [str(PATCH), *sys.path]))
        self.temp = Path(contexts.enter_context(tempfile.TemporaryDirectory()))
        contexts.enter_context(
            patch.dict(os.environ, {"LOCALVOICE_SESSION_LOCK": "", "TMPDIR": str(self.temp)})
        )
        contexts.enter_context(patch.object(tempfile, "tempdir", str(self.temp)))
        self.stdout = contexts.enter_context(redirect_stdout(io.StringIO()))
        self.vad_model = Mock(return_value=Mock(item=lambda: 0.9))
        self.vad_loader = Mock(return_value=self.vad_model)
        self.clipboard = Mock(return_value=True)
        self.paste = Mock(return_value=True)
        self.history = Mock()
        self.beep = Mock()
        self.resume = Mock()
        self.fake_torch = stub("torch", from_numpy=lambda _: Mock())
        models = stub("models", __path__=[str(PATCH / "models")])
        modules = {
            "utils": stub("utils", __path__=[str(PATCH / "utils")]),
            "utils.localvoice_vad": stub("utils.localvoice_vad", load_local_vad=self.vad_loader),
            "utils.media_pause": stub("utils.media_pause", resume_paused=self.resume),
            "utils.clipboard": stub("utils.clipboard", copy_to_clipboard=self.clipboard,
                                    paste_from_clipboard=self.paste, type_text=Mock(return_value=False)),
            "utils.player": stub("utils.player", play_start_beep=Mock(), play_stop_beep=self.beep),
            "utils.history": stub("utils.history", get_history_manager=Mock(return_value=self.history)),
            "sounddevice": stub("sounddevice"),
            "soundfile": stub("soundfile", write=Mock()),
            "torch": self.fake_torch,
            "numpy": stub("numpy", ndarray=Samples, float32=float,
                          array=lambda values, **_: Samples(values), concatenate=concatenate,
                          sqrt=lambda x: x ** 0.5, mean=lambda xs: sum(xs) / len(xs)),
            "rich": stub("rich", __path__=[], print=Mock()),
            "rich.console": stub("rich.console", Console=Mock),
            "rich.progress": stub("rich.progress", Progress=Mock, SpinnerColumn=Mock,
                                  TextColumn=Mock, BarColumn=Mock, TimeRemainingColumn=Mock),
            "rich.panel": stub("rich.panel", Panel=Mock()),
            "rich.style": stub("rich.style", Style=Mock),
            "rich.live": stub("rich.live", Live=Mock),
            "rich.text": stub("rich.text", Text=Mock),
            "models": models,
            "models.base_model": stub(
                "models.base_model", BaseSTTModel=type(
                    "BaseSTTModel", (), {"_clean_text": lambda _, text: text.strip()}
                ),
            ),
        }
        contexts.enter_context(patch.dict(sys.modules, modules))
        for name in ("state", "hotkeys", "transcription", "utils.audio",
                     "utils.localvoice_config", "models.whisper_mlx"):
            sys.modules.pop(name, None)
        import hotkeys
        import state
        import transcription
        from utils import audio, localvoice_config

        self.hotkeys, self.state, self.worker = hotkeys, state, transcription
        self.audio, self.config = audio, localvoice_config
        self.hotkeys._start_recording_overlay = Mock()
        self.hotkeys._show_start_error = Mock()
        self.config.as_bool = Mock(return_value=False)
        self.state.model_loaded = True
        self.state.console.print.side_effect = AssertionError("unexpected console output")
        self.addCleanup(self.hotkeys._release_session_lock)
        self.manager = self.make_manager()

    def make_manager(self):
        self.state.audio_manager = manager = self.audio.AudioManager(self.state.transcription_queue)
        manager.open_input_stream = Mock()
        manager.close_input_stream = Mock()
        return manager

    def start_worker(self, model):
        self.state.stt_model = model
        work = self.state.transcription_queue
        thread = threading.Thread(
            target=self.worker.transcription_worker,
            args=(model, work, self.state.transcribed_chunks, "en", "en"),
            daemon=True,
        )
        thread.start()

        def shutdown():
            work.put(None)
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
            self.assertEqual(work.unfinished_tasks, 0)
            self.assertEqual(list(self.temp.glob("*.wav")), [])

        self.addCleanup(shutdown)

    def test_pcm_backend_keeps_audio_off_disk(self):
        samples = Samples([0.1, 0.2])
        backend = SimpleNamespace(transcribe_pcm=Mock(return_value="recognized"))
        with patch.object(self.worker.tempfile, "NamedTemporaryFile") as temp_file:
            self.assertEqual(self.worker._transcribe_audio(backend, samples), "recognized")
        backend.transcribe_pcm.assert_called_once_with(samples, self.state.source_lang, self.state.target_lang)
        temp_file.assert_not_called()

    def test_managed_language_is_per_model_and_applies_between_recordings(self):
        config = self.temp / "config"
        config.write_text(
            "language = en\nlanguage.whisper-turbo-q4 = de\n"
            "language.nemotron-streaming = en\nlanguage.qwen3-asr-1.7b = de\n"
            "language.parakeet-v3 = de\n"
            "language.whisper-turbo-fp16 = unknown\n"
        )
        model = Mock(supports_streaming=False)
        model.transcribe_pcm.return_value = "recognized"
        self.start_worker(model)
        with patch.object(self.config, "CONFIG_FILE", config), patch.dict(
            os.environ, {"LOCALVOICE_MODEL_ID": "whisper-turbo-q4"}
        ):
            self.assertEqual(self.config.model_language("nemotron-streaming"), "en")
            self.assertEqual(self.config.model_language("qwen3-asr-1.7b"), "de")
            self.assertEqual(self.config.model_language("parakeet-v3"), "auto")
            self.assertEqual(self.config.model_language("whisper-turbo-fp16"), "auto")
            self.hotkeys._start_recording()
            config.write_text("language.whisper-turbo-q4 = en\n")
            for expected in ("de", "en"):
                self.manager.audio_buffer.append(Samples([0.2] * 8_000))
                self.hotkeys._end_recording(self.manager.recording_id)
                self.assertEqual(model.transcribe_pcm.call_args.args[1:], (expected, expected))
                if expected == "de":
                    self.hotkeys._start_recording()

    def test_mono_capture_columns_are_normalized_for_in_memory_decode(self):
        class MonoCapture(Samples):
            ndim = 2
            shape = (2, 1)

            def __getitem__(self, index):
                if index == (slice(None), 0):
                    return Samples(frame[0] for frame in self)
                return super().__getitem__(index)

        backend = SimpleNamespace(transcribe_pcm=Mock(return_value="recognized"))
        audio = MonoCapture([[0.1], [0.2]])
        self.assertEqual(self.worker._transcribe_audio(backend, audio), "recognized")
        backend.transcribe_pcm.assert_called_once_with(
            Samples([0.1, 0.2]), self.state.source_lang, self.state.target_lang,
        )

    def test_decode_error_is_not_reported_as_silence(self):
        model = Mock(supports_streaming=False)
        model.transcribe_pcm.side_effect = OverflowError("private exception payload")
        self.start_worker(model)
        self.hotkeys._start_recording()
        self.manager.audio_buffer.append(Samples([0.2] * 8_000))
        with patch.object(self.hotkeys, "_set_overlay_state") as status, self.assertLogs("ctrlspeak") as logs:
            self.hotkeys._end_recording(self.manager.recording_id)
        status.assert_called_with("failed")
        self.clipboard.assert_not_called()
        self.assertIn("OverflowError", str(logs.output))
        self.assertNotIn("private exception payload", str(logs.output))

    def test_stop_freezes_before_close_beep_resume_and_drain(self):
        text = "literal [/markup] [link=bad]\nsensitive words"
        model = Mock(transcribe_pcm=None)
        model.supports_streaming = False
        model.transcribe_batch.return_value = [text]
        self.start_worker(model)
        events = []

        def close():
            self.assertFalse(self.manager.is_collecting)
            events.append("close")
            # This frame may arrive between freeze and process teardown.
            self.manager.audio_callback(Samples([0.5] * 1024), 1024, None, None)

        def write(_path, audio, _rate):
            self.assertEqual(len(audio), 8_000)
            events.append("tail")

        self.manager.close_input_stream.side_effect = close
        self.beep.side_effect = lambda: events.append("beep")
        self.resume.side_effect = lambda: events.append("resume")
        self.audio.sf.write.side_effect = write
        self.clipboard.side_effect = lambda _: events.append("clipboard") or True
        self.hotkeys._start_recording()
        self.manager.audio_buffer.append(Samples([0.1] * 8_000))
        with self.assertLogs("ctrlspeak", level="DEBUG") as captured:
            logging.getLogger("ctrlspeak").debug("Test log capture.")
            self.hotkeys._end_recording(self.manager.recording_id)

        self.assertEqual(events, ["close", "beep", "resume", "tail", "clipboard"])
        self.clipboard.assert_called_once_with(text)
        self.history.add_entry.assert_called_once()
        self.assertEqual(self.history.add_entry.call_args.kwargs["text"], text)
        self.assertNotIn("sensitive words", "\n".join(captured.output))
        self.assertEqual(self.stdout.getvalue(), "")

    def test_escape_drops_queued_audio_and_late_decode_without_waiting(self):
        entered, unblock = threading.Event(), threading.Event()
        self.addCleanup(unblock.set)
        model = Mock(supports_streaming=False, transcribe_pcm=None)

        def decode(*_args, **_kwargs):
            if not entered.is_set():
                entered.set()
                if not unblock.wait(2):
                    raise RuntimeError("test timeout")
                return ["old result"]
            return ["new result"]

        model.transcribe_batch.side_effect = decode
        self.start_worker(model)
        self.hotkeys._start_recording()
        old_id = self.manager.recording_id
        self.manager._queue_segment(Samples([0.2]))
        self.assertTrue(entered.wait(1))
        self.manager._queue_segment(Samples([0.3]))
        self.state.transcription_queue.put(self.state.TranscriptionJob(old_id, "preview", Samples([0.4])))
        self.manager.audio_buffer.append(Samples([0.1] * 8_000))
        try:
            self.hotkeys._end_recording(old_id, discard=True)
            self.assertEqual(self.state.transcription_queue.unfinished_tasks, 1)
            self.assertEqual(self.manager.audio_buffer, [])
            self.assertFalse(self.manager.is_collecting)
            self.manager.close_input_stream.assert_called_once()
            self.clipboard.assert_not_called()
            self.history.add_entry.assert_not_called()
            self.assertEqual(self.state.transcribed_chunks, [])
            self.hotkeys._start_recording()
            self.hotkeys._end_recording(old_id, discard=True)  # delayed command
            self.assertTrue(self.manager.is_collecting)
            self.manager.audio_buffer.append(Samples([0.5] * 8_000))
        finally:
            unblock.set()
        self.hotkeys._end_recording(self.manager.recording_id)
        self.clipboard.assert_called_once_with("new result")
        self.assertEqual(model.transcribe_batch.call_count, 2)
        self.assertEqual(self.state.transcribed_chunks, ["new result"])

    def test_standby_and_streaming_cancel_never_finalize_or_close(self):
        model = Mock(supports_streaming=True, chunk_size_ms=1120)
        self.start_worker(model)
        self.state.mic_standby = True
        self.hotkeys._start_recording()
        self.manager.audio_callback(Samples([0.2] * 1024), 1024, None, None)
        self.assertTrue(self.manager._streaming_buffer)
        self.hotkeys._end_recording(self.manager.recording_id, discard=True)
        model.finalize_streaming.assert_not_called()
        model.stream_chunk.assert_not_called()
        self.manager.open_input_stream.assert_not_called()
        self.manager.close_input_stream.assert_not_called()
        self.assertEqual(self.manager._streaming_buffer, [])

    def test_in_flight_preview_cannot_publish_into_next_recording(self):
        entered, unblock = threading.Event(), threading.Event()

        def decode(*_args, **_kwargs):
            entered.set()
            unblock.wait(2)
            return ["stale preview"]

        model = Mock(supports_streaming=False, transcribe_pcm=None)
        model.transcribe_batch.side_effect = decode
        self.start_worker(model)
        self.hotkeys._start_recording()
        self.state.live_preview_active = True
        old_id = self.manager.recording_id
        with patch.object(self.hotkeys, "set_overlay_transcript") as preview:
            self.state.transcription_queue.put(
                self.state.TranscriptionJob(old_id, "preview", Samples([0.5]), 0)
            )
            try:
                self.assertTrue(entered.wait(1))
                self.hotkeys._end_recording(old_id, discard=True)
                self.hotkeys._start_recording()
                self.state.live_preview_active = True
            finally:
                unblock.set()
            self.state.transcription_queue.join()
            preview.assert_not_called()

    def test_streaming_stop_decodes_tail_after_close_and_resume(self):
        # A legacy model selection may change the current streaming backend
        # without replacing the persistent worker.
        self.start_worker(Mock(supports_streaming=False))
        backend_log = logging.getLogger("synthetic_backend")
        backend = type("SyntheticBackend", (), {"__module__": "models.synthetic"})
        model = self.state.stt_model = backend()
        model.supports_streaming = True
        model.chunk_size_ms = 1120
        model.init_streaming = Mock()
        events = []
        self.manager.close_input_stream.side_effect = lambda: events.append("close")
        self.resume.side_effect = lambda: events.append("resume")

        def finalize():
            events.append("final")
            backend_log.info("sensitive result")
            return "complete [literal]"

        model.stream_chunk = Mock(side_effect=lambda *_a, **_k: events.append("tail") or "partial")
        model.finalize_streaming = Mock(side_effect=finalize)
        with (
            patch.dict(sys.modules, {"models.synthetic": stub("models.synthetic", logger=backend_log)}),
            self.assertLogs("synthetic_backend", "INFO") as captured,
        ):
            self.hotkeys._start_recording()
            self.manager.audio_callback(Samples([0.2] * 1024), 1024, None, None)
            self.hotkeys._end_recording(self.manager.recording_id)
            backend_log.info("ordinary status")
        self.assertEqual(captured.output, ["INFO:synthetic_backend:ordinary status"])
        self.assertEqual(events, ["close", "resume", "tail", "final"])
        model.init_streaming.assert_called_once()
        model.stream_chunk.assert_called_once()
        self.assertTrue(model.stream_chunk.call_args.kwargs["is_final"])
        self.clipboard.assert_called_once_with("complete [literal]")

    def test_streaming_partial_reaches_overlay_before_final_delivery(self):
        model = Mock(supports_streaming=True, chunk_size_ms=64)
        model.stream_chunk.return_value = "live partial"
        model.finalize_streaming.return_value = "finished text"
        self.start_worker(model)
        self.config.as_bool.side_effect = lambda key: key == "live-preview"
        with patch.object(self.hotkeys, "set_overlay_transcript") as preview:
            self.hotkeys._start_recording()
            self.manager.audio_callback(Samples([0.2] * 1024), 1024, None, None)
            self.state.transcription_queue.join()
            preview.assert_called_once_with(partial="live partial")
            self.clipboard.assert_not_called()
            self.hotkeys._end_recording(self.manager.recording_id)
        self.clipboard.assert_called_once_with("finished text")

    def test_session_lock_rejects_contention_and_survives_until_delivery(self):
        path = self.temp / "session.lock"
        os.environ["LOCALVOICE_SESSION_LOCK"] = str(path)
        with path.open("a") as launcher:
            fcntl.flock(launcher, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.hotkeys._start_recording()
            self.hotkeys._show_start_error.assert_called_once()
            self.manager.open_input_stream.assert_not_called()
            fcntl.flock(launcher, fcntl.LOCK_UN)
            model = Mock(supports_streaming=False, transcribe_pcm=None)
            model.transcribe_batch.return_value = ["secret"]
            self.start_worker(model)
            self.hotkeys._start_recording()
            self.manager.audio_buffer.append(Samples([0.5] * 8_000))

            def fail_copy(_text):
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(launcher, fcntl.LOCK_EX | fcntl.LOCK_NB)
                raise ValueError("secret")

            self.clipboard.side_effect = fail_copy
            self.resume.side_effect = ValueError("secret")
            with self.assertLogs("ctrlspeak", "WARNING") as capture:
                self.hotkeys._end_recording(self.manager.recording_id)
            self.assertNotIn("secret", "\n".join(capture.output))
            self.history.add_entry.assert_called_once()
            fcntl.flock(launcher, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_session_lock_released_after_open_failure_and_cancel(self):
        path = self.temp / "session.lock"
        os.environ["LOCALVOICE_SESSION_LOCK"] = str(path)
        self.manager.open_input_stream.side_effect = OSError("open failed")
        with self.assertLogs("ctrlspeak.hotkeys", "ERROR"):
            self.hotkeys._start_recording()
        with path.open("a") as launcher:
            fcntl.flock(launcher, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(launcher, fcntl.LOCK_UN)
            self.manager.open_input_stream.side_effect = None
            self.hotkeys._start_recording()
            self.hotkeys._end_recording(self.manager.recording_id, discard=True)
            fcntl.flock(launcher, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_vad_load_and_inference_failures_use_bounded_fallback(self):
        self.vad_loader.assert_called_once_with(self.fake_torch)
        for bad_asset in (True, False):
            with self.subTest(bad_asset=bad_asset):
                self.vad_loader.side_effect = ValueError("fixture") if bad_asset else None
                self.vad_model.side_effect = RuntimeError("fixture")
                with self.assertLogs("ctrlspeak.audio", level="WARNING") as captured:
                    manager = self.make_manager()
                    manager.FALLBACK_SEGMENT_S = 0.1
                    manager.start_recording()
                    for _ in range(3):
                        manager.audio_callback(Samples([0.1] * 1024), 1024, None, None)
                self.assertIsNone(manager._vad_model)
                self.assertEqual(len(captured.output), 1)
                self.assertEqual(manager.transcription_queue.qsize(), 1)
                self.worker.discard_pending_jobs(manager.transcription_queue)
                self.assertLess(len(manager.audio_buffer), 2)

    def test_whisper_filter_and_vocabulary_diagnostics_never_log_words(self):
        from models.whisper_mlx import WhisperMLXModel

        model = object.__new__(WhisperMLXModel)
        model.model = object()
        model.model_name = "synthetic"
        fake_whisper = stub("mlx_whisper", transcribe=Mock(side_effect=[
            {"segments": [
                {"text": "loop-private", "start": 0, "end": 2, "compression_ratio": 3},
                {"text": "non-speech-private", "no_speech_prob": 0.9},
                {"text": "vocabulary-private another-private"},
            ]},
            RuntimeError("retry-private"),
        ]))
        with (
            patch.dict(sys.modules, {"mlx_whisper": fake_whisper}),
            patch.object(self.config, "effective",
                         return_value="vocabulary-private<|endoftext|>, another-private"),
            self.assertLogs(level="DEBUG") as captured,
        ):
            self.assertEqual(
                model._transcribe_batch(["synthetic.wav"], "en", "en"),
                ["loop-private vocabulary-private another-private"],
            )
        self.assertNotIn("-private", "\n".join(captured.output))
        self.assertEqual(
            fake_whisper.transcribe.call_args_list[0].kwargs["initial_prompt"],
            "vocabulary-private, another-private",
        )

    def test_managed_whisper_loads_local_only_and_refuses_disappearing_dir(self):
        from models.whisper_mlx import WhisperMLXModel

        model = object.__new__(WhisperMLXModel)
        local_model = self.temp / "verified-weights"
        model.model_name = str(local_model)
        model.model = None
        holder = Mock()
        mx = stub("mlx.core", float16=object())
        whisper = stub("mlx_whisper", __path__=[], transcribe=Mock(return_value={"text": "speech"}))
        with (
            patch.dict(sys.modules, {
                "mlx": stub("mlx", __path__=[], core=mx),
                "mlx.core": mx,
                "mlx_whisper": whisper,
                "mlx_whisper.transcribe": stub("mlx_whisper.transcribe", ModelHolder=holder),
                "model_download": None,  # A managed load must not even import this.
            }),
            patch.object(self.config, "vocabulary", return_value=[]),
        ):
            with self.assertRaises(FileNotFoundError):
                model.load_model()
            holder.get_model.assert_not_called()
            local_model.mkdir()
            self.assertIs(model.load_model(), holder.get_model.return_value)
            holder.get_model.assert_called_once_with(str(local_model), mx.float16)
            self.assertEqual(model._transcribe_batch(["synthetic.wav"], "en", "en"), ["speech"])
            self.assertEqual(whisper.transcribe.call_args.kwargs["path_or_hf_repo"], str(local_model))
            local_model.rmdir()
            with self.assertRaises(FileNotFoundError):
                model._transcribe_batch(["synthetic.wav"], "en", "en")
            whisper.transcribe.assert_called_once()

    def test_managed_qwen_loads_local_only_maps_language_and_passes_vocabulary(self):
        from models.qwen3_asr_mlx import Qwen3ASRMLXModel

        local_model = self.temp / "verified-qwen"
        model = Qwen3ASRMLXModel(local_model)
        session = Mock()
        session.transcribe.return_value = SimpleNamespace(text=" Hallo Qwen. ")
        session_class = Mock(return_value=session)
        mx = stub("mlx.core", clear_cache=Mock())
        samples = Samples([0.2] * 1_600)
        with (
            patch.dict(sys.modules, {
                "mlx": stub("mlx", __path__=[], core=mx),
                "mlx.core": mx,
                "mlx_qwen3_asr": stub("mlx_qwen3_asr", Session=session_class),
            }),
            patch.object(self.config, "vocabulary", return_value=["Qwen", "LocalVoice"]),
        ):
            # Without a verified directory the Hub fallback must never be reached.
            with self.assertRaises(FileNotFoundError):
                model.transcribe_pcm(samples, "de", "de")
            session_class.assert_not_called()
            local_model.mkdir()
            (local_model / "config.json").write_text("{}")
            self.assertEqual(model.transcribe_pcm(samples, "de", "de"), "Hallo Qwen.")
            session_class.assert_called_once_with(str(local_model))
            self.assertEqual(session.transcribe.call_args.kwargs,
                             {"language": "German", "context": "Qwen, LocalVoice"})
            model.transcribe_pcm(samples, "auto", "auto")
            self.assertIsNone(session.transcribe.call_args.kwargs["language"])
            self.assertEqual(mx.clear_cache.call_count, 2)
            # A read-back of the context on silence is not dictation.
            session.transcribe.return_value = SimpleNamespace(text="Qwen, LocalVoice")
            self.assertEqual(model.transcribe_pcm(samples, "en", "en"), "")
            with self.assertRaises(ValueError):
                model.transcribe_pcm(samples, "fr", "fr")
            session_class.assert_called_once()
