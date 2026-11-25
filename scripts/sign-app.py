#!/usr/bin/env python3
"""Sign LocalVoice.app with a Developer ID so Apple can notarize it.

`codesign --deep` is not enough: every Mach-O file in the bundle (the embedded
Python, each .so/.dylib from the wheels, the helpers) needs its own signature
with the hardened runtime and a secure timestamp, signed inside-out before the
bundle itself. The embedded Python's executables get the entitlements from
scripts/entitlements/python.plist; the app gets scripts/entitlements/app.plist.

  python3 -B scripts/sign-app.py build/dev/LocalVoice.app \\
      --identity "Developer ID Application: Name (TEAMID)"
"""

import argparse
import concurrent.futures
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
ENTITLEMENTS = ROOT / "scripts/entitlements"
RUNTIME = Path("Contents/Resources/runtime")

THIN_MAGICS = {
    b"\xfe\xed\xfa\xce": ">", b"\xce\xfa\xed\xfe": "<",  # 32-bit
    b"\xfe\xed\xfa\xcf": ">", b"\xcf\xfa\xed\xfe": "<",  # 64-bit
}
FAT_MAGIC, FAT_MAGIC_64 = b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"
MH_EXECUTE, MH_DYLIB, MH_BUNDLE = 2, 6, 8
SIGNABLE = {MH_EXECUTE, MH_DYLIB, MH_BUNDLE}


def macho_type(path):
    """The Mach-O file type (MH_EXECUTE, MH_DYLIB, …), or None for any other file."""
    try:
        with open(path, "rb") as stream:
            header = stream.read(32)
            if header[:4] in (FAT_MAGIC, FAT_MAGIC_64):
                count = struct.unpack(">I", header[4:8])[0]
                # Java class files share 0xcafebabe; their version field is far above this.
                if not 0 < count < 32 or len(header) < 24:
                    return None
                # The first fat_arch (or fat_arch_64) entry points at the first slice.
                if header[:4] == FAT_MAGIC:
                    offset = struct.unpack(">I", header[16:20])[0]
                else:
                    offset = struct.unpack(">Q", header[16:24])[0]
                stream.seek(offset)
                header = stream.read(16)
            endian = THIN_MAGICS.get(header[:4])
            if endian is None or len(header) < 16:
                return None
            return struct.unpack(endian + "I", header[12:16])[0]
    except OSError:
        return None


def plan(app):
    """(path, entitlements or None) for every nested Mach-O, the unsignable ones, and the app.

    Nested bundles are refused, so the nested files are independent of each other
    and only the app itself has to come last."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    main = app / "Contents/MacOS" / info["CFBundleExecutable"]
    nested, skipped = [], []
    for directory, folders, files in os.walk(app):
        here = Path(directory)
        for folder in folders:
            if Path(folder).suffix in {".app", ".framework", ".appex", ".xpc", ".bundle"}:
                sys.exit(f"Nested bundle {here / folder} needs bundle signing; extend sign-app.py.")
        for name in files:
            path = here / name
            if path.is_symlink() or path == main:
                continue
            kind = macho_type(path)
            if kind is None:
                continue
            if kind not in SIGNABLE:
                skipped.append(path)  # object files and debug symbols carry no signature
                continue
            relative = path.relative_to(app)
            python = kind == MH_EXECUTE and RUNTIME in relative.parents
            nested.append((path, ENTITLEMENTS / "python.plist" if python else None))
    return sorted(nested), skipped, (app, ENTITLEMENTS / "app.plist")


def codesign(path, entitlements, identity, keychain, attempts=3):
    command = ["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime"]
    if keychain:
        command += ["--keychain", keychain]
    if entitlements:
        command += ["--entitlements", str(entitlements)]
    for attempt in range(1, attempts + 1):
        result = subprocess.run([*command, str(path)], capture_output=True, text=True)
        if result.returncode == 0:
            return
        # The timestamp server is the usual cause of transient failures.
        if attempt == attempts:
            raise RuntimeError(f"codesign failed for {path}:\n{result.stderr.strip()}")
        time.sleep(2 * attempt)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path, help="the .app bundle to sign in place")
    parser.add_argument("--identity", default=os.environ.get("CODESIGN_IDENTITY"),
                        help="Developer ID Application identity (default: $CODESIGN_IDENTITY)")
    parser.add_argument("--keychain", help="only look for the identity in this keychain")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = parser.parse_args()
    if not args.identity:
        parser.error("--identity or CODESIGN_IDENTITY is required.")
    if not args.identity.startswith("Developer ID Application:"):
        parser.error("Notarization needs a 'Developer ID Application: …' identity.")
    app = args.app.resolve(strict=True)
    if app.suffix != ".app" or not (app / "Contents/Info.plist").is_file():
        parser.error(f"Not an app bundle: {app}")

    nested, skipped, bundle = plan(app)
    python = sum(1 for _, entitlements in nested if entitlements)
    print(f"Signing {len(nested)} nested Mach-O files ({python} with Python entitlements), then the app…",
          flush=True)
    for path in skipped:
        print(f"  not signable, left as is: {path.relative_to(app)}")
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for future in [pool.submit(codesign, path, entitlements, args.identity, args.keychain)
                       for path, entitlements in nested]:
            future.result()
    codesign(*bundle, args.identity, args.keychain)

    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True)
    # --deep verification skips code in Resources (it is sealed as data), so check those files too.
    def verify(path):
        result = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)],
                                capture_output=True, text=True)
        return None if result.returncode == 0 else f"{path.relative_to(app)}: {result.stderr.strip()}"
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        failures = [message for message in pool.map(verify, [path for path, _ in nested]) if message]
    if failures:
        sys.exit("Signature check failed:\n" + "\n".join(failures))
    print(f"Signed {app.name} as {args.identity}.")


if __name__ == "__main__":
    main()
