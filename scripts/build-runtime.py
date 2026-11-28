"""Produce the private runtime consumed by build-app.sh from local, locked inputs."""

import argparse
import gzip
import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from email.parser import BytesParser
from pathlib import Path, PurePosixPath


SPEC = importlib.util.spec_from_file_location("build_app", Path(__file__).with_name("build-app.py"))
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)
require = app.require
HASH = r"[0-9a-f]{64}"
PIN = re.compile(rf"([A-Za-z0-9][A-Za-z0-9._-]*)\s*==\s*"
                 rf"([A-Za-z0-9][A-Za-z0-9_.+!-]*)\s+--hash=sha256:({HASH})")
SITE = Path("lib/python3.11/site-packages")


def normal(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def parse_lock(text):
    pins = {}
    text = re.sub(r"\\\r?\n", " ", text)
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        pin = PIN.fullmatch(line)
        require(pin, f"Invalid lock line {number}; expected NAME==VERSION --hash=sha256:DIGEST.")
        name, version, digest = pin.groups()
        name = normal(name)
        require(name not in pins and name != "pip", f"Duplicate or reserved lock name: {name}")
        pins[name] = (version, digest)
    require(pins, "The wheel lock is empty.")
    require(len({digest for _, digest in pins.values()}) == len(pins), "Duplicate wheel hash in lock.")
    return pins


def read_wheel(path):
    """Validate names before pip sees any wheel bytes; reject startup hooks."""
    with zipfile.ZipFile(path) as wheel:
        entries = set()
        metadata = []
        setuptools_hook = False
        for entry in wheel.infolist():
            p = PurePosixPath(entry.filename)
            require(p.parts and not p.is_absolute() and ".." not in p.parts
                    and "\\" not in entry.filename and not stat.S_ISLNK(entry.external_attr >> 16),
                    f"Unsafe wheel member: {path.name}: {entry.filename}")
            key = str(p).casefold()
            require(key not in entries, f"Duplicate wheel member: {path.name}: {entry.filename}")
            entries.add(key)
            # Recent torch requires setuptools. Its known top-level .pth is
            # inert here (-S) and removed from the finished runtime.
            setuptools_hook |= str(p) == "distutils-precedence.pth"
            require((p.suffix.lower() not in {".pth", ".egg-link", ".pyc", ".pyo"}
                     or str(p) == "distutils-precedence.pth")
                    and p.name not in {"sitecustomize.py", "usercustomize.py"},
                    f"Non-portable wheel member: {path.name}: {entry.filename}")
            if len(p.parts) == 2 and p.parts[0].endswith(".dist-info") and p.name == "METADATA":
                metadata.append(entry)
        require(len(metadata) == 1, f"Expected one .dist-info/METADATA in {path.name}.")
        with wheel.open(metadata[0]) as source:
            record = BytesParser().parse(source, headersonly=True)
        require(record["Name"] and record["Version"], f"Incomplete METADATA: {path.name}")
        name = normal(record["Name"])
        require(not setuptools_hook or name == "setuptools", f"Unexpected .pth file: {path.name}")
        return name, record["Version"]


def prepare_wheels(wheelhouse, pins, directory):
    directory.mkdir()
    locked = {digest: (name, version) for name, (version, digest) in pins.items()}
    chosen = {}
    for source in sorted(wheelhouse.glob("*.whl")):
        require(source.is_file() and not source.is_symlink(), f"Not a regular wheel: {source}")
        digest = app.sha256(source)
        if digest not in locked:
            continue
        name, version = locked[digest]
        require(name not in chosen, f"Ambiguous wheel for {name}.")
        destination = directory / source.name
        shutil.copyfile(source, destination)
        require(app.sha256(destination) == digest, f"Wheel changed while copying: {source}")
        require(read_wheel(destination) == (name, version),
                f"Wheel metadata differs from the lock: {source.name}")
        chosen[name] = {"version": version, "wheel": source.name, "sha256": digest}
    missing = pins.keys() - chosen.keys()
    require(not missing, f"No wheel for locked packages: {', '.join(sorted(missing))}")
    return chosen


def extract_pinned(path, expected, destination):
    require(re.fullmatch(HASH, expected), f"Expected a lowercase SHA-256 digest for {path.name}.")
    # Verify the same bytes that are extracted, not a mutable caller path.
    private = destination.with_suffix(".tar")
    shutil.copyfile(path, private)
    require(app.sha256(private) == expected, f"SHA-256 mismatch: {path}")
    app.extract(private, destination, allow_links=True)
    private.unlink()


def merge(source, destination):
    """Merge only disjoint regular files/relative links, without following links."""
    for item in sorted(source.iterdir()):
        output = destination / item.name
        if item.is_dir() and not item.is_symlink():
            if not output.exists():
                output.mkdir()
            require(output.is_dir() and not output.is_symlink(), f"Runtime path collision: {output}")
            merge(item, output)
        else:
            require(not output.exists() and not output.is_symlink(), f"Runtime path collision: {output}")
            if item.is_symlink():
                output.symlink_to(os.readlink(item))
            else:
                shutil.copy2(item, output)


def copy_licenses(source, destination):
    destination.mkdir()
    for item in sorted(source.rglob("*")):
        target = destination / item.relative_to(source)
        require(not item.is_symlink(), f"Supply a real license file, not a symlink: {item}")
        if item.is_dir():
            target.mkdir()
        else:
            require(item.is_file(), f"Unsupported license entry: {item}")
            shutil.copyfile(item, target)
    for name in ("CPython", "FFmpeg"):
        directory = destination / name
        require(directory.is_dir() and any(p.is_file() and p.stat().st_size
                                           for p in directory.rglob("*")),
                f"Supply license and notice files in --licenses/{name}/.")


def native_targets(runtime, minimum):
    """Preflight Mach-O min targets. build-app also verifies the full dyld graph."""
    images = {}
    for path in sorted(runtime.rglob("*")):
        if path.is_symlink():
            app.check_link(runtime, path)
            continue
        if not path.is_file():
            continue
        with path.open("rb") as source:
            if source.read(4) not in app.MACH_MAGICS:
                continue
        name = path.relative_to(runtime).as_posix()
        target, loads, rpaths, kind = app.native_info(path)
        require(app.macos_version(target) <= app.macos_version(minimum),
                f"{name} needs macOS {target}, above declared macOS {minimum}.")
        for value in loads + rpaths:
            token, _, suffix = value.partition("/")
            if token in {"@loader_path", "@executable_path", "@rpath"}:
                relative = Path(suffix)
                require(suffix and not relative.is_absolute(), f"Invalid dyld path in {name}: {value}")
                if token == "@rpath":
                    safe = ".." not in relative.parts
                else:
                    base = path.parent if token == "@loader_path" else runtime / "bin"
                    safe = (base / relative).resolve().is_relative_to(runtime)
            else:
                safe = app.system_location(value)
            require(safe, f"Non-portable dyld path in {name}: {value}")
        images[name] = {"min_macos": target, "type": kind}
    for entry in ("bin/python3.11", "bin/ffmpeg"):
        path = (runtime / entry).resolve(strict=True)
        require(path.is_relative_to(runtime) and os.access(path, os.X_OK) and
                images.get(path.relative_to(runtime).as_posix(), {}).get("type") == "EXECUTE",
                f"Missing ARM64 Mach-O executable: {entry}")
    return images


PIP_MAIN = (
    "import runpy,sys; "
    "bootstrap,site=sys.argv[1:3]; "
    "sys.argv=sys.argv[2:]; "
    "sys.path.insert(0,bootstrap); import pip; sys.path.pop(0); "
    "sys.path.append(site); runpy.run_module('pip',run_name='__main__')"
)


def pip_environment(work):
    home = work / "home"
    home.mkdir()
    temp = work / "tmp"
    temp.mkdir()
    return {
        "PATH": app.SYSTEM_PATH, "HOME": str(home), "TMPDIR": str(temp),
        "PIP_CONFIG_FILE": os.devnull,
    }


def pip_install(python, bootstrap, site, wheels, lock, env):
    command = (str(python), "-I", "-S", "-B", "-c", PIP_MAIN, str(bootstrap), str(site),
               "--isolated", "--no-cache-dir", "--disable-pip-version-check", "--no-input")
    app.run(*command, "install", "--no-index", "--find-links", wheels.as_uri(),
            "--require-hashes", "--only-binary", ":all:", "--no-deps", "--no-compile",
            "--target", str(site), "-r", str(lock), capture=False, env=env)
    (site / "distutils-precedence.pth").unlink(missing_ok=True)
    app.run(*command, "check", capture=False, env=env)


def install_wheels(python, bootstrap, site, wheels, lock, work):
    env = pip_environment(work)
    info = app.run(str(python), "-I", "-S", "-B", "-c",
                   "import json,sys; print(json.dumps([sys.version_info[:3], sys.prefix]))",
                   env=env)
    version, prefix = json.loads(info)
    require(version[:2] == [3, 11] and Path(prefix).resolve() == python.parent.parent,
            "CPython 3.11 must discover its private prefix without a venv or PYTHONHOME.")
    pip_install(python, bootstrap, site, wheels, lock, env)
    # Console entry points contain the temporary interpreter's absolute shebang.
    # LocalVoice calls the Python modules and ffmpeg directly, not these scripts.
    if (site / "bin").is_dir():
        shutil.rmtree(site / "bin")
    return ".".join(map(str, version))


def write_archive(runtime, path):
    """Write a sorted, timestamp/ownership-normalized tar.gz accepted by build-app."""
    with path.open("xb") as stream, gzip.GzipFile(filename="", fileobj=stream, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for item in sorted(runtime.rglob("*")):
                member = tarfile.TarInfo(item.relative_to(runtime).as_posix())
                info = item.lstat()
                if stat.S_ISLNK(info.st_mode):
                    app.check_link(runtime, item)
                    member.type = tarfile.SYMTYPE
                    member.linkname = os.readlink(item)
                    tar.addfile(member)
                elif stat.S_ISDIR(info.st_mode):
                    member.type = tarfile.DIRTYPE
                    member.mode = 0o755
                    tar.addfile(member)
                else:
                    require(stat.S_ISREG(info.st_mode), f"Unsupported runtime file: {item}")
                    member.mode = 0o755 if info.st_mode & 0o111 else 0o644
                    member.size = info.st_size
                    with item.open("rb") as source:
                        tar.addfile(member, source)


def produce(args, work):
    lock = args.requirements.read_bytes()
    pins = parse_lock(lock.decode())
    missing = app.REQUIRED_PACKAGES - pins.keys()
    require(not missing, f"Missing required lock entries: {', '.join(sorted(missing))}")
    for name, version in app.PINNED_PACKAGES.items():
        require(pins[name][0] == version, f"LocalVoice requires {name}=={version}.")
    wheels = work / "wheels"
    chosen = prepare_wheels(args.wheelhouse, pins, wheels)
    local_lock = work / "requirements.lock"
    local_lock.write_text("".join(f"{name}=={version} --hash=sha256:{digest}\n"
                                  for name, (version, digest) in sorted(pins.items())))

    extract_pinned(args.python, args.python_sha256, work / "python-input")
    extract_pinned(args.ffmpeg, args.ffmpeg_sha256, work / "ffmpeg-input")
    python_source = work / "python-input/python"
    baseline = python_source / SITE
    python = python_source / "bin/python3.11"
    require(python.is_file() and python.resolve().parent == python.parent
            and (python_source / "lib/python3.11/encodings/__init__.py").is_file(),
            "Expected a standalone CPython install_only archive rooted at python/.")
    require(not any(python_source.rglob("pyvenv.cfg")), "A virtualenv is not a standalone CPython.")
    ffmpeg = work / "ffmpeg-input"
    require((ffmpeg / "bin/ffmpeg").is_file() and
            all(p.name in {"bin", "lib"} and p.is_dir() and not p.is_symlink() for p in ffmpeg.iterdir()),
            "Expected the portable FFmpeg archive to contain bin/ffmpeg and optionally lib/.")

    runtime = work / "runtime"
    (runtime / "bin").mkdir(parents=True)
    shutil.copy2(python, runtime / "bin/python3.11", follow_symlinks=True)
    # The archive is known to have internal links only. Retain shared libraries
    # and stdlib, but not CPython's preinstalled distributions or build tools.
    require(not (python_source / "lib").is_symlink() and not baseline.is_symlink(),
            "Expected real lib/ and site-packages directories in CPython.")
    shutil.move(str(python_source / "lib"), str(runtime / "lib"))
    site = runtime / SITE
    bootstrap = work / "bootstrap"
    bootstrap.mkdir()
    if (site / "pip/__init__.py").is_file():
        # Only pip comes from the base, not setuptools or any other package.
        shutil.copytree(site / "pip", bootstrap / "pip")
    else:
        bundled = sorted((site.parent / "ensurepip/_bundled").glob("pip-*.whl"))
        require(len(bundled) == 1, "The CPython input needs a packaged pip or one ensurepip pip wheel.")
        shutil.copyfile(bundled[0], bootstrap / bundled[0].name)
        bootstrap /= bundled[0].name
    if site.exists():
        shutil.rmtree(site)
    site.mkdir()
    # No generated bytecode or bootstrap wheel copies in the runtime payload.
    for path in sorted((runtime / "lib").rglob("__pycache__"), reverse=True):
        if path.is_symlink():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
    bundled = site.parent / "ensurepip/_bundled"
    if bundled.is_dir() and not bundled.is_symlink():
        shutil.rmtree(bundled)
    merge(ffmpeg, runtime)
    copy_licenses(args.licenses, runtime / "licenses")
    native_targets(runtime, args.min_macos)
    if args.check_inputs:
        return

    python_version = install_wheels(runtime / "bin/python3.11", bootstrap, site, wheels, local_lock, work)
    # Strip unused stdlib GUI/doc/test trees and C headers from the runtime payload.
    for rel in (
        "lib/python3.11/ensurepip",
        "lib/python3.11/idlelib",
        "lib/python3.11/tkinter",
        "lib/python3.11/lib2to3",
        "lib/python3.11/pydoc_data",
        "lib/python3.11/turtledemo",
        "lib/python3.11/turtle.py",
        "lib/python3.11/test",
        "lib/python3.11/site-packages/mlx/include",
    ):
        target = runtime / rel
        if target.is_symlink() or target.is_file():
            target.unlink(missing_ok=True)
        elif target.is_dir():
            shutil.rmtree(target)
    for pattern in ("tcl*", "tk*", "itcl*", "libtcl*", "libtk*", "tdbc*", "thread*"):
        for match in (runtime / "lib").glob(pattern):
            if match.is_symlink() or match.is_file():
                match.unlink(missing_ok=True)
            elif match.is_dir():
                shutil.rmtree(match)
    for test_dir in sorted(site.rglob("*"), reverse=True):
        if test_dir.is_dir() and not test_dir.is_symlink() and test_dir.name in {"tests", "test", "testing"}:
            shutil.rmtree(test_dir)
    require(app.runtime_packages(runtime) == {name: version for name, (version, _) in pins.items()},
            "Installed distributions don't match the wheel lock.")
    targets = native_targets(runtime, args.min_macos)
    provenance = {
        "schema": 1,
        "architecture": "arm64",
        "min_macos": args.min_macos,
        "python": {"version": python_version, "archive_sha256": args.python_sha256},
        "ffmpeg": {"archive_sha256": args.ffmpeg_sha256},
        "requirements_sha256": hashlib.sha256(lock).hexdigest(),
        "wheels": chosen,
        "native_arm64": targets,
        "status": "staging-input-not-cleared-for-distribution",
    }
    (runtime / "runtime-provenance.json").write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
    shutil.copyfile(local_lock, runtime / "requirements.lock")
    artifact = work / "runtime.tar.gz"
    write_archive(runtime, artifact)
    os.link(artifact, args.output)
    print(f"Runtime archive: {args.output}")
    print(f"--runtime-sha256 {app.sha256(args.output)}")


def main():
    parser = argparse.ArgumentParser(
        prog="build-runtime.sh",
        description="Produce a private LocalVoice ARM64 runtime from explicit local inputs. No downloads.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Input contract:
  --python: trusted ARM64 CPython 3.11 install_only tar, rooted at python/.
            Requires an already-local pip or the CPython-bundled ensurepip wheel.
  --ffmpeg: trusted portable tar rooted at bin/ffmpeg and optionally lib/.
            Do not provide a Homebrew keg, dylibs using an external prefix, or a venv.
  --requirements: platform-specific lock of NAME==VERSION --hash=sha256:DIGEST
                  (one wheel hash per project, including all transitive dependencies).
  --wheelhouse: flat directory containing the locked .whl files.
  --licenses: reviewed license/notice tree, including CPython/ and FFmpeg/.
              Add licenses for native dependencies and any wheel without its own
              license file in <normalized-distribution-name>/. Include applicable
              source offers. This script does not determine redistribution rights.
  --check-inputs: validate locks, archives, legal input presence and base executables;
                  do not execute bundled Python/pip or create an archive.

Use the emitted tar.gz as --runtime in build-app.sh, along with its printed
--runtime-sha256 and the same --min-macos. Build-app checks the whole dyld graph.
Neither tool proves runtime behavior on that OS or clears legal/signing checks.
""",
    )
    for name in ("python", "ffmpeg", "wheelhouse", "requirements", "licenses"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    for name in ("python-sha256", "ffmpeg-sha256", "min-macos"):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--check-inputs", action="store_true")
    parser.add_argument("--output", type=Path, help="default: build/localvoice-runtime-arm64.tar.gz")
    args = parser.parse_args()
    try:
        require(sys.platform == "darwin" and os.uname().machine == "arm64",
                "Building or preflighting the runtime requires Apple Silicon and Xcode CLT.")
        require(app.macos_version(args.min_macos) >= (13, 0, 0), "LocalVoice requires macOS 13 or later.")
        require(args.wheelhouse.is_dir() and args.licenses.is_dir(),
                "--wheelhouse and --licenses must be directories.")
        build = app.ROOT / "build"
        require(build.resolve() == build, "Expected a physical build/ directory.")
        if args.check_inputs:
            require(args.output is None, "--check-inputs does not take --output.")
            parent = build
        else:
            args.output = (app.ROOT / (args.output or build / "localvoice-runtime-arm64.tar.gz")).resolve()
            require(args.output.is_relative_to(build) and args.output.name.endswith(".tar.gz"),
                    "--output must be a .tar.gz under the repository's build/ directory.")
            require(not args.output.exists(), f"Output already exists: {args.output}")
            parent = args.output.parent
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".runtime-", dir=parent) as directory:
            produce(args, Path(directory))
        if args.check_inputs:
            print("Runtime inputs passed offline preflight (no bundled code executed).")
    except (ValueError, KeyError, RuntimeError, OSError, tarfile.TarError, zipfile.BadZipFile,
            subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
