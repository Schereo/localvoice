#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/localvoice-check.XXXXXXXX")"
trap 'rm -r "$BUILD"' EXIT
cd "$ROOT"
PYTHON="${LOCALVOICE_CHECK_PYTHON:-$(command -v python3)}"
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else "Python 3.9+ is required for tests")'

echo "Checking shell syntax"
bash -n install.sh
bash -n uninstall.sh
./install.sh --plan >/dev/null
for script in scripts/*.sh; do
  bash -n "$script"
done

echo "Checking Python sources"
"$PYTHON" - <<'PY'
from pathlib import Path

for root in (Path("patches"), Path("scripts"), Path("tests")):
    for path in sorted(root.rglob("*.py")):
        compile(path.read_bytes(), str(path), "exec")
PY

echo "Running isolated tests"
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m unittest discover -v -s tests

if [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]; then
  echo "Building macOS UI (no launch)"
  for product in ctrlspeak-icon ctrlspeak-overlay; do
    xcrun swiftc -target arm64-apple-macosx13.0 \
      -module-cache-path "$BUILD/module-cache" \
      "src/$product.swift" -o "$BUILD/$product"
  done
  xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx13.0 \
    -module-cache-path "$BUILD/module-cache" \
    src/ctrlspeak-launcher.swift src/localvoice-model-library.swift src/localvoice-updater.swift -o "$BUILD/LocalVoice"
  # The app build scripts compile in the default (Swift 5) language mode; check that too.
  xcrun swiftc -parse-as-library -target arm64-apple-macosx13.0 \
    -module-cache-path "$BUILD/module-cache" \
    src/ctrlspeak-launcher.swift src/localvoice-model-library.swift src/localvoice-updater.swift -o "$BUILD/LocalVoice-swift5"
  # The release build links Sparkle (the in-app updater); without it the updater compiles
  # to a stub. Check the real one too once scripts/fetch-sparkle.sh has run (CI does).
  sparkle="build/sparkle/$(sed -nE 's/^SPARKLE_VERSION="([^"]+)"$/\1/p' scripts/fetch-sparkle.sh)"
  if [[ -f "$sparkle/.unpacked" ]]; then
    xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx15.0 \
      -module-cache-path "$BUILD/module-cache" -F "$sparkle" -framework Sparkle \
      src/ctrlspeak-launcher.swift src/localvoice-model-library.swift src/localvoice-updater.swift \
      -o "$BUILD/LocalVoice-sparkle"
    otool -L "$BUILD/LocalVoice-sparkle" | grep -q "@rpath/Sparkle.framework/"
  else
    echo "Skipping the Sparkle build: run scripts/fetch-sparkle.sh first"
  fi
  xcrun swiftc -parse-as-library -target arm64-apple-macosx13.0 \
    -module-cache-path "$BUILD/module-cache" -D MODEL_LIBRARY_PREVIEW \
    src/localvoice-model-library.swift -o "$BUILD/model-library"
  xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx13.0 \
    -module-cache-path "$BUILD/module-cache" -D PERMISSIONS_PREVIEW \
    src/ctrlspeak-launcher.swift src/localvoice-model-library.swift src/localvoice-updater.swift -o "$BUILD/permissions-preview"
  xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx13.0 \
    -module-cache-path "$BUILD/module-cache" -D SETTINGS_PREVIEW \
    src/ctrlspeak-launcher.swift src/localvoice-model-library.swift src/localvoice-updater.swift -o "$BUILD/settings-preview"
  xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macosx13.0 \
    -module-cache-path "$BUILD/module-cache" \
    src/localvoice-model-library.swift tests/model_library_smoke.swift -o "$BUILD/model-library-smoke"
  "$BUILD/model-library-smoke" "$BUILD" "$PYTHON"
else
  echo "Skipping native builds: Apple Silicon macOS required"
fi
