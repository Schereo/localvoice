#!/bin/bash

set -euo pipefail

SERVICE_LABEL="com.localvoice.app"
CURRENT_UID="$(id -u)"
LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"

if [[ ! -f "$LAUNCH_AGENT_PATH" ]]; then
  echo "LaunchAgent not found. Run ./install.sh first." >&2
  exit 1
fi

launchctl bootout "gui/$CURRENT_UID/$SERVICE_LABEL" 2>/dev/null || true

# Also clear any service started outside launchd (a double-clicked app, an
# old manual launch): left alive, it would hold the single-instance lock and
# make the fresh launchd service exit at once.
pkill -f "libexec/ctrlspeak.py" 2>/dev/null || true
pkill -f "LocalVoice.app/Contents/MacOS/LocalVoice" 2>/dev/null || true

launchctl bootstrap "gui/$CURRENT_UID" "$LAUNCH_AGENT_PATH"

echo "LocalVoice restarted. The model may need a few seconds to become ready."
