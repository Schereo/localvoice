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
                          zeros=lambda n, **_: Samples([0.0] * n),
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

    def capture_manager(self, standby_body):
        """A real AudioManager whose capture child is a fake mic_capture.py."""
        script = self.temp / "fake_capture.py"
        log = self.temp / "capture.log"
        script.write_text(
            "import sys, time\n"
            f"log = open({str(log)!r}, 'a')\n"
            "if sys.argv[4] == '--standby':\n"
            "    print('standby', file=sys.stderr, flush=True)\n"
            f"{standby_body}"
            "else:\n"
            "    log.write('new ' + sys.argv[4] + '\\n'); log.flush()\n"
            "print('ready', file=sys.stderr, flush=True)\n"
            "time.sleep(30)\n"
        )
        manager = self.audio.AudioManager(self.state.transcription_queue)
        manager._mic_command = lambda device: [sys.executable, str(script), "16000", "1", "1024", device]
        manager.input_device = "MacBook Air-Mikrofon"
        self.addCleanup(manager.discard_standby_mic)
        self.addCleanup(manager.close_input_stream)
        return manager, log

    def test_recording_opens_the_device_in_the_prewarmed_capture_child(self):
        manager, log = self.capture_manager(
            "    log.write('standby ' + sys.stdin.readline()); log.flush()\n"
        )
        manager.prewarm_input_stream()
        standby = manager._standby_mic
        manager.open_input_stream(prepare_next=True)
        self.assertIs(manager._mic_process, standby)
        self.assertEqual(log.read_text(), "standby open MacBook Air-Mikrofon\n")
        # The next recording gets its own standby child, prepared in the background.
        for _ in range(100):
            if manager._standby_mic is not None:
                break
            threading.Event().wait(0.02)
        self.assertIsNotNone(manager._standby_mic)
        self.assertIsNot(manager._standby_mic, standby)
        manager.close_input_stream()
        self.assertIsNotNone(standby.poll())

    def test_recording_pill_is_the_prepared_standby_overlay(self):
        script = self.temp / "fake_overlay.py"
        log = self.temp / "overlay.log"
        script.write_text(
            "#!" + sys.executable + "\n"
            "import sys\n"
            f"log = open({str(log)!r}, 'a')\n"
            "log.write('start ' + ' '.join(sys.argv[1:]) + '\\n'); log.flush()\n"
            "for line in sys.stdin:\n"
            "    if not line.startswith('level'):\n"
            "        log.write(line); log.flush()\n"
            "    if line.strip() == 'quit':\n"
            "        break\n"
        )
        script.chmod(0o755)
        with patch.object(self.hotkeys, "_OVERLAY_PATH", str(script)):
            self.state.source_lang = "en"
            self.hotkeys.prepare_overlay()
            standby = self.hotkeys._standby_overlay
            session = self.hotkeys._OverlaySession("de")
            session.start()
            session.close()
            session.thread.join(timeout=3)
        self.assertIsNone(self.hotkeys._standby_overlay)
        self.assertEqual(standby.wait(timeout=3), 0)
        self.assertEqual(log.read_text(), "start standby en\nshow de\nquit\n")

    def test_dead_standby_child_falls_back_to_a_new_capture_process(self):
        # Dies after taking the open line, before reporting: always the fallback path.
        manager, log = self.capture_manager("    sys.stdin.readline(); sys.exit(0)\n")
        manager.prewarm_input_stream()
        with self.assertLogs("ctrlspeak.audio", "WARNING"):
            manager.open_input_stream()
        self.assertEqual(log.read_text(), "new MacBook Air-Mikrofon\n")
        self.assertIsNone(manager._standby_mic)

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
        sys.modules["soundfile"].write.side_effect = write
        self.clipboard.side_effect = lambda _: events.append("clipboard") or True
        self.hotkeys._start_recording()
        self.manager.audio_buffer.append(Samples([0.1] * 8_000))
        with self.assertLogs("ctrlspeak", level="DEBUG") as captured:
            logging.getLogger("ctrlspeak").debug("Test log capture.")
            self.hotkeys._end_recording(self.manager.recording_id)
        self.hotkeys._media_queue.join()

        # Resuming media runs beside the transcription, never in front of it.
        self.assertEqual([e for e in events if e != "resume"], ["close", "beep", "tail", "clipboard"])
        self.assertEqual(events.count("resume"), 1)
        self.assertLess(events.index("close"), events.index("resume"))
        self.clipboard.assert_called_once_with(text)
        self.history.add_entry.assert_called_once()
        self.assertEqual(self.history.add_entry.call_args.kwargs["text"], text)
        self.assertNotIn("sensitive words", "\n".join(captured.output))
        self.assertEqual(self.stdout.getvalue(), "")

    def test_media_pause_runs_beside_the_microphone_open_and_capture_waits_for_it(self):
        events = []

        def pause():
            threading.Event().wait(0.1)
            events.append("paused")

        self.hotkeys.media_pause.pause_playing = pause
        self.hotkeys.media_pause.paused_any = lambda: True
        self.resume.side_effect = lambda: events.append("resume")
        self.config.as_bool = Mock(side_effect=lambda key: key == "pause-media")
        self.manager.open_input_stream.side_effect = lambda **_: events.append("open")
        self.manager._onset_buffer.append(Samples([0.4] * 1024))  # music before the pause
        self.manager._onset_samples = 1024
        original = self.manager.start_recording
        self.manager.start_recording = lambda: (events.append("capture"), original())
        self.hotkeys._start_recording()
        self.assertEqual(events, ["open", "paused", "capture"])
        self.assertEqual(len(self.manager._onset_buffer), 0)
        self.hotkeys._end_recording(self.manager.recording_id, discard=True)
        self.hotkeys._media_queue.join()
        self.assertEqual(events, ["open", "paused", "capture", "resume"])

    def test_pill_appears_only_once_capture_is_live(self):
        self.hotkeys._start_recording_overlay.side_effect = (
            lambda: self.assertTrue(self.manager.is_collecting))
        self.hotkeys._start_recording()
        self.hotkeys._start_recording_overlay.assert_called_once()
        self.manager.open_input_stream.side_effect = OSError("no microphone")
        self.hotkeys._end_recording(self.manager.recording_id, discard=True)
        with self.assertLogs("ctrlspeak.hotkeys", "ERROR"):
            self.hotkeys._start_recording()
        self.hotkeys._start_recording_overlay.assert_called_once()

    def test_language_change_drops_a_preview_decoded_in_the_old_language(self):
        model = Mock(supports_streaming=False, supports_forced_language=True,
                     transcribe_pcm=Mock(side_effect=lambda _a, lang, _t: f"text-{lang}"))
        self.start_worker(model)
        self.hotkeys._start_recording()
        manager = self.manager
        manager.audio_buffer.extend(Samples([0.3] * 1024) for _ in range(10))
        self.state.source_lang = "de"
        self.state.transcription_queue.put(self.state.TranscriptionJob(
            manager.recording_id, "preview", concatenate(manager.audio_buffer),
            manager.segments_queued, preview_chunks=10))
        self.state.transcription_queue.join()
        self.assertIsNotNone(self.state.last_preview)
        with patch.object(self.config, "set_value"):
            self.hotkeys._apply_language("en")
        manager.quiet_tail_chunks = 0
        self.hotkeys._end_recording(manager.recording_id)
        self.clipboard.assert_called_once_with("text-en")

    def test_silence_cut_reuses_the_pause_decode_through_real_capture(self):
        manager = self.manager
        manager._get_speech_probability = lambda chunk: 0.9 if max(abs(x) for x in chunk) > 0.1 else 0.0
        manager.recording_id += 1
        manager.set_is_collecting(True)
        work = self.state.transcription_queue

        def feed(level, count):
            for _ in range(count):
                manager.audio_callback(Samples([level] * 1024), 1024, None, None)

        feed(0.3, 10)
        feed(0.001, 4)
        self.assertEqual((len(manager.audio_buffer), manager.quiet_tail_chunks), (14, 4))
        feed(0.05, 1)  # not speech to VAD, but too loud to count as quiet
        self.assertEqual(manager.quiet_tail_chunks, 0)
        feed(0.001, 4)
        self.state.last_preview = (manager.recording_id, 0, 19, "Ganzer Satz.")
        feed(0.001, 12)  # reaches the one-second cut
        job = work.get_nowait()
        work.task_done()
        self.assertEqual((job.kind, job.text), ("resolved", "Ganzer Satz."))
        self.assertEqual(manager.segments_queued, 1)
        self.assertIsNone(self.state.last_preview)
        self.assertEqual(manager.quiet_tail_chunks, 0)
        manager.set_is_collecting(False)

    def test_prewarm_racing_mic_standby_cannot_revive_a_discarded_child(self):
        manager, _log = self.capture_manager("    sys.stdin.readline()\n")
        manager.discard_standby_mic()
        manager._prewarm_if_wanted()  # the background prewarm of an earlier open
        self.assertIsNone(manager._standby_mic)
        manager.prewarm_input_stream()  # explicit: standby turned off again
        self.assertIsNotNone(manager._standby_mic)

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

    def preview_then_stop(self, decode, after_preview, *, block=None):
        """Record ten speech chunks, preview them whole, then stop."""
        model = Mock(supports_streaming=False, transcribe_pcm=Mock(side_effect=decode))
        self.start_worker(model)
        self.hotkeys._start_recording()
        self.state.live_preview_active = True
        manager = self.manager
        manager.audio_buffer.extend(Samples([0.3] * 1024) for _ in range(10))
        with patch.object(self.hotkeys, "set_overlay_transcript"):
            self.state.transcription_queue.put(self.state.TranscriptionJob(
                manager.recording_id, "preview", concatenate(manager.audio_buffer),
                manager.segments_queued, preview_chunks=10,
            ))
            if block is None:
                self.state.transcription_queue.join()
            after_preview(manager)
            self.hotkeys._end_recording(manager.recording_id)
        return model

    def test_stop_reuses_a_whole_segment_preview_when_only_quiet_audio_followed(self):
        def quiet_tail(manager):
            manager.audio_buffer.extend(Samples([0.001] * 1024) for _ in range(3))
            manager.quiet_tail_chunks = 3

        model = self.preview_then_stop(lambda *_: "Fertiger Satz.", quiet_tail)
        model.transcribe_pcm.assert_called_once()
        self.clipboard.assert_called_once_with("Fertiger Satz.")

    def test_stop_decodes_the_tail_when_anything_but_quiet_followed_the_preview(self):
        texts = iter(["Fertiger", "Fertiger Satz, und noch mehr."])

        def more_speech(manager):
            manager.audio_buffer.extend(Samples([0.3] * 1024) for _ in range(3))
            manager.quiet_tail_chunks = 1  # only the last chunk was quiet

        model = self.preview_then_stop(lambda *_: next(texts), more_speech)
        self.assertEqual(model.transcribe_pcm.call_count, 2)
        self.clipboard.assert_called_once_with("Fertiger Satz, und noch mehr.")

    def test_preview_still_decoding_at_stop_is_used_once_it_finishes(self):
        entered, unblock = threading.Event(), threading.Event()

        def decode(*_args):
            entered.set()
            unblock.wait(2)
            return "Gerade noch rechtzeitig."

        def stop_mid_preview(manager):
            self.assertTrue(entered.wait(1))
            # Stop arrives while the preview decodes; let it finish shortly after.
            threading.Timer(0.05, unblock.set).start()

        model = self.preview_then_stop(decode, stop_mid_preview, block=True)
        model.transcribe_pcm.assert_called_once()
        self.clipboard.assert_called_once_with("Gerade noch rechtzeitig.")

    def test_pause_in_speech_starts_one_whole_segment_decode_without_live_preview(self):
        manager = self.manager
        manager.recording_id += 1
        manager.set_is_collecting(True)
        self.state.live_preview_active = False
        work = self.state.transcription_queue

        def next_job():
            for _ in range(100):
                if not work.empty():
                    job = work.get_nowait()
                    work.task_done()
                    return job
                threading.Event().wait(0.01)
            return None

        with patch.object(self.hotkeys, "SEGMENT_TICK_S", 0.005):
            ticker = threading.Thread(
                target=self.hotkeys._segment_ticker, args=(manager, manager.recording_id), daemon=True
            )
            with manager.capture_lock:
                manager.audio_buffer.extend(Samples([0.3] * 1024) for _ in range(12))
                manager.quiet_tail_chunks = 3
            ticker.start()
            threading.Event().wait(0.05)
            self.assertTrue(work.empty())  # still speaking, as far as anyone knows
            with manager.capture_lock:
                manager.audio_buffer.append(Samples([0.001] * 1024))
                manager.quiet_tail_chunks = 4
            job = next_job()
            self.assertEqual((job.kind, job.preview_chunks, job.preview_segment), ("preview", 13, 0))
            threading.Event().wait(0.05)
            self.assertTrue(work.empty())  # once per pause
            with manager.capture_lock:
                manager.audio_buffer.extend(Samples([0.3] * 1024) for _ in range(3))
                manager.quiet_tail_chunks = 0
                manager.audio_buffer.extend(Samples([0.001] * 1024) for _ in range(4))
                manager.quiet_tail_chunks = 4
            self.assertEqual(next_job().preview_chunks, 20)
            manager.set_is_collecting(False)
            ticker.join(timeout=1)
        self.assertFalse(ticker.is_alive())

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
        self.hotkeys._media_queue.join()
        self.assertEqual(captured.output, ["INFO:synthetic_backend:ordinary status"])
        self.assertEqual([e for e in events if e != "resume"], ["close", "tail", "final"])
        self.assertEqual(events.count("resume"), 1)
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
                self.hotkeys._media_queue.join()
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
        self.vad_loader.assert_called_once_with()
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

    def test_mic_command_prefers_native_helper_when_executable(self):
        helper = self.temp / "ctrlspeak-mic"
        helper.write_text("#!/bin/sh\n")
        helper.chmod(0o755)
        with patch.dict(os.environ, {"CTRLSPEAK_MIC_PATH": str(helper)}):
            cmd = self.manager._mic_command("--standby")
        self.assertEqual(cmd[0], str(helper))
        self.assertEqual(cmd[-1], "--standby")
        with patch.dict(os.environ, {"CTRLSPEAK_MIC_PATH": str(self.temp / "missing")}):
            fallback = self.manager._mic_command("--standby")
        self.assertEqual(fallback[0], sys.executable)
        self.assertTrue(fallback[1].endswith("mic_capture.py"))

    def test_config_load_caches_by_stat_and_invalidates_on_edit(self):
        config = self.temp / "cached-config"
        config.write_text("language = de\n")
        with patch.object(self.config, "CONFIG_FILE", config):
            self.assertEqual(self.config.load()["language"], "de")
            self.assertEqual(self.config.load()["language"], "de")
            config.write_text("language = en\ncompact = on\n")
            loaded = self.config.load()
            self.assertEqual(loaded["language"], "en")
            self.assertEqual(loaded["compact"], "on")

    def test_media_pause_skips_osascript_when_no_player_is_running(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("real_media_pause", PATCH / "utils/media_pause.py")
        mp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mp)
        with (
            patch.object(mp, "_running_players", return_value=[]),
            patch.object(mp, "_osascript") as run_osa,
        ):
            mp.pause_playing()
        run_osa.assert_not_called()
        self.assertFalse(mp.paused_any())

    def test_persistent_overlay_reuses_same_process_across_recordings(self):
        script = self.temp / "fake_persistent_overlay.py"
        log = self.temp / "persistent_overlay.log"
        script.write_text(
            "#!" + sys.executable + "\n"
            "import sys\n"
            f"log = open({str(log)!r}, 'a')\n"
            "log.write('start ' + ' '.join(sys.argv[1:]) + '\\n'); log.flush()\n"
            "for line in sys.stdin:\n"
            "    if not line.startswith('level'):\n"
            "        log.write(line); log.flush()\n"
            "    if line.strip() == 'quit':\n"
            "        break\n"
        )
        script.chmod(0o755)
        with patch.object(self.hotkeys, "_OVERLAY_PATH", str(script)):
            self.hotkeys._overlay_session = None
            self.state.source_lang = "de"
            self.hotkeys.prepare_overlay()
            standby = self.hotkeys._standby_overlay
            # Call the real _start_recording_overlay directly via hotkeys module.
            session = self.hotkeys._OverlaySession("de")
            self.hotkeys._overlay_session = session
            session.start()
            session.set_state("success")
            # Wait briefly so state success moves loop into reusable standby.
            threading.Event().wait(0.05)
            self.assertTrue(session.is_reusable_and_alive())
            session.show("en")
            session.close()
            session.thread.join(timeout=3)
            self.hotkeys._overlay_session = None
        self.assertEqual(standby.wait(timeout=3), 0)
        self.assertEqual(log.read_text(), "start standby de\nshow de\nstate success\nshow en\nquit\n")

    def test_deferred_worker_runs_silent_warmup_after_load(self):
        model = SimpleNamespace(
            deferred_load=True,
            supports_streaming=False,
            supports_forced_language=True,
            load_model=Mock(),
            transcribe_pcm=Mock(return_value=""),
        )
        self.state.model_loaded = False
        self.state.source_lang = "auto"
        self.start_worker(model)
        self.assertTrue(self.state.model_loaded_event.wait(timeout=2))
        for _ in range(100):
            if model.transcribe_pcm.called:
                break
            threading.Event().wait(0.01)
        model.load_model.assert_called_once()
        model.transcribe_pcm.assert_called_once()
        samples, src, tgt = model.transcribe_pcm.call_args.args
        self.assertEqual((len(samples), src, tgt), (8_000, "de", "de"))

    def test_idle_unload_releases_model_and_preload_reloads(self):
        unloaded = threading.Event()
        reloaded = threading.Event()

        def do_unload():
            unloaded.set()

        def do_load():
            if unloaded.is_set():
                reloaded.set()

        model = SimpleNamespace(
            deferred_load=True,
            supports_streaming=False,
            supports_forced_language=True,
            load_model=Mock(side_effect=do_load),
            unload_model=Mock(side_effect=do_unload),
            transcribe_pcm=Mock(return_value="ok"),
        )
        self.state.model_loaded = False
        self.state.model_unloaded = False
        with patch.object(sys.modules["transcription"], "_idle_unload_seconds", return_value=0.05):
            self.start_worker(model)
            self.assertTrue(self.state.model_loaded_event.wait(timeout=2))
            self.assertTrue(unloaded.wait(timeout=2), "Model should unload after idle timeout")
            self.assertTrue(self.state.model_unloaded)
            # Trigger background preload as _start_recording() does.
            self.state.transcription_queue.put(self.state.TranscriptionJob(1, "preload"))
            self.assertTrue(reloaded.wait(timeout=2), "Preload job should reload unloaded model")
            self.assertFalse(self.state.model_unloaded)
            self.assertEqual(model.load_model.call_count, 2)

    def test_embedded_overlay_socket_skips_subprocess(self):
        import socket
        with tempfile.TemporaryDirectory() as tmp:
            sock_path = str(Path(tmp) / "o.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(sock_path)
            server.listen(1)
            received = []
            done = threading.Event()

            def serve():
                conn, _ = server.accept()
                with conn:
                    f = conn.makefile("r", encoding="utf-8")
                    for line in f:
                        received.append(line.strip())
                        if line.strip() == "quit":
                            break
                done.set()

            srv_thread = threading.Thread(target=serve, daemon=True)
            srv_thread.start()
            try:
                with patch.dict(os.environ, {"LOCALVOICE_OVERLAY_SOCKET": sock_path}):
                    with patch.object(self.hotkeys.subprocess, "Popen") as popen:
                        self.hotkeys.prepare_overlay()
                        popen.assert_not_called()
                        session = self.hotkeys._OverlaySession("de")
                        session.start()
                        session.set_state("success")
                        threading.Event().wait(0.05)
                        session.show("en")
                        session.close()
                        session.thread.join(timeout=3)
                        popen.assert_not_called()
                self.assertTrue(done.wait(timeout=3))
            finally:
                server.close()
            self.assertIn("show de", received)
            self.assertIn("state success", received)
            self.assertIn("show en", received)
            self.assertEqual(received[-1], "quit")

    def test_native_sound_player_does_not_require_sounddevice(self):
        import importlib.util
        player_path = Path(__file__).resolve().parents[1] / "patches/ctrlspeak-1.8.0/utils/player.py"
        spec = importlib.util.spec_from_file_location("localvoice_player_test", player_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        fake_copy = Mock()
        fake_sound = Mock()
        fake_sound.copy.return_value = fake_copy
        fake_nssound = Mock()
        fake_nssound.alloc.return_value.initWithContentsOfFile_byReference_.return_value = fake_sound
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "on.wav").write_bytes(b"RIFF")
            (Path(tmp) / "off.wav").write_bytes(b"RIFF")
            p = mod.SoundPlayer()
            p.base_dir = tmp
            with patch.dict(sys.modules, {"AppKit": SimpleNamespace(NSSound=fake_nssound), "sounddevice": None}):
                p.play("start")
                p.play("stop")
            self.assertEqual(fake_copy.play.call_count, 2)
