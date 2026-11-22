"""Run with python3 -m unittest discover -s tests -p test_model_store.py."""

from contextlib import ExitStack, redirect_stdout
import hashlib
from http.client import IncompleteRead
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.request import Request


SCRIPT = Path(__file__).resolve().parents[1] / "patches/ctrlspeak-1.8.0/localvoice_models.py"
spec = importlib.util.spec_from_file_location("localvoice_models", SCRIPT)
store = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = store
spec.loader.exec_module(store)


class ModelStoreTests(unittest.TestCase):
    def setUp(self):
        stack = ExitStack()
        self.stack = stack
        self.addCleanup(stack.close)
        temporary = stack.enter_context(tempfile.TemporaryDirectory())
        self.root = Path(temporary).resolve()
        self.app = self.root / "App Models"
        self.hub = self.root / "HF Cache"
        self.env = {"HOME": str(self.root), "LOCALVOICE_MODELS_DIR": str(self.app),
                    "HF_HUB_CACHE": str(self.hub)}
        stack.enter_context(patch.dict(os.environ, self.env, clear=True))
        self.data = {"config.json": b'{"model_type":"whisper"}', "weights.npz": b"fake weights"}
        q4 = store.MODELS["whisper-turbo-q4"]
        self.model = store.Model(q4.id, q4.name, q4.repo, q4.revision, tuple(
            store.Asset(name, len(data), hashlib.sha256(data).hexdigest())
            for name, data in self.data.items()
        ))
        stack.enter_context(patch.dict(store.MODELS, {self.model.id: self.model}))
        store._digest.cache_clear()
        self.addCleanup(store._digest.cache_clear)

    def cli(self, command, *args):
        out = io.StringIO()
        with redirect_stdout(out):
            code = store.main([command, *args])
        return code, [json.loads(line) for line in out.getvalue().splitlines()]

    def install(self):
        def transport(url, *, timeout):
            prefix = f"https://huggingface.co/{self.model.repo}/resolve/{self.model.revision}/"
            self.assertTrue(url.startswith(prefix), url)
            name = url[len(prefix):]
            self.assertGreater(timeout, 0)
            self.assertFalse((self.app / self.model.id).exists())
            return io.BytesIO(self.data[name])

        with patch.object(store, "_open_https", side_effect=transport) as opener:
            code, messages = self.cli("download", self.model.id)
        self.assertEqual(code, 0, messages)
        self.assertEqual(opener.call_count, len(self.data))
        return messages

    def legacy_snapshot(self, revision=None):
        repo = self.hub / ("models--" + self.model.repo.replace("/", "--"))
        blobs = repo / "blobs"
        blobs.mkdir(parents=True, exist_ok=True)
        snapshot = repo / "snapshots" / (revision or self.model.revision)
        snapshot.mkdir(parents=True)
        for name, data in self.data.items():
            blob = blobs / hashlib.sha256(data).hexdigest()
            blob.write_bytes(data)
            path = snapshot / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(os.path.relpath(blob, path.parent))
        return snapshot

    def status_row(self):
        code, [result] = self.cli("status")
        self.assertEqual(code, 0)
        return next(row for row in result["models"] if row["id"] == self.model.id)

    def assert_no_staging(self):
        self.assertEqual(list(self.app.glob(f".{self.model.id}.download-*")), [])

    def test_public_catalog_in_clean_subprocess(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "status"], env=self.env,
            capture_output=True, text=True, check=True,
        )
        rows = json.loads(result.stdout)["models"]
        self.assertEqual(
            [(row["id"], row["bytes"], row["status"]) for row in rows],
            [("whisper-turbo-fp16", 1_613_977_880, "not-installed"),
             ("whisper-turbo-q4", 463_665_005, "not-installed"),
             ("parakeet-v3", 483_105_645, "not-installed"),
             ("parakeet-ultra", 632_162_964, "not-installed"),
             ("parakeet-redux", 220_304_193, "not-installed"),
             ("nemotron-streaming", 615_434_988, "not-installed")],
        )
        for row in rows:
            self.assertEqual(row["available"], row["id"].startswith("whisper-"))
            self.assertIsInstance(row["available"], bool)
            self.assertIsInstance(row["availability_reason"], str)
            self.assertEqual(bool(row["availability_reason"]), not row["available"])
        self.assertFalse(self.app.exists())

    def use_worker_model(self, model_id="parakeet-redux"):
        self.data = ({
            "multilingual/2240ms/encoder.mlmodelc/weights/weight.bin": b"fake encoder weights",
            "multilingual/2240ms/decoder_joint.mlmodelc/weights/weight.bin": b"fake fused decoder weights",
            "multilingual/2240ms/metadata.json": b'{"chunk_mel_frames":224}',
            "multilingual/2240ms/tokenizer.json": b"{}",
        } if model_id == "nemotron-streaming" else {
            "Encoder.mlmodelc/model.mil": b"fake compiled graph",
            "Encoder.mlmodelc/weights/weight.bin": b"fake nested weights",
            "parakeet_vocab.json": b"{}",
        })
        original = store.MODELS[model_id]
        self.model = store.Model(original.id, original.name, original.repo, original.revision,
                                 tuple(store.Asset(name, len(data), hashlib.sha256(data).hexdigest())
                                       for name, data in self.data.items()),
                                 minimum_macos=original.minimum_macos,
                                 allow_matching_hf_revisions=original.allow_matching_hf_revisions)
        self.stack.enter_context(patch.dict(store.MODELS, {self.model.id: self.model}))
        self.stack.enter_context(patch.object(store.sys, "platform", "darwin"))
        self.machine = self.stack.enter_context(patch.object(store.platform, "machine", return_value="arm64"))
        self.mac_ver = self.stack.enter_context(patch.object(store.platform, "mac_ver",
                                                            return_value=("15.0", (), "arm64")))
        self.worker = self.root / "Parakeet Worker"
        self.worker.write_text("#!/bin/sh\n")
        self.worker.chmod(0o700)
        os.environ["LOCALVOICE_PARAKEET_WORKER"] = str(self.worker)

    def test_parakeet_manifest_revisions_components_and_weights(self):
        expected = {
            "parakeet-v3": ("parakeet-tdt-0.6b-v3-coreml", "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
                            445187200, "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            "parakeet-ultra": ("parakeet-ultra-coreml", "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
                               594211328, "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"),
            "parakeet-redux": ("parakeet-redux-coreml", "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9",
                               182389312, "adbb5550dc6488717d3a1407b53122fbdb1af5e99c330ee20f8d8cfd9ec49252"),
        }
        for model_id, (repo, revision, size, digest) in expected.items():
            with self.subTest(model_id=model_id):
                model = store.MODELS[model_id]
                self.assertEqual((model.repo, model.revision), (f"FluidInference/{repo}", revision))
                by_path = {asset.name: asset for asset in model.assets}
                self.assertEqual(len(by_path), len(model.assets))
                paths = {"parakeet_vocab.json"}
                for bundle in ("Encoder", "Preprocessor", "Decoder", "JointDecisionv3"):
                    for leaf in ("analytics/coremldata.bin", "coremldata.bin", "model.mil", "weights/weight.bin"):
                        paths.add(f"{bundle}.mlmodelc/{leaf}")
                    if model_id == "parakeet-v3" or bundle == "Preprocessor":
                        paths.add(f"{bundle}.mlmodelc/metadata.json")
                self.assertEqual(set(by_path), paths)
                weight = by_path["Encoder.mlmodelc/weights/weight.bin"]
                self.assertEqual((weight.size, weight.sha256), (size, digest))
                for asset in model.assets:
                    self.assertGreater(asset.size, 0)
                    self.assertRegex(asset.sha256, "^[0-9a-f]{64}$")

    def test_parakeet_capability_gates_download_not_offline_resolution(self):
        self.use_worker_model()
        self.assertTrue(self.status_row()["available"])
        self.assertEqual(self.status_row()["availability_reason"], "")
        self.assertEqual(store.parakeet_worker_path(self.model.id), self.worker)
        with patch.object(store, "_open_https", side_effect=AssertionError("network")):
            for reason, machine, version, worker in (
                ("Apple Silicon", "x86_64", "15.0", self.worker),
                ("macOS 15", "arm64", "14.7", self.worker),
                ("not configured", "arm64", "15.0", ""),
                ("not executable", "arm64", "15.0", self.root),
            ):
                with self.subTest(reason=reason):
                    self.machine.return_value = machine
                    self.mac_ver.return_value = (version, (), machine)
                    os.environ["LOCALVOICE_PARAKEET_WORKER"] = str(worker)
                    row = self.status_row()
                    self.assertFalse(row["available"])
                    self.assertIn(reason, row["availability_reason"])
                    code, [error] = self.cli("download", self.model.id)
                    self.assertNotEqual(code, 0)
                    self.assertIn(reason, error["error"])
                    self.assertFalse(self.app.exists())
            snapshot = self.legacy_snapshot()
            self.assertEqual(store.resolve_model(self.model.id), snapshot)
            self.assertEqual(self.cli("resolve", self.model.id)[0], 0)
            self.assertEqual(self.status_row()["status"], "installed")
            self.assertFalse(self.status_row()["available"])
            self.mac_ver.return_value = ("14.7", (), "arm64")
            os.environ["LOCALVOICE_PARAKEET_WORKER"] = str(self.worker)
            self.assertEqual(store.parakeet_worker_path("parakeet-v3"), self.worker)
            self.assertEqual(store.parakeet_worker_path("parakeet-ultra"), self.worker)

    def test_nemotron_manifest_is_the_minimal_pinned_multilingual_tier(self):
        model = store.MODELS["nemotron-streaming"]
        self.assertEqual(model.repo, "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML")
        self.assertEqual(model.revision, "a70b9d1c33594f1f4cf3f4eca9b4a0a8f44a9f59")
        by_path = {asset.name: asset for asset in model.assets}
        sizes = {"metadata.json": 3005, "tokenizer.json": 284969}
        for bundle, coremldata_size, graph_size, weights_size in (
            ("encoder", 573, 1010788, 565336640),
            ("decoder_joint", 454, 15801, 48782272),
        ):
            sizes.update({f"{bundle}.mlmodelc/{leaf}": size for leaf, size in (
                ("analytics/coremldata.bin", 243),
                ("coremldata.bin", coremldata_size),
                ("model.mil", graph_size),
                ("weights/weight.bin", weights_size),
            )})
        self.assertEqual(len(by_path), len(model.assets))
        self.assertEqual({path: asset.size for path, asset in by_path.items()},
                         {f"multilingual/2240ms/{path}": size for path, size in sizes.items()})
        for asset in model.assets:
            self.assertRegex(asset.sha256, "^[0-9a-f]{64}$")
        self.assertEqual(
            by_path["multilingual/2240ms/encoder.mlmodelc/weights/weight.bin"].sha256,
            "2e00be98049a22e095452c020f183d2b23728e145cc814ba031436931b4f2e8f",
        )
        self.assertEqual(
            by_path["multilingual/2240ms/decoder_joint.mlmodelc/weights/weight.bin"].sha256,
            "01f21eb747fbc53bd0ed7efebea1bf0aa655ebf2816f21d0bb6554c9b7fcfc0b",
        )

    def test_nemotron_explicit_download_requires_worker_and_preserves_tier(self):
        self.use_worker_model("nemotron-streaming")
        self.mac_ver.return_value = ("13.6", (), "arm64")
        with patch.object(store, "_open_https", side_effect=AssertionError("network")):
            row = self.status_row()
            self.assertFalse(row["available"])
            self.assertIn("macOS 14", row["availability_reason"])
            code, [error] = self.cli("download", self.model.id)
            self.assertNotEqual(code, 0)
            self.assertIn("macOS 14", error["error"])
            self.assertFalse(self.app.exists())
        self.mac_ver.return_value = ("14.0", (), "arm64")
        self.assertTrue(self.status_row()["available"])
        self.assertEqual(store.coreml_worker_path(self.model.id), self.worker)
        self.assertEqual(store.parakeet_worker_path(self.model.id), self.worker)
        *progress, success = self.install()
        self.assertEqual(progress[-1]["downloaded_bytes"], self.model.size)
        root = self.app / self.model.id
        self.assertEqual(success["path"], str(root))
        for name, data in self.data.items():
            self.assertEqual((root / name).read_bytes(), data)
        self.assertEqual(store.resolve_model(self.model.id), root)
        tier = root / "multilingual/2240ms"
        shadow = tier / "decoder_joint_argmax.mlpackage"
        shadow.mkdir()
        self.assertEqual(self.status_row()["status"], "not-installed")
        self.assertFalse(self.status_row()["removable"])
        self.assertNotEqual(self.cli("remove", self.model.id)[0], 0)
        self.assertTrue(shadow.is_dir())
        shadow.rmdir()
        self.assertTrue(self.cli("remove", self.model.id)[1][0]["removed"])
        self.assertFalse(root.exists())

    def test_nemotron_hf_cache_accepts_only_the_pinned_verified_tier_without_worker(self):
        self.use_worker_model("nemotron-streaming")
        self.legacy_snapshot("d" * 40)
        del os.environ["LOCALVOICE_PARAKEET_WORKER"]
        with patch.object(store, "_open_https", side_effect=AssertionError("network")):
            self.assertEqual(self.status_row()["status"], "not-installed")
            with self.assertRaisesRegex(store.ModelStoreError, "not installed"):
                store.resolve_model(self.model.id)
            snapshot = self.legacy_snapshot()
            self.assertFalse(self.status_row()["available"])
            self.assertEqual(store.resolve_model(self.model.id), snapshot)
            (snapshot / "multilingual/2240ms/tokenizer.json").unlink()
            with self.assertRaisesRegex(store.ModelStoreError, "not installed"):
                store.resolve_model(self.model.id)
        self.assertFalse(self.app.exists())

    def test_nested_install_repair_and_remove(self):
        self.use_worker_model()
        *progress, success = self.install()
        self.assertEqual(progress[-1]["downloaded_bytes"], self.model.size)
        destination = self.app / self.model.id
        self.assertEqual(success["path"], str(destination))
        self.assertEqual(store.resolve_model(self.model.id), destination)
        for name, data in self.data.items():
            self.assertEqual((destination / name).read_bytes(), data)
        (destination / "Encoder.mlmodelc/weights/weight.bin").unlink()
        self.assertEqual(self.status_row()["status"], "not-installed")
        self.assertTrue(self.status_row()["removable"])
        with patch.object(store, "_open_https", side_effect=[io.BytesIO(data) for data in self.data.values()]):
            self.assertEqual(self.cli("download", self.model.id)[0], 0)
        self.assertEqual(store.resolve_model(self.model.id), destination)
        self.assert_no_staging()
        del os.environ["LOCALVOICE_PARAKEET_WORKER"]
        self.assertTrue(self.cli("remove", self.model.id)[1][0]["removed"])
        self.assertFalse(destination.exists())

    def test_nested_unexpected_files_and_symlinks_are_not_verified_or_removed(self):
        self.use_worker_model()
        self.install()
        destination = self.app / self.model.id
        weights_dir = destination / "Encoder.mlmodelc/weights"
        leaf = weights_dir / "weight.bin"
        extra = weights_dir / "unexpected"
        extra.write_bytes(b"keep me")
        self.assertFalse(self.status_row()["removable"])
        self.assertEqual(self.status_row()["status"], "not-installed")
        self.assertNotEqual(self.cli("remove", self.model.id)[0], 0)
        self.assertEqual(extra.read_bytes(), b"keep me")
        extra.unlink()
        external = self.root / "external"
        weights_dir.rename(external)
        weights_dir.symlink_to(external, target_is_directory=True)
        self.assertEqual(self.status_row()["status"], "not-installed")
        self.assertNotEqual(self.cli("remove", self.model.id)[0], 0)
        self.assertTrue(leaf.exists())
        weights_dir.unlink()
        weights_dir.mkdir()
        leaf.symlink_to(external / leaf.name)
        self.assertEqual(self.status_row()["status"], "not-installed")
        self.assertNotEqual(self.cli("remove", self.model.id)[0], 0)
        self.assertTrue(leaf.is_symlink())
        self.assertEqual((external / leaf.name).read_bytes(), self.data[str(leaf.relative_to(destination))])

    def test_nested_hf_cache_links_and_ctc_shadowing(self):
        self.use_worker_model()
        snapshot = self.legacy_snapshot()
        self.assertEqual(store.resolve_model(self.model.id), snapshot)
        shadow = snapshot / "CtcHead.mlmodelc"
        shadow.symlink_to(self.root / "missing")
        self.assertEqual(self.status_row()["status"], "not-installed")
        shadow.unlink()
        leaf = snapshot / "Encoder.mlmodelc/weights/weight.bin"
        blob = leaf.resolve()
        external = self.root / "external"
        blob.rename(external)
        blob.symlink_to(external)
        self.assertEqual(self.status_row()["status"], "not-installed")
        blob.unlink()
        external.rename(blob)
        self.assertEqual(store.resolve_model(self.model.id), snapshot)
        self.assertIn("shared Hugging Face cache", self.cli("remove", self.model.id)[1][0]["error"])

    def test_manifest_asset_paths_cannot_escape_staging(self):
        for name in ("", "../escape", "/absolute", "bundle/../escape", "bundle//file", ".localvoice-model"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Invalid model asset path"):
                store.Asset(name, 0, "")

    def test_missing_is_offline_and_read_only(self):
        with patch.object(store, "_open_https", side_effect=AssertionError("network")):
            self.assertEqual(self.status_row()["status"], "not-installed")
            with self.assertRaisesRegex(store.ModelStoreError, "not installed"):
                store.resolve_model(self.model.id)
            code, [error] = self.cli("resolve", self.model.id)
        self.assertNotEqual(code, 0)
        self.assertEqual(error["event"], "error")
        self.assertEqual(error["id"], self.model.id)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.hub.exists())

    def test_unknown_id_fails_all_model_commands(self):
        with patch.object(store, "_open_https", side_effect=AssertionError("network")):
            for command in ("download", "resolve", "remove"):
                with self.subTest(command=command):
                    code, [error] = self.cli(command, "../arbitrary")
                    self.assertNotEqual(code, 0)
                    self.assertFalse(error["ok"])
                    self.assertIn("Unknown model ID", error["error"])
        self.assertFalse(self.app.exists())

    def test_download_progress_resolve_and_remove(self):
        *progress, success = self.install()
        self.assertEqual(success["event"], "success")
        self.assertTrue(success["ok"])
        self.assertEqual(success["location"], "localvoice")
        self.assertEqual(progress[0]["downloaded_bytes"], 0)
        self.assertEqual(progress[-1]["downloaded_bytes"], self.model.size)
        self.assertEqual([p["downloaded_bytes"] for p in progress],
                         sorted(p["downloaded_bytes"] for p in progress))
        for message in progress:
            self.assertEqual(message["event"], "progress")
            self.assertEqual(message["id"], self.model.id)
            self.assertEqual(message["total_bytes"], self.model.size)
        destination = self.app / self.model.id
        self.assertEqual(store.resolve_model(self.model.id), destination)
        self.assertEqual(self.cli("resolve", self.model.id), (0, [success]))
        row = self.status_row()
        self.assertEqual(row["status"], "installed")
        self.assertEqual(row["path"], str(destination))
        self.assertEqual(row["source"], self.model.repo)
        self.assertTrue(row["removable"])
        self.assert_no_staging()
        with patch.object(store, "_open_https", side_effect=AssertionError("network")):
            self.assertEqual(self.cli("download", self.model.id), (0, [success]))
        self.assertTrue(self.cli("remove", self.model.id)[1][0]["removed"])
        self.assertFalse(destination.exists())
        self.assertFalse(self.cli("remove", self.model.id)[1][0]["removed"])

    def test_legacy_reuse_is_read_only_even_for_an_older_revision(self):
        snapshot = self.legacy_snapshot("d" * 40)
        with patch.object(store, "_open_https", side_effect=AssertionError("network")):
            row = self.status_row()
            self.assertEqual(row["location"], "hf-cache")
            self.assertFalse(row["removable"])
            self.assertEqual(store.resolve_model(self.model.id), snapshot)
            code, [success] = self.cli("download", self.model.id)
            self.assertEqual(code, 0)
            self.assertEqual(success["path"], str(snapshot))
            code, [error] = self.cli("remove", self.model.id)
            self.assertNotEqual(code, 0)
            self.assertIn("shared Hugging Face cache", error["error"])
        self.assertTrue(snapshot.exists())
        self.assertFalse(self.app.exists())

    def test_removal_never_touches_shared_copy(self):
        self.install()
        snapshot = self.legacy_snapshot()
        self.assertEqual(self.status_row()["location"], "localvoice")
        self.assertTrue(self.cli("remove", self.model.id)[1][0]["removed"])
        self.assertEqual(store.resolve_model(self.model.id), snapshot)

    def test_legacy_rejects_loader_shadowing_corruption_and_external_symlinks(self):
        snapshot = self.legacy_snapshot()
        shadow = snapshot / "weights.safetensors"
        shadow.write_bytes(b"another weight file")
        self.assertEqual(self.status_row()["status"], "not-installed")
        shadow.unlink()
        self.assertEqual(self.status_row()["status"], "installed")
        weights = snapshot / "weights.npz"
        blob = weights.resolve()
        before = blob.stat()
        blob.write_bytes(b"X" * len(self.data[weights.name]))
        os.utime(blob, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.assertEqual(self.status_row()["status"], "not-installed")
        outside = self.root / "valid-but-external"
        outside.write_bytes(self.data[weights.name])
        weights.unlink()
        weights.symlink_to(outside)
        self.assertEqual(self.status_row()["status"], "not-installed")

    def test_download_failures_clean_staging(self):
        data = self.data["weights.npz"]
        failures = [
            (b"short", "Incorrect file size"),
            (data + b"extra", "File exceeds expected size"),
            (b"x" * len(data), "SHA256 mismatch"),
            (IncompleteRead(b"partial"), "IncompleteRead"),
            (TimeoutError("timed out"), "timed out"),
        ]
        for response, message in failures:
            with self.subTest(message=message):
                side_effect = [io.BytesIO(self.data["config.json"]),
                               response if isinstance(response, Exception) else io.BytesIO(response)]
                with patch.object(store, "_open_https", side_effect=side_effect):
                    code, events = self.cli("download", self.model.id)
                self.assertNotEqual(code, 0)
                self.assertEqual(events[-1]["event"], "error")
                self.assertIn(message, events[-1]["error"])
                self.assert_no_staging()
                self.assertFalse((self.app / self.model.id).exists())

    def test_unowned_path_is_neither_replaced_nor_removed(self):
        destination = self.app / self.model.id
        destination.mkdir(parents=True)
        unrelated = destination / "unrelated"
        unrelated.write_text("keep me")
        with patch.object(store, "_open_https", side_effect=AssertionError("network")):
            self.assertNotEqual(self.cli("download", self.model.id)[0], 0)
            self.assertNotEqual(self.cli("remove", self.model.id)[0], 0)
        self.assertEqual(unrelated.read_text(), "keep me")

    def test_remove_preserves_unexpected_files_in_owned_directory(self):
        self.install()
        unrelated = self.app / self.model.id / "notes.txt"
        unrelated.write_text("keep me")
        self.assertFalse(self.status_row()["removable"])
        code, [error] = self.cli("remove", self.model.id)
        self.assertNotEqual(code, 0)
        self.assertIn("unexpected files", error["error"])
        self.assertEqual(unrelated.read_text(), "keep me")

    def test_redirect_must_remain_https(self):
        handler = store._HTTPSRedirects()
        req = Request("https://huggingface.co/path")
        with self.assertRaisesRegex(store.ModelStoreError, "redirected away from HTTPS"):
            handler.redirect_request(req, None, 302, "", {}, "http://example.test/weights")
        redirected = handler.redirect_request(req, None, 302, "", {}, "https://example.test/weights")
        self.assertEqual(redirected.full_url, "https://example.test/weights")

    def test_corrupt_owned_copy_can_be_repaired(self):
        self.install()
        destination = self.app / self.model.id
        (destination / "weights.npz").write_bytes(b"bad")
        self.assertEqual(self.status_row()["status"], "not-installed")
        # Unlike the initial install, repair tolerates an existing (broken) path.
        with patch.object(store, "_open_https", side_effect=[
            io.BytesIO(data) for data in self.data.values()
        ]):
            code, messages = self.cli("download", self.model.id)
        self.assertEqual(code, 0, messages)
        self.assertEqual(store.resolve_model(self.model.id), destination)
        self.assert_no_staging()

    def test_mutating_commands_respect_concurrent_lock(self):
        self.app.mkdir()
        with store._model_lock(self.app, self.model):
            for command in ("download", "remove"):
                code, events = self.cli(command, self.model.id)
                self.assertNotEqual(code, 0)
                self.assertIn("Another operation", events[-1]["error"])

    def test_sigterm_cleans_staging_in_disposable_cli_process(self):
        # Install a transport stub in the child before entering the real CLI.
        stub = """
import runpy
import signal
import sys
import urllib.request
class Opener:
    def open(self, url, timeout):
        print("transport ready", file=sys.stderr, flush=True)
        signal.pause()
urllib.request.build_opener = lambda *args: Opener()
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
"""
        command = [sys.executable, "-c", stub, str(SCRIPT), "download", self.model.id]
        with subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True) as child:
            try:
                ready, _, _ = select.select([child.stderr], [], [], 5)
                self.assertTrue(ready, "child did not enter fake transport")
                self.assertEqual(child.stderr.readline().strip(), "transport ready")
                self.assertTrue(list(self.app.glob(f".{self.model.id}.download-*")))
                child.terminate()
                stdout, _ = child.communicate(timeout=5)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate()
        self.assertEqual(child.returncode, 143)
        self.assertEqual(json.loads(stdout.splitlines()[-1])["error"], "Cancelled")
        self.assert_no_staging()
        self.assertFalse((self.app / self.model.id).exists())

    def test_cache_environment_precedence(self):
        with patch.dict(os.environ, {
            "HOME": str(self.root), "XDG_CACHE_HOME": str(self.root / "xdg"),
            "HF_HOME": str(self.root / "home"), "HUGGINGFACE_HUB_CACHE": "~/old",
            "HF_HUB_CACHE": "~/new",
        }, clear=True):
            self.assertEqual(store._hf_cache_dir(), self.root / "new")
            del os.environ["HF_HUB_CACHE"]
            self.assertEqual(store._hf_cache_dir(), self.root / "old")
            del os.environ["HUGGINGFACE_HUB_CACHE"]
            self.assertEqual(store._hf_cache_dir(), self.root / "home" / "hub")
            del os.environ["HF_HOME"]
            self.assertEqual(store._hf_cache_dir(), self.root / "xdg" / "huggingface" / "hub")


if __name__ == "__main__":
    unittest.main()
