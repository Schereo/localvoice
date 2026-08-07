#!/bin/bash

set -euo pipefail

SERVICE_LABEL="com.localvoice.ctrlspeak"
MODEL_REPO="models--mlx-community--whisper-large-v3-turbo"

KEEP_BREW=1
REMOVE_MODEL=0
ASSUME_YES=0

usage() {
  cat <<'USAGE'
Usage: ./uninstall.sh [options]

Removes this local dictation setup: the LaunchAgent, the ctrlSPEAK app bundle,
the recording pill, the wrapper, and the patches applied to ctrlSPEAK (the
original files are restored from the backups install.sh made).

Options:
  --remove-model   Also delete the 1.6-GB Whisper model from the Hugging Face
                   cache. Left in place by default, so a reinstall is fast.
  --remove-brew    Also run "brew uninstall ctrlspeak". FFmpeg is never touched,
                   since other software commonly depends on it.
  --yes            Do not ask for confirmation.
  --help           Show this message.

ctrlSPEAK's own privacy-pane entries are cleared via tccutil.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove-model) REMOVE_MODEL=1 ;;
    --remove-brew) KEEP_BREW=0 ;;
    --yes | -y) ASSUME_YES=1 ;;
    --help | -h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This uninstaller only supports macOS." >&2
  exit 1
fi

CURRENT_UID="$(id -u)"
APP_PATH="$HOME/Applications/ctrlSPEAK.app"
LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"

BREW_PREFIX=""
CTRLSPEAK_LIBEXEC=""
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix)"
  if brew list --versions ctrlspeak >/dev/null 2>&1; then
    CTRLSPEAK_LIBEXEC="$(brew --prefix ctrlspeak)/libexec"
  fi
fi

echo "This will remove:"
echo "  - the background service ($SERVICE_LABEL)"
echo "  - $APP_PATH"
[[ -n "$BREW_PREFIX" ]] && echo "  - $BREW_PREFIX/bin/ctrlspeak-overlay and ctrlspeak-local"
[[ -n "$CTRLSPEAK_LIBEXEC" ]] && echo "  - the patches in $CTRLSPEAK_LIBEXEC (originals restored)"
[[ "$REMOVE_MODEL" -eq 1 ]] && echo "  - the cached Whisper model (~1.6 GB)"
[[ "$KEEP_BREW" -eq 0 ]] && echo "  - the ctrlspeak Homebrew formula"
echo

if [[ "$ASSUME_YES" -eq 0 ]]; then
  read -r -p "Continue? [y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

echo "Stopping the background service..."
launchctl bootout "gui/$CURRENT_UID/$SERVICE_LABEL" 2>/dev/null || true
rm -f "$LAUNCH_AGENT_PATH"

echo "Removing the app bundle..."
rm -rf "$APP_PATH"

if [[ -n "$BREW_PREFIX" ]]; then
  echo "Removing the pill and the wrapper..."
  rm -f "$BREW_PREFIX/bin/ctrlspeak-overlay" "$BREW_PREFIX/bin/ctrlspeak-local"
fi

# Restore whatever install.sh replaced. Files with no backup were added by this
# project and are simply deleted.
if [[ -n "$CTRLSPEAK_LIBEXEC" && -d "$CTRLSPEAK_LIBEXEC" ]]; then
  echo "Restoring the original ctrlSPEAK files..."
  restored=0
  removed=0

  while IFS= read -r backup; do
    target="${backup%.local-voice-backup}"
    mv -f "$backup" "$target"
    restored=$((restored + 1))
  done < <(find "$CTRLSPEAK_LIBEXEC" -name "*.local-voice-backup" 2>/dev/null)

  # These two have no upstream counterpart, so there is no backup to restore
  # them from; everything else install.sh touched already came back above.
  for added in overlay.py model_download.py; do
    if [[ -f "$CTRLSPEAK_LIBEXEC/$added" ]]; then
      rm -f "$CTRLSPEAK_LIBEXEC/$added"
      removed=$((removed + 1))
    fi
  done

  rm -rf "$CTRLSPEAK_LIBEXEC/__pycache__" "$CTRLSPEAK_LIBEXEC/models/__pycache__" \
    "$CTRLSPEAK_LIBEXEC/utils/__pycache__" 2>/dev/null || true

  echo "  restored $restored file(s), removed $removed added file(s)"
fi

echo "Removing the language preference..."
rm -f "$HOME/.config/ctrlspeak/language" \
  "$HOME/.config/ctrlspeak/startup-pill.fifo" \
  "$HOME/.config/ctrlspeak/setup-status" \
  "$HOME/.config/ctrlspeak/permission-status"

echo "Removing ctrlSPEAK's privacy-pane entries..."
tccutil reset All "$SERVICE_LABEL" >/dev/null 2>&1 || true

if [[ "$REMOVE_MODEL" -eq 1 ]]; then
  MODEL_DIR="${HF_HOME:-$HOME/.cache/huggingface}/hub/$MODEL_REPO"
  if [[ -d "$MODEL_DIR" ]]; then
    echo "Removing the cached model..."
    rm -rf "$MODEL_DIR"
  fi
fi

if [[ "$KEEP_BREW" -eq 0 ]] && command -v brew >/dev/null 2>&1; then
  echo "Uninstalling the ctrlspeak formula..."
  brew uninstall ctrlspeak || true
  # Installed outside the keg by the formula, so it survives brew uninstall.
  rm -rf "$BREW_PREFIX/var/ctrlspeak"
fi

echo
echo "Uninstall complete."
echo
echo "Kept, in case you still want them:"
echo "  ~/Library/Logs/ctrlspeak.log, ~/Library/Logs/ctrlspeak.error.log"
[[ "$REMOVE_MODEL" -eq 0 ]] && echo "  The cached model was kept; pass --remove-model to delete it."
echo
