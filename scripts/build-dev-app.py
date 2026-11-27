#!/usr/bin/env python3
"""Build an ad-hoc-signed test app.

By default the runtime remains under build/dev and the app only works on the
machine that built it. With --portable, a pinned standalone CPython is embedded
in the app so the bundle can be zipped and run on another Apple Silicon Mac
(this is what CI publishes as a dev release).

Every build embeds Sparkle.framework (scripts/fetch-sparkle.sh). Only with
--feed-url does the app get an update feed and the key that update archives
must be signed with; without it the updater stays off."""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import tempfile
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_app", ROOT / "scripts/build-app.py")
staging = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(staging)


DEPENDENCIES = [
    *(f"{name}=={version}" for name, version in staging.PINNED_PACKAGES.items()), "sounddevice", "soundfile", "pynput",
    "pyperclip", "rich", "textual", "pyobjc-framework-Cocoa", "pyobjc-framework-Quartz",
    "pyobjc-framework-ApplicationServices", "pyobjc-framework-CoreText",
]
# Relocatable CPython for --portable (astral-sh/python-build-standalone).
STANDALONE_PYTHON = (
    "https://github.com/astral-sh/python-build-standalone/releases/download/20250918/"
    "cpython-3.11.13%2B20250918-aarch64-apple-darwin-install_only.tar.gz"
)
STANDALONE_PYTHON_SHA256 = "dcd46cddff1501b65edbcc6a2b2e11ad5f81cf56d3ce82b50ed9d817f102161d"
# Public half of the EdDSA key that signs update archives and delta patches (see
# docs/setup.md, "In-app updates"). The private half is the SPARKLE_ED_PRIVATE_KEY
# secret of the `release` environment. Changing it strands every installed copy:
# they would refuse all later updates.
SPARKLE_PUBLIC_KEY = "BWe3PVy/ap6CRQquFjr+TiR8+1UXLHb5gxoBpvyPBnM="
# Parts of Sparkle.framework a non-sandboxed app never uses at run time.
SPARKLE_UNUSED = ("XPCServices", "Headers", "PrivateHeaders", "Modules")


def pip_install(python):
    subprocess.run([
        str(python), "-I", "-m", "pip", "--isolated", "--disable-pip-version-check",
        "--no-cache-dir", "install", "--only-binary=:all:", *DEPENDENCIES,
    ], check=True)


def fetch_checked(url, path, digest, limit):
    if path.is_file() and staging.sha256(path) == digest:
        return path
    with urlopen(url, timeout=30) as response:
        data = response.read(limit + 1)
    staging.require(len(data) <= limit and hashlib.sha256(data).hexdigest() == digest,
                    f"Pinned asset verification failed: {path.name}")
    path.write_bytes(data)
    return path


def sparkle_path():
    output = subprocess.check_output([str(ROOT / "scripts/fetch-sparkle.sh")], text=True)
    line = next(line for line in output.splitlines() if line.startswith("Sparkle: "))
    return Path(line[len("Sparkle: "):])


def embed_sparkle(source, frameworks):
    """Copy Sparkle.framework into the bundle without its build-time and sandbox-only parts."""
    frameworks.mkdir(parents=True, exist_ok=True)
    framework = frameworks / "Sparkle.framework"
    # ditto keeps the framework's symlinks (Versions/Current and the links into it).
    subprocess.run(["/usr/bin/ditto", str(source / "Sparkle.framework"), str(framework)], check=True)
    for name in SPARKLE_UNUSED:
        link = framework / name
        if link.is_symlink():
            link.unlink()
        for version in (framework / "Versions").iterdir():
            if not version.is_symlink() and (version / name).exists():
                shutil.rmtree(version / name)
    return framework


def update_keys(feed_url):
    """The Info.plist keys that turn the updater on, or none."""
    if not feed_url:
        return {}
    return {
        "SUFeedURL": feed_url,
        "SUPublicEDKey": SPARKLE_PUBLIC_KEY,
        # Look for an update once a day without asking first (Settings › General ›
        # Updates turns it off), and never send a system profile.
        "SUEnableAutomaticChecks": True,
        "SUEnableSystemProfiling": False,
    }


def worker_path(option):
    if option:
        return option.resolve(strict=True)
    output = subprocess.check_output([str(ROOT / "scripts/build-parakeet.sh")], text=True)
    line = next(line for line in output.splitlines() if line.startswith("Worker: "))
    return Path(line[len("Worker: "):])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", default=shutil.which("python3.11"),
                        help="existing ARM64 Python 3.11 (not installed by this script)")
    parser.add_argument("--worker", type=Path, help="reuse a previously built NVIDIA worker")
    parser.add_argument("--output", default="LocalVoice.app", help="app bundle name inside build/dev")
    parser.add_argument("--bundle-identifier", default="com.localvoice.dev")
    parser.add_argument("--display-name", default="LocalVoice Test")
    parser.add_argument("--portable", action="store_true",
                        help="embed a pinned standalone Python so the app runs on other Macs")
    parser.add_argument("--version", default="1.0", help="CFBundleShortVersionString")
    parser.add_argument("--build-number", default="1", help="CFBundleVersion")
    parser.add_argument("--feed-url", help="Sparkle appcast URL; turns on in-app updates")
    parser.add_argument("--sign", default="-", metavar="IDENTITY",
                        help="codesign identity; '-' signs ad hoc. A stable identity such as "
                             "'Apple Development: …' keeps macOS permissions across rebuilds")
    args = parser.parse_args()
    if os.uname().sysname != "Darwin" or os.uname().machine != "arm64":
        parser.error("Apple Silicon macOS is required.")
    if not args.portable and not args.python:
        parser.error("An existing Python 3.11 is required (or pass --portable).")
    for value in (args.version, args.build_number):
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
            parser.error(f"Expected a dotted numeric version, got {value!r}.")
    if not re.fullmatch(r"(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]+", args.bundle_identifier):
        parser.error("Expected a reverse-DNS bundle identifier.")
    if args.feed_url and not args.feed_url.startswith("https://"):
        parser.error("--feed-url must be an https:// URL.")

    destination = ROOT / "build/dev"
    output = Path(args.output)
    staging.require(output.name == args.output and output.suffix == ".app",
                    "--output must be an .app filename inside build/dev.")
    app = destination / output
    staging.require(destination.resolve() == destination, "Expected a physical build/dev directory.")
    staging.require(not app.exists(), f"App already exists: {app}; move it out of the build directory before rebuilding.")
    destination.mkdir(parents=True, exist_ok=True)
    if args.portable:
        standalone = fetch_checked(
            STANDALONE_PYTHON, destination / "cpython-3.11-standalone.tar.gz",
            STANDALONE_PYTHON_SHA256, 64 * 1024 * 1024,
        )
    else:
        runtime = destination / "venv"
        python = runtime / "bin/python3.11"
        if not python.is_file():
            subprocess.run([args.python, "-I", "-m", "venv", str(runtime)], check=True)
        print("Installing binary dependencies into build/dev/venv (no system packages changed)…", flush=True)
        pip_install(python)
    archive = fetch_checked(
        "https://codeload.github.com/patelnav/ctrlspeak/tar.gz/refs/tags/v1.8.0",
        destination / "ctrlspeak-1.8.0.tar.gz", staging.UPSTREAM_SHA256, 10 * 1024 * 1024,
    )
    vad = fetch_checked(
        "https://raw.githubusercontent.com/snakers4/silero-vad/v6.2.1/src/silero_vad/data/silero_vad.jit",
        destination / "silero_vad.jit", staging.VAD_SHA256, 2_272_526,
    )
    worker = worker_path(args.worker)
    staging.require(os.access(worker, os.X_OK), "Core ML worker is missing or not executable.")
    sparkle = sparkle_path()

    with tempfile.TemporaryDirectory(prefix=".staging-", dir=destination) as temporary:
        scratch = Path(temporary)
        bundle = scratch / "LocalVoice.app"
        resources = bundle / "Contents/Resources"
        helpers = bundle / "Contents/Helpers"
        macos = bundle / "Contents/MacOS"
        for folder in (resources / "Legal", helpers, macos):
            folder.mkdir(parents=True)
        # This is not a distribution: upstream v1.8.0 references MIT in its
        # README but omits the linked license file from the tagged archive.
        staging.copy_source(archive, scratch, resources / "ctrlspeak", resources / "Legal",
                            require_license=False)
        shutil.copy2(vad, resources / "silero_vad.jit")
        shutil.copy2(worker, helpers / "localvoice-parakeet")
        if args.portable:
            embedded = resources / "runtime"
            embedded.mkdir()
            subprocess.run(["/usr/bin/tar", "-xzf", str(standalone), "--strip-components", "1",
                            "-C", str(embedded)], check=True)
            print("Installing binary dependencies into the embedded runtime…", flush=True)
            pip_install(embedded / "bin/python3.11")

        swift = ["xcrun", "swiftc", "-target", "arm64-apple-macosx15.0",
                 "-module-cache-path", str(scratch / "module-cache")]
        embed_sparkle(sparkle, bundle / "Contents/Frameworks")
        subprocess.run([*swift, "-parse-as-library", "-F", str(sparkle), "-framework", "Sparkle",
                        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                        str(ROOT / "src/ctrlspeak-launcher.swift"), str(ROOT / "src/localvoice-model-library.swift"),
                        str(ROOT / "src/localvoice-updater.swift"), "-o", str(macos / "LocalVoice")], check=True)
        # The updater code compiles to a stub when Sparkle cannot be imported; refuse that build.
        links = subprocess.check_output(["/usr/bin/otool", "-L", str(macos / "LocalVoice")], text=True)
        staging.require("@rpath/Sparkle.framework/" in links, "The launcher does not link Sparkle.")
        subprocess.run([*swift, str(ROOT / "src/ctrlspeak-overlay.swift"),
                         "-o", str(helpers / "ctrlspeak-overlay")], check=True)
        icon_generator = scratch / "ctrlspeak-icon"
        subprocess.run([*swift, str(ROOT / "src/ctrlspeak-icon.swift"),
                        "-o", str(icon_generator)], check=True)
        staging.install_app_icon(icon_generator, scratch, resources)
        wrapper = resources / "run-ctrlspeak"
        runtime_prefix = 'RUNTIME="$RESOURCES/runtime"'
        original = (ROOT / "scripts/run-bundled-ctrlspeak.sh").read_text()
        staging.require(runtime_prefix in original, "Unexpected bundled runner layout.")
        if args.portable:
            # The embedded runtime sits where the release layout expects it.
            wrapper.write_text(original)
            launch_config = staging.LAUNCH_CONFIG
        else:
            wrapper.write_text(original.replace(runtime_prefix, f"RUNTIME={shlex.quote(str(runtime))}", 1))
            launch_config = staging.LAUNCH_CONFIG.replace(
                "model_python=runtime/bin/python3.11", f"model_python={python}")
        wrapper.chmod(0o755)
        (resources / "launch.conf").write_text(launch_config + staging.VAD_CONFIG + staging.PARAKEET_CONFIG)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": args.bundle_identifier,
            "CFBundleExecutable": "LocalVoice",
            "CFBundleIconFile": "LocalVoice",
            "CFBundleName": args.display_name,
            "CFBundleDisplayName": args.display_name,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": args.build_number,
            "CFBundleShortVersionString": args.version,
            "LSMinimumSystemVersion": "15.0",
            "LSUIElement": True,
            "NSMicrophoneUsageDescription": "LocalVoice records audio for on-device dictation.",
            "NSAppleEventsUsageDescription": "LocalVoice can pause media when dictation starts.",
            **update_keys(args.feed_url),
        }))
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", args.sign, str(bundle)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
        bundle.rename(app)

    print(f"Test app: {app}")
    print(f"Open with: open {shlex.quote(str(app))}")


if __name__ == "__main__":
    main()
