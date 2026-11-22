#!/bin/bash
set -euo pipefail

RESOURCES="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNTIME="$RESOURCES/runtime"

# This private entry point must not fall through to upstream's unmanaged
# mode (which can start automatic model acquisition).
if [[ -z "${LOCALVOICE_MODEL_ID:-}" ]]; then
  echo "LocalVoice: launch the app and select an installed model first." >&2
  exit 78
fi

# Never fall back to Homebrew or the user's Python installation. The same
# environment is inherited by the microphone worker (spawned via sys.executable).
export PATH="$RUNTIME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Remove inherited Python settings before adding the two settings needed by
# both this process and the bundled interpreter's subprocesses.
for variable in ${!PYTHON@}; do
  unset "$variable"
done
unset __PYVENV_LAUNCHER__ VIRTUAL_ENV
unset DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH
unset DYLD_INSERT_LIBRARIES
export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
export CTRLSPEAK_OVERLAY_PATH="${RESOURCES%/Resources}/Helpers/ctrlspeak-overlay"

# The Python service reads the language from the user's LocalVoice config.
exec "$RUNTIME/bin/python3.11" "$RESOURCES/ctrlspeak/ctrlspeak.py" --model whisper-mlx "$@"
