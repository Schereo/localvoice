#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
  printf '%s\n' \
    'Usage: scripts/check-nvidia.sh --download /path/to/localvoice-parakeet' \
    '       scripts/check-nvidia.sh --reuse-store /path/to/Models /path/to/localvoice-parakeet' \
    'Explicit --download fetches about 1.95 GB into a disposable directory.' \
    'Both modes transcribe synthetic German and English with networking blocked.'
}
case "${1:-}" in
  --download) [[ $# -eq 2 ]] || { usage >&2; exit 2; }; WORKER="$2" ;;
  --reuse-store) [[ $# -eq 3 && -d "$2" ]] || { usage >&2; exit 2; }; WORKER="$3" ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ "$(uname -sm)" == "Darwin arm64" && -x "$WORKER" ]] || {
  echo 'Apple Silicon and an executable Core ML worker are required.' >&2
  exit 2
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/localvoice-nvidia.XXXXXXXX")"
trap 'rm -r "$WORK"' EXIT
WORKER_DIR="$(cd "$(dirname "$WORKER")" && pwd)"
HELPERS="$WORK/Moved LocalVoice.app/Contents/Helpers"
mkdir -p "$HELPERS"
cp "$WORKER" "$HELPERS/localvoice-parakeet"
if [[ -d "$WORKER_DIR/FluidAudio_FluidAudio.bundle" ]]; then
  cp -R "$WORKER_DIR/FluidAudio_FluidAudio.bundle" "$HELPERS/"
fi
export LOCALVOICE_PARAKEET_WORKER="$HELPERS/localvoice-parakeet"
export HF_HUB_CACHE="$WORK/empty-hub"
export LOCALVOICE_MODELS_DIR="$WORK/Models"
if [[ "$1" == "--reuse-store" ]]; then
  LOCALVOICE_MODELS_DIR="$(cd "$2" && pwd)"
fi

MODELS=(parakeet-v3 parakeet-ultra parakeet-redux nemotron-streaming)
if [[ "$1" == "--download" ]]; then
  echo 'Downloading 1.95 GB of pinned assets into the temporary model store.'
  for model in "${MODELS[@]}"; do
    echo "Downloading $model"
    if ! python3 -I -B "$ROOT/patches/ctrlspeak-1.8.0/localvoice_models.py" \
        download "$model" > "$WORK/download.jsonl"; then
      tail -n 1 "$WORK/download.jsonl" >&2
      exit 1
    fi
  done
fi

say -v Anna -o "$WORK/de.aiff" 'Guten Morgen. Das ist ein Test für die lokale Spracherkennung.'
say -v Samantha -o "$WORK/en.aiff" 'Good morning. This is a test of local speech recognition.'
for lang in de en; do
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/$lang.aiff" "$WORK/$lang.wav"
done

for model in "${MODELS[@]}"; do
  sandbox-exec -p '(version 1) (allow default) (deny network*)' \
    "$(command -v python3)" -I -B "$ROOT/scripts/smoke-parakeet.py" "$model" \
    --worker "$LOCALVOICE_PARAKEET_WORKER" \
    --wav "$WORK/de.wav" --expect 'Guten Morgen' --wav "$WORK/en.wav" --expect 'Good morning'
done
