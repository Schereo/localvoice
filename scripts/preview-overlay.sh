#!/bin/bash

set -euo pipefail

command -v ctrlspeak-overlay >/dev/null 2>&1 || {
  echo "ctrlspeak-overlay is not installed. Run ./install.sh first." >&2
  exit 1
}

MODE="${1:-preview}"

case "$MODE" in
  preview | language)
    ctrlspeak-overlay "$MODE"
    ;;

  recording)
    # Simulated levels, so the waveform and the language badge can be checked
    # without holding a real recording open.
    {
      for step in $(seq 0 120); do
        awk -v step="$step" 'BEGIN { printf "level %.4f\n", 0.2 + 0.7 * (sin(step / 3.0) ^ 2) }'
        sleep 0.04
      done
      printf 'quit\n'
    } | ctrlspeak-overlay recording
    ;;

  permission)
    {
      printf 'detail Microphone · Accessibility\n'
      sleep 6
      printf 'quit\n'
    } | ctrlspeak-overlay permission
    ;;

  download)
    TOTAL_MB=1614
    {
      # Start indeterminate, the way a real run looks until the repo size
      # comes back from Hugging Face.
      printf 'detail whisper-large-v3-turbo · starting\n'
      sleep 1.5

      for step in $(seq 0 100); do
        awk -v step="$step" 'BEGIN { printf "progress %.4f\n", step / 100 }'
        awk -v step="$step" -v total="$TOTAL_MB" \
          'BEGIN { printf "detail whisper-large-v3-turbo · %d MB of 1.6 GB\n", total * step / 100 }'
        sleep 0.05
      done

      sleep 0.5
      printf 'quit\n'
    } | ctrlspeak-overlay download
    ;;

  *)
    echo "Usage: $(basename "$0") [preview|recording|permission|download|language]" >&2
    exit 1
    ;;
esac
