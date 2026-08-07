#!/bin/bash

set -euo pipefail

SERVICE_LABEL="com.localvoice.ctrlspeak"
CURRENT_UID="$(id -u)"

check_file() {
  local path="$1"
  if [[ -e "$path" ]]; then
    echo "✓ $path"
  else
    echo "✗ Missing: $path"
    return 1
  fi
}

command -v brew >/dev/null 2>&1 || { echo "✗ Homebrew not found"; exit 1; }
BREW_PREFIX="$(brew --prefix)"
CTRLSPEAK_PREFIX="$(brew --prefix ctrlspeak)"

echo "Checking local dictation installation..."
check_file "$BREW_PREFIX/bin/ctrlspeak"
check_file "$BREW_PREFIX/bin/ctrlspeak-local"
check_file "$BREW_PREFIX/bin/ctrlspeak-overlay"
check_file "$BREW_PREFIX/var/ctrlspeak/venv/bin/python3.11"
check_file "$CTRLSPEAK_PREFIX/libexec/hotkeys.py"
check_file "$CTRLSPEAK_PREFIX/libexec/models/whisper_mlx.py"
check_file "$CTRLSPEAK_PREFIX/libexec/overlay.py"
check_file "$CTRLSPEAK_PREFIX/libexec/model_download.py"
check_file "$CTRLSPEAK_PREFIX/libexec/permissions.py"
check_file "$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"

APP_PATH="$HOME/Applications/ctrlSPEAK.app"
check_file "$APP_PATH/Contents/MacOS/ctrlSPEAK"
check_file "$APP_PATH/Contents/Resources/launch.conf"

# The signature is the identity macOS keys the permissions to; without it the
# permission panes fall back to showing whichever binary made the call.
if codesign --verify --strict "$APP_PATH" >/dev/null 2>&1; then
  echo "✓ App bundle signature is valid"
else
  echo "✗ App bundle signature is broken — re-run ./install.sh"
  exit 1
fi

# A LaunchAgent still pointing at the shell wrapper means permissions would be
# attributed to bash again, which is the problem the bundle exists to solve.
if grep -q "ctrlSPEAK.app/Contents/MacOS/ctrlSPEAK" "$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"; then
  echo "✓ Service launches through the app bundle"
else
  echo "✗ Service does not launch through the app bundle — re-run ./install.sh"
  exit 1
fi

if "$BREW_PREFIX/var/ctrlspeak/venv/bin/python3.11" -c "import mlx_whisper" >/dev/null 2>&1; then
  echo "✓ MLX Whisper runtime is installed"
else
  echo "✗ MLX Whisper runtime is missing"
  exit 1
fi

if launchctl print "gui/$CURRENT_UID/$SERVICE_LABEL" >/dev/null 2>&1; then
  echo "✓ Background service is loaded"
else
  echo "✗ Background service is not loaded"
  exit 1
fi

# Loaded but not running is the signature of a failed permission check: the
# process exits immediately and KeepAlive does not restart a clean exit.
if launchctl print "gui/$CURRENT_UID/$SERVICE_LABEL" 2>/dev/null | grep -qE "state = running"; then
  echo "✓ Background service is running"
else
  echo "! Background service is loaded but not running"
  echo "  Usually a missing permission. Check the last lines of:"
  echo "    ~/Library/Logs/ctrlspeak.log"
  echo "  Grant Microphone, Accessibility and Input Monitoring to:"
  echo "    $APP_PATH"
  echo "  then run ./scripts/restart.sh"
fi

echo
echo "All installation checks passed."
