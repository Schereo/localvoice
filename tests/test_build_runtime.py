"""Synthetic, offline tests for the runtime input contract and archive producer."""

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "build_runtime", Path(__file__).resolve().parents[1] / "scripts/build-runtime.py"
)
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


def wheel(directory, name="fixture", version="1.0", extra=None, dependency=None):
    base = f"{name.replace('-', '_')}-{version}"
    path = directory / f"{base}-py3-none-any.whl"
    info = f"{base}.dist-info"
    files = {
        f"{name.replace('-', '_')}.py": "payload = 1\n",
        f"{info}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n",
        f"{info}/WHEEL": "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        f"{info}/LICENSE": "Synthetic test fixture\n",
    }
    if extra:
        files[extra] = "raise RuntimeError('never run this startup hook')"
    if dependency:
        files[f"{info}/METADATA"] += f"Requires-Dist: {dependency}\n"
    files[f"{info}/RECORD"] = "".join(f"{entry},,\n" for entry in files) + f"{info}/RECORD,,\n"
    with zipfile.ZipFile(path, "w") as out:
        for name, contents in files.items():
            out.writestr(name, contents)
    return path


class Inputs(unittest.TestCase):
    def test_lock_rejects_pip_options_urls_duplicates_and_unhashed_entries(self):
        valid = f"Fixture==1.0 --hash=sha256:{'a' * 64}"
        self.assertEqual({"fixture": ("1.0", "a" * 64)}, runtime.parse_lock(valid))
        for bad in ("--extra-index-url https://example.com", "-r nested.txt",
                    "fixture @ https://example.com/fixture.whl", "fixture==1.0",
                    valid + "\n" + valid, valid + " --hash=sha256:" + "b" * 64):
            with self.subTest(line=bad), self.assertRaises(ValueError):
                runtime.parse_lock(bad)

    def test_wheel_hash_metadata_and_path_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            source = path / "wheelhouse"
            source.mkdir()
            good = wheel(source)
            chosen = runtime.prepare_wheels(source, {"fixture": ("1.0", runtime.app.sha256(good))},
                                            path / "ok")
            self.assertEqual(good.name, chosen["fixture"]["wheel"])
            with self.assertRaisesRegex(ValueError, "No wheel"):
                runtime.prepare_wheels(source, {"fixture": ("1.0", "0" * 64)}, path / "bad")
            with self.assertRaisesRegex(ValueError, "metadata"):
                runtime.prepare_wheels(source, {"wrong": ("1.0", runtime.app.sha256(good))},
                                       path / "bad-name")
            for bad in ("//path.py", "../path.py", "fake.pth", "sitecustomize.py"):
                with self.subTest(member=bad), self.assertRaises(ValueError):
                    runtime.read_wheel(wheel(source, extra=bad))
            setuptools = wheel(source, "setuptools", extra="distutils-precedence.pth")
            self.assertEqual(("setuptools", "1.0"), runtime.read_wheel(setuptools))

    def test_real_pip_uses_local_hashed_wheels_and_checks_dependencies(self):
        spec = importlib.util.find_spec("pip")
        if not spec:
            self.skipTest("local Python has no pip bootstrap")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            wheels = path / "wheelhouse"
            wheels.mkdir()
            bootstrap = path / "bootstrap"
            shutil.copytree(Path(spec.origin).parent, bootstrap / "pip")
            lock = path / "requirements.lock"
            site = path / "site"
            site.mkdir()
            env = runtime.pip_environment(path)
            fixture = wheel(wheels)
            lock.write_text(f"fixture==1.0 --hash=sha256:{runtime.app.sha256(fixture)}\n")
            runtime.pip_install(Path(sys.executable), bootstrap, site, wheels, lock, env)
            self.assertTrue((site / "fixture.py").is_file())

            # The lock has the correct hash, but pip check must fail without the
            # transitive requirement. A deliberately invalid index must not be consulted.
            fixture = wheel(wheels, "missing-dep", dependency="unpinned-fixture")
            lock.write_text(f"missing-dep==1.0 --hash=sha256:{runtime.app.sha256(fixture)}\n")
            with patch.dict(os.environ, {"PIP_INDEX_URL": "https://example.invalid"}):
                with self.assertRaises(subprocess.CalledProcessError) as error:
                    runtime.pip_install(Path(sys.executable), bootstrap, site, wheels, lock, env)
            self.assertIn("check", error.exception.cmd)


@unittest.skipUnless(sys.platform == "darwin" and os.uname().machine == "arm64",
                     "requires Apple Silicon and Xcode CLT")
class Producer(unittest.TestCase):
    def test_preflight_and_reproducible_archive_readable_by_build_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            python = root / "python"
            stdlib = python / "lib/python3.11"
            (python / "bin").mkdir(parents=True)
            (stdlib / "site-packages/pip").mkdir(parents=True)
            (stdlib / "encodings").mkdir()
            for name in ("os.py", "site-packages/pip/__init__.py", "encodings/__init__.py"):
                (stdlib / name).write_text("# Synthetic\n")
            source = root / "fixture.c"
            source.write_text("int main(void) { return 0; }\n")
            runtime.app.run("xcrun", "clang", "-target", "arm64-apple-macosx15.0",
                            str(source), "-o", str(python / "bin/python3.11"))

            python_tar = root / "python.tar"
            ffmpeg_tar = root / "ffmpeg.tar"
            with tarfile.open(python_tar, "w") as tar:
                tar.add(python, arcname="python")
            with tarfile.open(ffmpeg_tar, "w") as tar:
                tar.add(python / "bin/python3.11", arcname="bin/ffmpeg")

            licenses = root / "licenses"
            for name in ("CPython", "FFmpeg"):
                (licenses / name).mkdir(parents=True)
                (licenses / name / "LICENSE").write_text("Synthetic license.\n")
            wheelhouse = root / "wheelhouse"
            wheelhouse.mkdir()
            lock = root / "requirements.lock"
            versions = {name: runtime.app.PINNED_PACKAGES.get(name, "1.0")
                        for name in runtime.app.REQUIRED_PACKAGES}
            lock.write_text("".join(
                f"{name}=={version} --hash=sha256:{runtime.app.sha256(wheel(wheelhouse, name, version))}\n"
                for name, version in sorted(versions.items())
            ))

            args = argparse.Namespace(
                python=python_tar, python_sha256=runtime.app.sha256(python_tar),
                ffmpeg=ffmpeg_tar, ffmpeg_sha256=runtime.app.sha256(ffmpeg_tar),
                wheelhouse=wheelhouse, requirements=lock, licenses=licenses, min_macos="15.0",
                check_inputs=True, output=root / "runtime.tar.gz",
            )
            with tempfile.TemporaryDirectory(dir=root) as work:
                with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                    runtime.extract_pinned(python_tar, "0" * 64, Path(work) / "input")
                self.assertFalse((Path(work) / "input").exists())
            with tempfile.TemporaryDirectory(dir=root) as work, patch.object(runtime, "install_wheels") as pip:
                runtime.produce(args, Path(work))
                pip.assert_not_called()
                self.assertFalse(args.output.exists())

            def fixture_install(_python, _bootstrap, site, _wheels, _lock, _work):
                # Model pip's installed layout without executing the native stubs.
                for name, version in versions.items():
                    info = site / f"{name}-{version}.dist-info"
                    info.mkdir()
                    (info / "METADATA").write_text(f"Name: {name}\nVersion: {version}\n")
                    (info / "LICENSE").write_text("Synthetic license.\n")
                return "3.11.0"

            args.check_inputs = False
            hashes = []
            for n in (1, 2):
                args.output = root / f"runtime-{n}.tar.gz"
                with tempfile.TemporaryDirectory(dir=root) as work, \
                        patch.object(runtime, "install_wheels", side_effect=fixture_install):
                    runtime.produce(args, Path(work))
                hashes.append(runtime.app.sha256(args.output))
            self.assertEqual(hashes[0], hashes[1])
            extracted = root / "unpacked"
            runtime.app.extract(args.output, extracted, allow_links=True)
            self.assertEqual(versions, runtime.app.runtime_packages(extracted))
            self.assertEqual("15.0", runtime.native_targets(extracted, "15.0")["bin/ffmpeg"]["min_macos"])
            with self.assertRaisesRegex(ValueError, "above declared macOS"):
                runtime.native_targets(extracted, "14.0")


if __name__ == "__main__":
    unittest.main()
