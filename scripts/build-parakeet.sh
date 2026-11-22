#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--help" ]]; then
  echo 'Usage: scripts/build-parakeet.sh [scratch-directory]'
  echo 'Build the ARM64 Core ML provider. SwiftPM fetches pinned build dependencies, not speech models.'
  exit 0
fi
[[ $# -le 1 && "$(uname -sm)" == "Darwin arm64" ]] || {
  echo 'An Apple Silicon Mac is required; pass at most one scratch directory.' >&2
  exit 1
}

SCRATCH="${1:-$ROOT/build/parakeet-worker}"
BUILD=(xcrun swift build --package-path "$ROOT/providers/parakeet" --scratch-path "$SCRATCH/build"
       --cache-path "$SCRATCH/cache" -c release)
"${BUILD[@]}" --force-resolved-versions --product localvoice-parakeet
PRODUCTS="$("${BUILD[@]}" --show-bin-path)"
printf 'Worker: %s/localvoice-parakeet\n' "$PRODUCTS"
printf 'License: %s/build/checkouts/FluidAudio/LICENSE\n' "$SCRATCH"
if [[ -d "$PRODUCTS/FluidAudio_FluidAudio.bundle" ]]; then
  printf 'Resources: %s/FluidAudio_FluidAudio.bundle\n' "$PRODUCTS"
fi
