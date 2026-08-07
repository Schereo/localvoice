#!/bin/bash

# Re-run the guided permission setup, then restart the service.
#
# Useful when the wizard was skipped during install, or when a macOS update
# or a re-signed bundle invalidated the grants.

set -euo pipefail

SERVICE_LABEL="com.localvoice.ctrlspeak"
CURRENT_UID="$(id -u)"
APP_PATH="$HOME/Applications/ctrlSPEAK.app"
SETUP_STATUS_FILE="$HOME/.config/ctrlspeak/setup-status"

[[ -d "$APP_PATH" ]] || {
  echo "ctrlSPEAK.app not found. Run ./install.sh first." >&2
  exit 1
}

# "open" passes --setup only to a fresh instance; a running service would just
# be activated instead, so stop it for the duration of the wizard.
launchctl bootout "gui/$CURRENT_UID/$SERVICE_LABEL" 2>/dev/null || true

rm -f "$SETUP_STATUS_FILE"
open -W "$APP_PATH" --args --setup || true

if [[ "$(cat "$SETUP_STATUS_FILE" 2>/dev/null)" == "granted" ]]; then
  echo "All permissions granted. Restarting the service..."
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restart.sh"
fi

echo "The permission setup did not finish. Grant Microphone, Accessibility and" >&2
echo "Input Monitoring to ctrlSPEAK under System Settings > Privacy & Security," >&2
echo "then run ./scripts/restart.sh" >&2
exit 1
