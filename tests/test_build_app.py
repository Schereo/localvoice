"""Offline tests for the LocalVoice app verifier; no app or runtime is launched."""

import importlib.util
import io
import json
import os
import plistlib
import shutil
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "build_app", Path(__file__).resolve().parents[1] / "scripts/build-app.py"
)
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


def write(path, value="synthetic fixture"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value)


class ArchiveTests(unittest.TestCase):
    def test_reject_absolute_traversal_and_link_ancestors(self):
        entries = {
            "//outside": [("//outside", None)],
            "../outside": [("../outside", None)],
            "symlink chain": [("one", "../outside"), ("one/new", "../target")],
            "broken symlink": [("link", "not-in-archive")],
        }
        for label, items in entries.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                path = Path(directory).resolve()
                (path / "outside").mkdir()
                archive = path / "test.tar"
                with tarfile.open(archive, "w") as tar:
                    for name, link in items:
                        item = tarfile.TarInfo(name)
                        if link:
                            item.type = tarfile.SYMTYPE
                            item.linkname = link
                            tar.addfile(item)
                        else:
                            item.size = 1
                            tar.addfile(item, io.BytesIO(b"x"))
                with self.assertRaises((ValueError, OSError)):
                    build.extract(archive, path / "payload", allow_links=True)
                self.assertEqual([], list((path / "outside").iterdir()))

    def test_accept_relative_symlink_within_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            archive = path / "test.tar"
            with tarfile.open(archive, "w") as tar:
                item = tarfile.TarInfo("bin/file")
                item.size = 1
                tar.addfile(item, io.BytesIO(b"x"))
                item = tarfile.TarInfo("link")
                item.type = tarfile.SYMTYPE
                item.linkname = "bin/file"
                tar.addfile(item)
            build.extract(archive, path / "payload", allow_links=True)
            self.assertEqual("x", (path / "payload/link").read_text())


@unittest.skipUnless(sys.platform == "darwin" and os.uname().machine == "arm64",
                     "requires Apple Silicon and Xcode CLT")
class NativeTests(unittest.TestCase):
    def test_dyld_paths_must_resolve_inside_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            app = path / "Fixture.app"
            source = path / "fixture.c"
            library = path / "library.c"
            write(source, "int fixture(void);\nint main(void) { return fixture(); }\n")
            write(library, "int fixture(void) { return 0; }\n")
            dylib = app / build.RUNTIME / "lib/libfixture.dylib"
            dylib.parent.mkdir(parents=True)
            flags = ("-target", "arm64-apple-macosx15.0")
            build.run("xcrun", "clang", *flags, "-dynamiclib", str(library),
                      "-install_name", "@rpath/libfixture.dylib", "-o", str(dylib))
            plain = path / "plain.c"
            write(plain, "int main(void) { return 0; }\n")
            for entry in build.ENTRYPOINTS[:-1]:
                (app / entry).parent.mkdir(parents=True, exist_ok=True)
                build.run("xcrun", "clang", *flags, str(plain), "-o", str(app / entry))
            ffmpeg = app / build.ENTRYPOINTS[-1]
            build.run("xcrun", "clang", *flags, str(source), str(dylib),
                      "-Wl,-rpath,@loader_path/../lib", "-o", str(ffmpeg))
            build.verify_native(app, build.inventory(app), "15.0")
            dylib.unlink()
            with self.assertRaisesRegex(ValueError, "Unresolved dyld dependency"):
                build.verify_native(app, build.inventory(app), "15.0")

    def test_relocated_app_and_real_deployment_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            app = path / "Fixture.app"
            runtime = app / build.RUNTIME
            resources = app / build.RESOURCES
            minimum = "15.0"
            source = path / "fixture.c"
            write(source, "int main(void) { return 0; }\n")
            executable = path / "fixture"
            build.run("xcrun", "clang", "-target", "arm64-apple-macosx15.0",
                      str(source), "-o", str(executable))
            for entry in build.ENTRYPOINTS:
                (app / entry).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(executable, app / entry)
            write(runtime / "lib/python3.11/encodings/__init__.py")
            write(runtime / "lib/python3.11/os.py")
            for name in ("CPython", "FFmpeg"):
                write(runtime / "licenses" / name / "LICENSE")
            for package in build.REQUIRED_PACKAGES:
                version = "0.4.3" if package == "mlx-whisper" else "1.0"
                info = runtime / "lib/python3.11/site-packages" / f"{package}-{version}.dist-info"
                write(info / "METADATA", f"Name: {package}\nVersion: {version}\n")
                write(info / "LICENSE")
            for name in ("ctrlspeak/ctrlspeak.py", "ctrlspeak/localvoice_models.py",
                         "ctrlspeak/on.wav", "ctrlspeak/off.wav", "LocalVoice.icns",
                         "Legal/LocalVoice-LICENSE", "Legal/LocalVoice-NOTICE.md",
                         "Legal/ctrlSPEAK-LICENSE"):
                write(resources / name)
            write(resources / "run-ctrlspeak")
            (resources / "run-ctrlspeak").chmod(0o755)
            write(resources / "launch.conf", build.LAUNCH_CONFIG)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "LSMinimumSystemVersion": minimum,
                "CFBundleIdentifier": build.SERVICE_ID,
                "CFBundleExecutable": "LocalVoice",
                "CFBundleVersion": "1.0.0",
                "CFBundleShortVersionString": "1.0.0",
            }))
            records = build.inventory(app)
            manifest = {
                "schema": 1, "architecture": "arm64",
                "status": "staged-unverified-for-distribution", "min_macos": minimum,
                "localvoice_version": "1.0.0", "silero_vad": None,
                "upstream": {"version": build.UPSTREAM_VERSION, "sha256": build.UPSTREAM_SHA256},
                "python_distributions": build.runtime_packages(runtime),
                "native_arm64_min_macos": build.verify_native(app, records, minimum),
                "files": records,
            }
            write(app / build.MANIFEST, json.dumps(manifest))
            target = path / "With spaces" / "Moved.app"
            target.parent.mkdir()
            app.rename(target)
            self.assertEqual(manifest, build.verify(target))

            helper = target / build.PARAKEET_HELPER
            shutil.copy2(executable, helper)
            relocated_resources = target / build.RESOURCES
            write(relocated_resources / "launch.conf", build.LAUNCH_CONFIG + build.PARAKEET_CONFIG)
            write(relocated_resources / "Legal/FluidAudio-LICENSE")
            provider_records = build.inventory(target)
            provider_manifest = dict(
                manifest, parakeet_coreml=True, files=provider_records,
                native_arm64_min_macos=build.verify_native(target, provider_records, minimum),
            )
            write(target / build.MANIFEST, json.dumps(provider_manifest))
            self.assertEqual(provider_manifest, build.verify(target))
            self.assertEqual(provider_manifest["native_arm64_min_macos"][build.PARAKEET_HELPER], minimum)

            build.run("xcrun", "clang", "-target", "arm64-apple-macosx15.1",
                      str(source), "-o", str(target / build.ENTRYPOINTS[-1]))
            with self.assertRaisesRegex(ValueError, "files, modes or hashes"):
                build.verify(target)
            with self.assertRaisesRegex(ValueError, "above declared macOS 15.0"):
                build.verify_native(target, build.inventory(target), minimum)


if __name__ == "__main__":
    unittest.main()
