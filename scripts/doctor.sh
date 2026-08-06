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
check_file "$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"

if launchctl print "gui/$CURRENT_UID/$SERVICE_LABEL" >/dev/null 2>&1; then
  echo "✓ Background service is loaded"
else
  echo "✗ Background service is not loaded"
  exit 1
fi

echo
echo "All installation checks passed."
