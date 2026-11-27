#!/bin/bash

set -euo pipefail

# Drives the pill from the current source: it is compiled into a temporary
# directory first (a few seconds). LOCALVOICE_OVERLAY=<binary> uses an existing
# build instead, e.g. LocalVoice.app/Contents/Helpers/ctrlspeak-overlay.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${LOCALVOICE_OVERLAY:-}"
if [[ -z "$OVERLAY" ]]; then
  BUILD="$(mktemp -d "${TMPDIR:-/tmp}/localvoice-overlay.XXXXXXXX")"
  trap 'rm -r "$BUILD"' EXIT
  xcrun swiftc -module-cache-path "$BUILD/module-cache" \
    "$PROJECT_DIR/src/ctrlspeak-overlay.swift" -o "$BUILD/ctrlspeak-overlay"
  OVERLAY="$BUILD/ctrlspeak-overlay"
fi

MODE="${1:-preview}"

case "$MODE" in
  preview)
    "$OVERLAY" "$MODE"
    ;;

  recording)
    # Simulated levels, so the waveform and the timer can be checked
    # without holding a real recording open.
    {
      for step in $(seq 0 120); do
        awk -v step="$step" 'BEGIN { printf "level %.4f\n", 0.2 + 0.7 * (sin(step / 3.0) ^ 2) }'
        sleep 0.04
      done
      printf 'quit\n'
    } | "$OVERLAY" recording
    ;;

  live)
    # The live-preview pill: confirmed text joins after each pause, the
    # dimmed guess of the open phrase updates in between and the capsule
    # grows to fit up to two lines.
    {
      feed_levels() {
        for step in $(seq 0 "$1"); do
          awk -v step="$step" 'BEGIN { printf "level %.4f\n", 0.2 + 0.7 * (sin(step / 3.0) ^ 2) }'
          sleep 0.04
        done
      }
      feed_levels 30
      printf 'partial Das hier ist die\n'
      feed_levels 20
      printf 'partial Das hier ist die gedimmte Live-Vermutung\n'
      feed_levels 20
      printf 'final Das hier ist die gedimmte Live-Vermutung, jetzt bestätigt.\n'
      printf 'partial\n'
      feed_levels 30
      printf 'partial und hier spricht man gerade weiter\n'
      feed_levels 30
      printf 'final Das hier ist die gedimmte Live-Vermutung, jetzt bestätigt. Und hier spricht man gerade weiter, bis der Text über zwei Zeilen läuft und vorne rausscrollt.\n'
      printf 'partial während die Vermutung gedimmt hinterherläuft\n'
      feed_levels 80
      printf 'state processing\n'
      sleep 1
      printf 'state success\n'
      sleep 1.5
      printf 'quit\n'
    } | "$OVERLAY" recording
    ;;

  start)
    # The start as the service drives it: the waiting pill appears as a circle
    # at the hotkey, then grows into the pill once the microphone is open.
    # MIC_DELAY imitates the microphone (Bluetooth inputs take much longer).
    {
      sleep 0.6
      printf 'arm\n'
      sleep "${MIC_DELAY:-0.15}"
      printf 'show de\n'
      for step in $(seq 0 60); do
        awk -v step="$step" 'BEGIN { printf "level %.4f\n", 0.2 + 0.7 * (sin(step / 3.0) ^ 2) }'
        sleep 0.04
      done
      printf 'state processing\n'
      sleep 1
      printf 'state success\n'
      sleep 1.5
      printf 'quit\n'
    } | "$OVERLAY" standby
    ;;

  permission)
    {
      printf 'detail Microphone · Accessibility\n'
      sleep 6
      printf 'quit\n'
    } | "$OVERLAY" permission
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
    } | "$OVERLAY" download
    ;;

  *)
    echo "Usage: $(basename "$0") [preview|recording|start|live|permission|download]" >&2
    exit 1
    ;;
esac
