"""Offline LocalVoice staging and pre-signing verification (see build-app.sh --help)."""

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from email.parser import BytesParser
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parent.parent
UPSTREAM_VERSION = "1.8.0"
UPSTREAM_URL = "https://github.com/patelnav/ctrlspeak/archive/refs/tags/v1.8.0.tar.gz"
# From the upstream Homebrew formula, not from the mutable installed libexec.
UPSTREAM_SHA256 = "ca8aa0a33eba212fc1f9ab65fa77d121f8001d110854f984f6151edf059cd884"
SOURCE_ROOT = f"ctrlspeak-{UPSTREAM_VERSION}"
SERVICE_ID = "com.localvoice.app"
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
LAUNCH_CONFIG = (
    "command=run-ctrlspeak\n"
    "overlay=../Helpers/ctrlspeak-overlay\n"
    "model_python=runtime/bin/python3.11\n"
    "model_store=ctrlspeak/localvoice_models.py\n"
    "managed_models=1\n"
    f"path={SYSTEM_PATH}\n"
)
VAD_SHA256 = "e1122837f4154c511485fe0b9c64455f7b929c96fbb8d79fbdb336383ebd3720"
VAD_CONFIG = "vad=silero_vad.jit\n"
PARAKEET_CONFIG = "parakeet_worker=../Helpers/localvoice-parakeet\n"
PARAKEET_HELPER = "Contents/Helpers/localvoice-parakeet"
MANIFEST = "Contents/Resources/build-manifest.json"
RESOURCES = "Contents/Resources"
RUNTIME = f"{RESOURCES}/runtime"
ENTRYPOINTS = (
    "Contents/MacOS/LocalVoice",
    "Contents/Helpers/ctrlspeak-overlay",
    f"{RUNTIME}/bin/python3.11",
    f"{RUNTIME}/bin/ffmpeg",
)
REQUIRED_PACKAGES = {
    "certifi", "huggingface-hub", "mlx", "mlx-qwen3-asr", "mlx-whisper", "numpy", "pynput",
    "pyobjc-core", "pyobjc-framework-applicationservices", "pyobjc-framework-cocoa",
    "pyobjc-framework-coretext", "pyobjc-framework-quartz", "pyperclip", "rich",
    "sounddevice", "soundfile", "textual", "torch", "tqdm",
}
# The backends rely on these exact releases' loading and decoding behavior.
PINNED_PACKAGES = {"mlx-whisper": "0.4.3", "mlx-qwen3-asr": "0.4.4"}
MACH_MAGICS = set(bytes.fromhex(x) for x in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca",
    "cafebabf", "bfbafeca",
))
DYLIB_LOADS = {
    "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
    "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, capture=True, env=None):
    if args[0] == "xcrun":
        args = ("xcrun", "--no-cache", *args[1:])
    return subprocess.run(
        args, check=True, text=True,
        stdout=subprocess.PIPE if capture else None, env=env,
    ).stdout


def install_app_icon(generator, work, resources):
    iconset = work / "LocalVoice.iconset"
    iconset.mkdir()
    run(str(generator), str(iconset), capture=False)
    run("iconutil", "-c", "icns", str(iconset), "-o", str(resources / "LocalVoice.icns"))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def macos_version(value):
    require(re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", value),
            f"Invalid macOS version: {value}")
    return tuple(int(n) for n in (value + ".0").split(".")[:3])


def extract(archive, destination, allow_links=False):
    """Never extract special files, absolute paths, or files through links."""
    destination.mkdir()
    links = []
    seen = set()
    with tarfile.open(archive, "r:*") as tar:
        for member in tar:
            archive_path = PurePosixPath(member.name)
            parts = archive_path.parts
            if not parts and member.isdir():
                continue  # `tar -C DIR -cf FILE .`
            require(parts and not archive_path.is_absolute() and ".." not in parts,
                    f"Unsafe archive path: {member.name}")
            relative = Path(*parts)
            key = str(relative).casefold()
            require(key not in seen, f"Duplicate archive path: {member.name}")
            seen.add(key)
            target = destination / relative
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, target.open("xb") as out:
                    shutil.copyfileobj(source, out)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
            elif allow_links and member.issym():
                require(member.linkname and not PurePosixPath(member.linkname).is_absolute(),
                        f"Non-relative link: {member.name}")
                links.append((target, member.linkname))
            else:
                raise ValueError(f"Unsupported archive entry: {member.name}")
    # No directory is created through a link: prepare all link parents before
    # creating any link. A link occupying another entry's parent then fails.
    for target, _ in links:
        target.parent.mkdir(parents=True, exist_ok=True)
    for target, link in links:
        target.symlink_to(link)
    for target, _ in links:
        check_link(destination, target)


def check_link(root, path):
    require(not Path(os.readlink(path)).is_absolute(), f"Absolute link: {path}")
    resolved = path.resolve(strict=True)
    require(resolved.is_relative_to(root) and not path.parent.is_relative_to(resolved),
            f"Escaping or recursive link: {path}")


def copy_source(archive, workspace, target, notices, *, require_license=True):
    destination = workspace / "source"
    extract(archive, destination)
    source = destination / SOURCE_ROOT
    require(source.is_dir() and list(destination.iterdir()) == [source],
            f"Expected one archive root: {SOURCE_ROOT}")
    target.mkdir()
    for item in sorted(source.iterdir()):
        if item.suffix == ".py" and not item.name.startswith("test_"):
            shutil.copy2(item, target / item.name)
    for name in ("models", "ui", "utils"):
        shutil.copytree(source / name, target / name, ignore=shutil.ignore_patterns(
            "__pycache__", "*.pyc", ".DS_Store",
        ))
    for name in ("on.wav", "off.wav"):
        shutil.copy2(source / name, target / name)
    license_files = [p for p in source.iterdir()
                     if p.is_file() and re.fullmatch(r"LICEN[CS]E(?:\..*)?", p.name, re.I)]
    if require_license:
        require(license_files, "Upstream license not found in the pinned source archive.")
    for item in sorted(license_files):
        shutil.copy2(item, notices / f"ctrlSPEAK-{item.name}")
    patches = ROOT / "patches" / SOURCE_ROOT
    for item in sorted(patches.rglob("*.py")):
        relative = item.relative_to(patches)
        require(relative.parent == Path(".") or (target / relative.parent).is_dir(),
                f"Patch has no corresponding upstream directory: {relative}")
        shutil.copy2(item, target / relative)


def runtime_packages(runtime):
    site = runtime / "lib/python3.11/site-packages"
    for name in ("bin", "lib", "lib/python3.11", "lib/python3.11/site-packages", "licenses"):
        path = runtime / name
        require(path.is_dir() and not path.is_symlink(), f"Missing runtime directory: {name}")
    for name in ("encodings/__init__.py", "os.py"):
        require((site.parent / name).is_file(), f"Missing Python standard library file: {name}")
    require(not any(runtime.rglob("pyvenv.cfg")), "Supply a private Python distribution, not a venv.")
    require(not list(site.glob("*.egg-link")), "Editable Python package links are not portable.")
    require(not list(site.glob("*.pth")), "Supply a flat site-packages without .pth startup hooks.")
    for name in ("CPython", "FFmpeg"):
        directory = runtime / "licenses" / name
        require(directory.is_dir() and any(p.is_file() and p.stat().st_size
                                           for p in directory.rglob("*")),
                f"Provide legal material in runtime/licenses/{name}/.")
    packages = {}
    for metadata in sorted(site.glob("*.dist-info/METADATA")):
        with metadata.open("rb") as source:
            record = BytesParser().parse(source, headersonly=True)
        name = re.sub(r"[-_.]+", "-", (record["Name"] or "").lower())
        version = record["Version"]
        require(re.fullmatch(r"[a-z0-9-]+", name) and version and name not in packages,
                f"Invalid or duplicate distribution: {metadata.parent.name}")
        candidates = list(metadata.parent.glob("[Ll][Ii][Cc][Ee][Nn][Ss]*"))
        candidates += list(metadata.parent.glob("[Cc][Oo][Pp][Yy][Ii][Nn][Gg]*"))
        candidates += list((metadata.parent / "licenses").rglob("*"))
        candidates += list((runtime / "licenses" / name).rglob("*"))
        require(any(p.is_file() and p.stat().st_size for p in candidates),
                f"Missing license text for {name} (add it under runtime/licenses/{name}/).")
        packages[name] = version
    missing = REQUIRED_PACKAGES - packages.keys()
    require(not missing, f"Missing runtime distributions: {', '.join(sorted(missing))}")
    for name, version in PINNED_PACKAGES.items():
        require(packages[name] == version, f"LocalVoice requires {name}=={version}.")
    return packages


def inventory(app):
    records = {}
    for directory, dirs, files in os.walk(app, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(directory) / name
            relative = path.relative_to(app).as_posix()
            if relative == MANIFEST:
                continue
            if path.is_symlink():
                check_link(app, path)
                records[relative] = {"link": os.readlink(path)}
            elif path.is_file():
                records[relative] = {
                    "sha256": sha256(path),
                    "executable": bool(path.stat().st_mode & 0o111),
                }
            else:
                require(path.is_dir(), f"Unexpected file type: {path}")
    return records


def native_info(path):
    commands = run("xcrun", "otool", "-arch", "arm64", "-hv", "-l", str(path))
    header = re.search(r"^\s*MH_MAGIC_64\s+ARM64\s+\S+\s+\S+\s+(\S+)", commands, re.MULTILINE)
    require(header, f"Not an ARM64 Mach-O image: {path}")
    filetype = header[1]
    require(filetype in {"EXECUTE", "DYLIB", "BUNDLE"}, f"Unexpected Mach-O type {filetype}: {path}")
    loads, rpaths, versions = [], [], []
    for block in re.split(r"^Load command \d+\s*$", commands, flags=re.MULTILINE)[1:]:
        values = {}
        for line in block.splitlines():
            pair = line.strip().split(maxsplit=1)
            if len(pair) == 2:
                values[pair[0]] = pair[1]
        command = values.get("cmd")
        if command == "LC_BUILD_VERSION":
            require(values.get("platform", "").lower() in {"1", "macos"},
                    f"Not a macOS Mach-O image: {path}")
            versions.append(values["minos"])
        elif command == "LC_VERSION_MIN_MACOSX":
            versions.append(values["version"])
        elif command in DYLIB_LOADS or command == "LC_RPATH":
            value = values["path" if command == "LC_RPATH" else "name"]
            value = re.sub(r" \(offset \d+\)$", "", value)
            (rpaths if command == "LC_RPATH" else loads).append(value)
        elif command == "LC_DYLD_ENVIRONMENT":
            raise ValueError(f"Unsupported embedded dyld environment: {path}")
    require(len(versions) == 1, f"No unambiguous ARM64 macOS deployment target: {path}")
    return versions[0], loads, rpaths, filetype


def system_location(path):
    return path.startswith(("/usr/lib/", "/System/Library/")) and ".." not in PurePosixPath(path).parts


def verify_native(app, records, minimum):
    images = {}
    arm64 = {}
    for name, record in records.items():
        if "sha256" not in record:
            continue
        path = app / name
        with path.open("rb") as stream:
            if stream.read(4) not in MACH_MAGICS:
                continue
        versions = run("xcrun", "lipo", "-archs", str(path)).split()
        require("arm64" in versions, f"Missing ARM64 slice: {name} ({' '.join(versions)})")
        target, loads, rpaths, filetype = native_info(path)
        require(macos_version(target) <= macos_version(minimum),
                f"{name} needs macOS {target}, above declared macOS {minimum}.")
        images[path] = (loads, rpaths, filetype)
        arm64[name] = target
        if name in ENTRYPOINTS[:2]:
            require(versions == ["arm64"] and macos_version(target) == macos_version(minimum),
                    f"{name} must target exactly arm64-apple-macosx{minimum}.")

    entrypoints = ENTRYPOINTS + ((PARAKEET_HELPER,) if PARAKEET_HELPER in records else ())
    resolved_entries = [(app / name).resolve() for name in entrypoints]
    for name, path in zip(entrypoints, resolved_entries):
        require(path in images and images[path][2] == "EXECUTE" and os.access(path, os.X_OK),
                f"Missing native executable: {name}")

    def expand(value, loader, executable):
        if value.startswith("@loader_path/"):
            path = loader.parent / value[len("@loader_path/"):]
        elif value.startswith("@executable_path/"):
            path = executable.parent / value[len("@executable_path/"):]
        else:
            require(system_location(value), f"Non-portable dyld path in {loader.name}: {value}")
            return value
        path = path.resolve()
        require(path.is_relative_to(app), f"Dyld path escapes app in {loader.name}: {value}")
        return str(path)

    visited = set()
    seen_images = set()

    def resolve_image(loader, executable, inherited, stack=()):
        if loader in stack:  # cycles in dylib graphs are valid
            return
        loads, rpaths, _ = images[loader]
        search = tuple(dict.fromkeys([*(expand(p, loader, executable) for p in rpaths),
                                      *inherited]))
        key = (loader, executable, search)
        if key in visited:
            return
        visited.add(key)
        seen_images.add(loader)
        for load in loads:
            if load.startswith("@rpath/"):
                suffix = load[len("@rpath/"):]
                require(suffix and not Path(suffix).is_absolute() and ".." not in Path(suffix).parts,
                        f"Unsafe dyld dependency in {loader.name}: {load}")
                candidates = [f"{base}/{suffix}" for base in search]
            else:
                candidates = [expand(load, loader, executable)]
            for candidate in candidates:
                if system_location(candidate):
                    break  # macOS system libraries may be in the dyld shared cache
                dependency = Path(candidate).resolve()
                if dependency in images and images[dependency][2] == "DYLIB":
                    resolve_image(dependency, executable, search, stack + (loader,))
                    break
            else:
                raise ValueError(f"Unresolved dyld dependency in {loader.relative_to(app)}: {load}")

    for executable in resolved_entries:
        resolve_image(executable, executable, ())
    # Native extensions loaded through Python are not in its initial Mach-O graph.
    python = resolved_entries[2]
    python_rpaths = tuple(expand(p, python, python) for p in images[python][1])
    for loader in images:
        if loader not in seen_images:
            if images[loader][2] == "EXECUTE":
                resolve_image(loader, loader, ())
            else:
                resolve_image(loader, python, python_rpaths)
    return arm64


def verify(app):
    app = app.resolve(strict=True)
    require(app.is_dir() and app.suffix == ".app", f"Expected an app bundle: {app}")
    manifest_path = app / MANIFEST
    require(manifest_path.is_file() and not manifest_path.is_symlink()
            and manifest_path.resolve() == manifest_path, "Missing or linked build manifest.")
    manifest = json.loads(manifest_path.read_text())
    require(manifest["schema"] == 1 and manifest["architecture"] == "arm64"
            and manifest["upstream"]["sha256"] == UPSTREAM_SHA256
            and manifest["upstream"]["version"] == UPSTREAM_VERSION
            and manifest["status"] == "staged-unverified-for-distribution",
            "Unexpected build manifest schema, status, or upstream.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    minimum = manifest["min_macos"]
    require(macos_version(minimum) >= (13, 0, 0), "Invalid minimum version in the build manifest.")
    require(info["LSMinimumSystemVersion"] == minimum
            and info["CFBundleIdentifier"] == SERVICE_ID
            and info["CFBundleExecutable"] == "LocalVoice"
            and info["CFBundleShortVersionString"] == manifest["localvoice_version"]
            and info["CFBundleVersion"] == manifest["localvoice_version"],
            "Bundle identity, version, or minimum macOS does not match the manifest.")
    vad = manifest["silero_vad"]
    parakeet = manifest.get("parakeet_coreml", False)
    require(isinstance(parakeet, bool), "Invalid Parakeet manifest field.")
    expected_config = LAUNCH_CONFIG + (VAD_CONFIG if vad else "") + (PARAKEET_CONFIG if parakeet else "")
    require((app / RESOURCES / "launch.conf").read_text() == expected_config,
            "Expected the bundle-relative launcher configuration.")
    records = inventory(app)
    require(records == manifest["files"], "Bundle files, modes or hashes differ from the manifest.")
    for name in ("ctrlspeak/ctrlspeak.py", "ctrlspeak/localvoice_models.py", "ctrlspeak/on.wav", "ctrlspeak/off.wav",
                 "Legal/LocalVoice-LICENSE", "Legal/LocalVoice-NOTICE.md", "LocalVoice.icns",
                 "run-ctrlspeak"):
        require(f"{RESOURCES}/{name}" in records, f"Missing staged asset: {name}")
    require(any(p.startswith(f"{RESOURCES}/Legal/ctrlSPEAK-") for p in records),
            "Missing upstream legal material.")
    vad_record = records.get(f"{RESOURCES}/silero_vad.jit")
    if vad:
        require(vad == VAD_SHA256 and vad_record and vad_record.get("sha256") == VAD_SHA256
                and f"{RESOURCES}/Legal/Silero-VAD-LICENSE" in records,
                "The optional Silero artifact or its legal material is invalid.")
    else:
        require(vad is None and vad_record is None, "Unexpected Silero artifact.")
    if parakeet:
        require(macos_version(minimum) >= (14, 0, 0)
                and os.access(app / PARAKEET_HELPER, os.X_OK)
                and f"{RESOURCES}/Legal/FluidAudio-LICENSE" in records,
                "Parakeet requires macOS 14+, its executable worker and the FluidAudio license.")
    else:
        require(PARAKEET_HELPER not in records, "Unconfigured Parakeet worker.")
    require(os.access(app / RESOURCES / "run-ctrlspeak", os.X_OK), "Wrapper is not executable.")
    require(runtime_packages(app / RUNTIME) == manifest["python_distributions"],
            "Python distributions differ from the manifest.")
    require(verify_native(app, records, minimum) == manifest["native_arm64_min_macos"],
            "Native deployment targets differ from the manifest.")
    return manifest


def stage(args):
    require(sys.platform == "darwin" and os.uname().machine == "arm64",
            "Staging requires native Apple Silicon macOS and the Apple CLT or Xcode.")
    minimum = args.min_macos
    require(macos_version(minimum) >= (13, 0, 0), "LocalVoice requires at least macOS 13.0.")
    parakeet = getattr(args, "parakeet_worker", None)
    if parakeet:
        require(macos_version(minimum) >= (14, 0, 0), "Parakeet packages require macOS 14.0 or later.")
        require(parakeet.is_file() and os.access(parakeet, os.X_OK),
                "The Parakeet worker must be an executable file.")
        require(args.parakeet_license.is_file() and args.parakeet_license.stat().st_size,
                "A non-empty FluidAudio license is required.")
    resource_bundle = getattr(args, "parakeet_resources", None)
    if resource_bundle:
        require(parakeet and resource_bundle.is_dir() and resource_bundle.name == "FluidAudio_FluidAudio.bundle",
                "Expected FluidAudio_FluidAudio.bundle from the worker build.")
    require(re.fullmatch(r"[0-9a-f]{64}", args.runtime_sha256),
            "--runtime-sha256 must be a lowercase SHA-256 digest.")
    source = args.source.resolve(strict=True)
    runtime = args.runtime.resolve(strict=True)
    require(sha256(source) == UPSTREAM_SHA256, f"Upstream archive SHA-256 must be {UPSTREAM_SHA256}.")
    require(sha256(runtime) == args.runtime_sha256, "Runtime archive SHA-256 mismatch.")
    if args.vad_artifact:
        require(sha256(args.vad_artifact) == VAD_SHA256, "Silero VAD artifact SHA-256 mismatch.")
        require(args.vad_license.is_file() and args.vad_license.stat().st_size,
                "--vad-license must be a non-empty upstream license file.")
    build_root = ROOT / "build"
    output = (ROOT / args.output).resolve()
    require(build_root == build_root.resolve() and output.is_relative_to(build_root)
            and output.name == "LocalVoice.app",
            "--output must be named LocalVoice.app inside the repository's physical build/ directory.")
    require(not output.exists(), f"Output already exists: {output}")
    version = (ROOT / "VERSION").read_text().strip()
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Invalid LocalVoice VERSION.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".localvoice-", dir=output.parent) as temp:
        work = Path(temp)
        app = work / "LocalVoice.app"
        resources = app / RESOURCES
        notices = resources / "Legal"
        notices.mkdir(parents=True)
        (app / "Contents/MacOS").mkdir()
        (app / "Contents/Helpers").mkdir()
        copy_source(source, work, resources / "ctrlspeak", notices)
        require((resources / "ctrlspeak/localvoice_models.py").is_file(),
                "The LocalVoice model store is missing from the patch set.")
        extract(runtime, app / RUNTIME, allow_links=True)
        packages = runtime_packages(app / RUNTIME)
        for name in ("LICENSE", "NOTICE.md"):
            shutil.copy2(ROOT / name, notices / f"LocalVoice-{name}")
        wrapper = resources / "run-ctrlspeak"
        shutil.copyfile(ROOT / "scripts/run-bundled-ctrlspeak.sh", wrapper)
        wrapper.chmod(0o755)
        config = LAUNCH_CONFIG
        if args.vad_artifact:
            shutil.copyfile(args.vad_artifact, resources / "silero_vad.jit")
            require(sha256(resources / "silero_vad.jit") == VAD_SHA256, "Silero VAD input changed.")
            shutil.copyfile(args.vad_license, notices / "Silero-VAD-LICENSE")
            config += VAD_CONFIG
        if parakeet:
            shutil.copyfile(parakeet, app / PARAKEET_HELPER)
            (app / PARAKEET_HELPER).chmod(0o755)
            shutil.copyfile(args.parakeet_license, notices / "FluidAudio-LICENSE")
            dependency_notices = args.parakeet_license.parent / "ThirdPartyLicenses"
            if dependency_notices.is_dir():
                shutil.copytree(dependency_notices, notices / "FluidAudio-ThirdPartyLicenses",
                                symlinks=True)
            if resource_bundle:
                shutil.copytree(resource_bundle, (app / PARAKEET_HELPER).parent / resource_bundle.name,
                                symlinks=True)
            config += PARAKEET_CONFIG
        (resources / "launch.conf").write_text(config)

        sdk = run("xcrun", "--sdk", "macosx", "--show-sdk-path").strip()
        # Keep compiler caches under staging as well, rather than the user's install.
        compile_env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET=minimum, TMPDIR=str(work),
                           CLANG_MODULE_CACHE_PATH=str(work / "module-cache"))

        def compile_swift(source_names, binary, *flags):
            run("xcrun", "--sdk", "macosx", "swiftc", "-target", f"arm64-apple-macosx{minimum}",
                "-sdk", sdk, "-module-cache-path", str(work / "module-cache"), *flags,
                *(str(ROOT / "src" / name) for name in source_names), "-o", str(binary),
                capture=False, env=compile_env)

        # Without Sparkle on the search path the updater compiles to its stub: this app has none.
        compile_swift(["ctrlspeak-launcher.swift", "localvoice-model-library.swift", "localvoice-updater.swift",
                       "localvoice-shortcuts.swift", "localvoice-shortcut-recorder.swift"],
                      app / ENTRYPOINTS[0], "-parse-as-library")
        compile_swift(["ctrlspeak-overlay.swift"], app / ENTRYPOINTS[1])
        icon_generator = work / "ctrlspeak-icon"
        compile_swift(["ctrlspeak-icon.swift"], icon_generator)
        install_app_icon(icon_generator, work, resources)

        info = {
            "CFBundleDisplayName": "LocalVoice",
            "CFBundleExecutable": "LocalVoice",
            "CFBundleIconFile": "LocalVoice",
            "CFBundleIdentifier": SERVICE_ID,
            "CFBundleName": "LocalVoice",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": minimum,
            "LSUIElement": True,
            "NSHighResolutionCapable": True,
            "NSMicrophoneUsageDescription": "LocalVoice records audio to transcribe speech on this Mac.",
            "NSAppleEventsUsageDescription": "LocalVoice can pause media while you dictate.",
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        records = inventory(app)
        manifest = {
            "schema": 1,
            "localvoice_version": version,
            "upstream": {"version": UPSTREAM_VERSION, "url": UPSTREAM_URL, "sha256": UPSTREAM_SHA256},
            "runtime_sha256": args.runtime_sha256,
            "silero_vad": VAD_SHA256 if args.vad_artifact else None,
            "parakeet_coreml": bool(parakeet),
            "python_distributions": packages,
            "architecture": "arm64",
            "min_macos": minimum,
            "build_sdk": run("xcrun", "--sdk", "macosx", "--show-sdk-version").strip(),
            "native_arm64_min_macos": verify_native(app, records, minimum),
            "status": "staged-unverified-for-distribution",
            "files": records,
        }
        (app / MANIFEST).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        # Reserve an empty destination before replacing it; never replace a
        # pre-existing bundle, even if another build ran during this one.
        output.mkdir()
        try:
            app.rename(output)
        except OSError:
            output.rmdir()
            raise
    print(f"Staged {output} (arm64, macOS {minimum}+).")
    print("Not signed for distribution, notarized, or runtime-tested.")


def main():
    parser = argparse.ArgumentParser(
        prog="build-app.sh",
        description="Stage an offline LocalVoice app, or verify a relocated pre-signing stage.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""\
Inputs (not acquired by this script):
  --source: {UPSTREAM_URL}
            SHA-256 {UPSTREAM_SHA256}
  --runtime: a tar archive rooted at bin/, lib/, and licenses/ (no enclosing
             directory), prepared for relocation. Include bin/python3.11,
             lib/python3.11/ and its complete site-packages, bin/ffmpeg, and all
             native dependencies. No venv or external install paths. Use a
             producer-verified archive digest. Preserve package license files
             (or add them to licenses/<normalized-distribution-name>/), plus
             licenses/CPython/ and licenses/FFmpeg/ and native dependency notices.
             Keep provenance and applicable source offers with the runtime.
   --vad-artifact: optional Silero VAD v6.2.1 silero_vad.jit
                  (SHA-256 {VAD_SHA256});
                   supply its upstream license with --vad-license.
   --parakeet-worker: executable built from providers/parakeet with a macOS 14+
                      deployment target. Also pass --parakeet-license and any
                      FluidAudio_FluidAudio.bundle via --parakeet-resources.
                      A ThirdPartyLicenses/ directory beside the license is copied.

  ./scripts/build-app.sh --source ctrlspeak-1.8.0.tar.gz --runtime runtime.tar.gz \\
      --runtime-sha256 <sha256> --min-macos 15.0
  ./scripts/build-app.sh --verify 'build/LocalVoice.app'

--verify checks contents, links, ARM64 slices, deployment targets and linked
libraries without launching the app or runtime. It is not a signature check,
release attestation, functionality test, or test on the minimum macOS version.
An appropriate private runtime, distribution signing, and notarization are
separate steps. Speech models aren't bundled; they are installed by the model library.
""",
    )
    parser.add_argument("--source", type=Path)
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--runtime-sha256")
    parser.add_argument("--vad-artifact", type=Path)
    parser.add_argument("--vad-license", type=Path)
    parser.add_argument("--parakeet-worker", type=Path)
    parser.add_argument("--parakeet-license", type=Path)
    parser.add_argument("--parakeet-resources", type=Path)
    parser.add_argument("--min-macos", help="explicit deployment target, e.g. 15.0")
    parser.add_argument("--output", type=Path, help="default: build/LocalVoice.app (must not exist)")
    parser.add_argument("--verify", type=Path, metavar="APP")
    args = parser.parse_args()
    try:
        if args.verify is not None:
            if any((args.source, args.runtime, args.runtime_sha256, args.min_macos, args.output,
                     args.vad_artifact, args.vad_license, args.parakeet_worker,
                     args.parakeet_license, args.parakeet_resources)):
                parser.error("--verify cannot be combined with build options")
            manifest = verify(args.verify)
            print(f"Verified staging layout: {args.verify} (arm64, macOS {manifest['min_macos']}+).")
        else:
            if not all((args.source, args.runtime, args.runtime_sha256, args.min_macos)):
                parser.error("building requires --source, --runtime, --runtime-sha256 and --min-macos")
            if bool(args.vad_artifact) != bool(args.vad_license):
                parser.error("--vad-artifact and --vad-license must be supplied together")
            if bool(args.parakeet_worker) != bool(args.parakeet_license):
                parser.error("--parakeet-worker and --parakeet-license must be supplied together")
            args.output = args.output or Path("build/LocalVoice.app")
            stage(args)
    except (ValueError, KeyError, TypeError, RuntimeError, OSError, tarfile.TarError,
            subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
