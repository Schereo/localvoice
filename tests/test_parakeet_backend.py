import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "parakeet_coreml", ROOT / "patches/ctrlspeak-1.8.0/models/parakeet_coreml.py"
)
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)


class Samples(list):
    ndim = 1

    def __getitem__(self, index):
        value = super().__getitem__(index)
        return Samples(value) if isinstance(index, slice) else value

    def astype(self, dtype, *, copy):
        assert dtype == "<f4" and not copy
        return self

    def tobytes(self):
        import struct
        return struct.pack(f"<{len(self)}f", *self)


class BackendTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)

    def worker(self, content):
        executable = self.root / "decoder"
        executable.write_text(f"#!{sys.executable}\n{content}")
        executable.chmod(0o700)
        return executable

    def test_pipe_round_trip_and_process_cleanup(self):
        worker = self.worker("""
import base64, json, struct, sys
assert sys.argv[1] == 'ultra'
print('{"event":"ready"}', flush=True)
for line in sys.stdin:
    audio = base64.b64decode(json.loads(line)['pcm'])
    assert struct.unpack('<3f', audio) == (0.0, 0.5, -0.5)
    print('{"event":"result","text":" decoded "}', flush=True)
""")
        model = backend.ParakeetCoreMLModel("parakeet-ultra", self.root, worker=worker)
        self.addCleanup(model.close)
        model.load_model()
        process = model.process
        for _ in range(2):
            self.assertEqual(model.transcribe_pcm(Samples([0.0, 0.5, -0.5]), "auto", "auto"),
                             "decoded")
        self.assertIs(model.process, process)
        model.close()
        self.assertIsNotNone(process.poll())

    def test_initialization_failure_reaps_child(self):
        worker = self.worker('print(\'{"event":"error"}\', flush=True)')
        model = backend.ParakeetCoreMLModel("parakeet-v3", self.root, worker=worker)
        with self.assertRaisesRegex(RuntimeError, "could not load"):
            model.load_model()
        self.assertIsNone(model.process)

    def test_nemotron_stream_starts_emits_partial_and_resets_next_recording(self):
        worker = self.worker("""
import json, sys
assert sys.argv[1] == 'nemotron'
print('{"event":"ready"}', flush=True)
session, n = None, 0
for line in sys.stdin:
    request = json.loads(line)
    command = request['command']
    if command == 'start':
        session, n = request['language'], 0
        text = ''
    elif command == 'chunk':
        assert session and request['pcm']
        n += 1
        text = f'{session} partial {n}'
    elif command == 'finish':
        text = f'{session} final {n}'
        session = None
    else:
        raise AssertionError(command)
    print(json.dumps({'event': 'result', 'text': text}), flush=True)
""")
        model = backend.NemotronCoreMLModel(backend.NEMOTRON, self.root, worker=worker)
        self.addCleanup(model.close)
        model.load_model()
        model.init_streaming("de")
        self.assertEqual(model.stream_chunk(Samples([0.3])), "de partial 1")
        self.assertEqual(model.stream_chunk(Samples([0.4])), "de partial 2")
        # Escape does not finalize/publish the old session.
        model.init_streaming("en")
        self.assertEqual(model.stream_chunk(Samples([0.7])), "en partial 1")
        self.assertEqual(model.finalize_streaming(), "en final 1")
