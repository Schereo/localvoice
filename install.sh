#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_LABEL="com.localvoice.ctrlspeak"
SOURCE_LANGUAGE="${CTRLSPEAK_LANGUAGE:-de}"
SUPPORTED_CTRLSPEAK_VERSION="1.8.0"

fail() {
  echo "Error: $*" >&2
  exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "This installer only supports macOS."
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  fail "Apple Silicon is required."
fi

if [[ "$SOURCE_LANGUAGE" != "de" && "$SOURCE_LANGUAGE" != "en" ]]; then
  fail "CTRLSPEAK_LANGUAGE must be 'de' or 'en'."
fi

command -v brew >/dev/null 2>&1 || fail "Homebrew is missing. Install it from https://brew.sh and run this script again."
command -v xcrun >/dev/null 2>&1 || fail "Xcode Command Line Tools are missing. Run: xcode-select --install"

BREW_PREFIX="$(brew --prefix)"
CURRENT_UID="$(id -u)"
PATCH_DIR="$PROJECT_DIR/patches/ctrlspeak-$SUPPORTED_CTRLSPEAK_VERSION"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ctrlspeak-local.XXXXXX")"

cleanup() {
  rm -rf -- "$BUILD_DIR"
}
trap cleanup EXIT

echo "Installing ctrlSPEAK and its local MLX dependencies..."
brew tap patelnav/ctrlspeak
brew install ctrlspeak ffmpeg

INSTALLED_VERSION="$(brew list --versions ctrlspeak | awk 'NR == 1 { print $2 }')"
if [[ "$INSTALLED_VERSION" != "$SUPPORTED_CTRLSPEAK_VERSION" ]]; then
  fail "This patch set supports ctrlSPEAK $SUPPORTED_CTRLSPEAK_VERSION, but Homebrew installed $INSTALLED_VERSION."
fi

CTRLSPEAK_PREFIX="$(brew --prefix ctrlspeak)"
CTRLSPEAK_LIBEXEC="$CTRLSPEAK_PREFIX/libexec"
CTRLSPEAK_PYTHON="$BREW_PREFIX/var/ctrlspeak/venv/bin/python3.11"

[[ -x "$CTRLSPEAK_PYTHON" ]] || fail "ctrlSPEAK's Python environment was not created correctly."
[[ -d "$PATCH_DIR" ]] || fail "Patch directory not found: $PATCH_DIR"

echo "Installing the verified MLX Whisper runtime..."
"$CTRLSPEAK_PYTHON" -m pip install "mlx-whisper==0.4.3"

echo "Building the native recording pill..."
xcrun swiftc \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR/src/ctrlspeak-overlay.swift" \
  -o "$BUILD_DIR/ctrlspeak-overlay"

install -m 755 "$BUILD_DIR/ctrlspeak-overlay" "$BREW_PREFIX/bin/ctrlspeak-overlay"

backup_and_install() {
  local source_file="$1"
  local target_file="$2"
  local mode="$3"
  local backup_file="$target_file.local-voice-backup"

  if [[ -e "$target_file" && ! -e "$backup_file" ]]; then
    cp -p "$target_file" "$backup_file"
  fi

  install -m "$mode" "$source_file" "$target_file"
}

echo "Applying the verified ctrlSPEAK 1.8.0 compatibility patches..."
backup_and_install "$PATCH_DIR/hotkeys.py" "$CTRLSPEAK_LIBEXEC/hotkeys.py" 644
backup_and_install "$PATCH_DIR/model_loader.py" "$CTRLSPEAK_LIBEXEC/model_loader.py" 644
backup_and_install "$PATCH_DIR/transcription.py" "$CTRLSPEAK_LIBEXEC/transcription.py" 644
backup_and_install "$PATCH_DIR/ctrlspeak.py" "$CTRLSPEAK_LIBEXEC/ctrlspeak.py" 644
backup_and_install "$PATCH_DIR/state.py" "$CTRLSPEAK_LIBEXEC/state.py" 644
backup_and_install "$PATCH_DIR/models/factory.py" "$CTRLSPEAK_LIBEXEC/models/factory.py" 644
backup_and_install "$PATCH_DIR/models/registry.py" "$CTRLSPEAK_LIBEXEC/models/registry.py" 644
backup_and_install "$PATCH_DIR/models/whisper_mlx.py" "$CTRLSPEAK_LIBEXEC/models/whisper_mlx.py" 644
backup_and_install "$PATCH_DIR/utils/clipboard.py" "$CTRLSPEAK_LIBEXEC/utils/clipboard.py" 644

"$CTRLSPEAK_PYTHON" -m py_compile \
  "$CTRLSPEAK_LIBEXEC/hotkeys.py" \
  "$CTRLSPEAK_LIBEXEC/model_loader.py" \
  "$CTRLSPEAK_LIBEXEC/transcription.py" \
  "$CTRLSPEAK_LIBEXEC/ctrlspeak.py" \
  "$CTRLSPEAK_LIBEXEC/state.py" \
  "$CTRLSPEAK_LIBEXEC/models/factory.py" \
  "$CTRLSPEAK_LIBEXEC/models/registry.py" \
  "$CTRLSPEAK_LIBEXEC/models/whisper_mlx.py" \
  "$CTRLSPEAK_LIBEXEC/utils/clipboard.py"

WRAPPER_PATH="$BREW_PREFIX/bin/ctrlspeak-local"
cat > "$BUILD_DIR/ctrlspeak-local" <<EOF
#!/bin/bash

export PATH="$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CTRLSPEAK_OVERLAY_PATH="$BREW_PREFIX/bin/ctrlspeak-overlay"

LANGUAGE_FILE="\$HOME/.config/ctrlspeak/language"
LANGUAGE="$SOURCE_LANGUAGE"

if [[ -f "\$LANGUAGE_FILE" ]]; then
  read -r SAVED_LANGUAGE < "\$LANGUAGE_FILE"
  if [[ "\$SAVED_LANGUAGE" == "de" || "\$SAVED_LANGUAGE" == "en" ]]; then
    LANGUAGE="\$SAVED_LANGUAGE"
  fi
fi

exec "$BREW_PREFIX/bin/ctrlspeak" \\
  --model whisper-mlx \\
  --source-lang "\$LANGUAGE" \\
  --target-lang "\$LANGUAGE" \\
  "\$@"
EOF
install -m 755 "$BUILD_DIR/ctrlspeak-local" "$WRAPPER_PATH"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/$SERVICE_LABEL.plist"

cat > "$BUILD_DIR/$SERVICE_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SERVICE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$WRAPPER_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>TERM</key>
    <string>xterm-256color</string>
    <key>CTRLSPEAK_OVERLAY_PATH</key>
    <string>$BREW_PREFIX/bin/ctrlspeak-overlay</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/ctrlspeak.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/ctrlspeak.error.log</string>
</dict>
</plist>
EOF

plutil -lint "$BUILD_DIR/$SERVICE_LABEL.plist" >/dev/null
install -m 644 "$BUILD_DIR/$SERVICE_LABEL.plist" "$LAUNCH_AGENT_PATH"

launchctl bootout "gui/$CURRENT_UID/$SERVICE_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$CURRENT_UID" "$LAUNCH_AGENT_PATH"

echo
echo "Installation complete."
echo
echo "Required macOS permissions:"
echo "  System Settings > Privacy & Security > Microphone"
echo "  System Settings > Privacy & Security > Accessibility"
echo "  System Settings > Privacy & Security > Input Monitoring"
echo
echo "Add this executable to all three sections:"
echo "  $CTRLSPEAK_PYTHON"
echo
echo "In the file picker, press Command-Shift-G and paste the path above."
echo "Then run: $PROJECT_DIR/scripts/restart.sh"
echo
echo "Usage: triple-tap Control to start, then triple-tap Control to stop."
echo "Toggle German/English with Control-Option-L."
echo "The local Whisper Large V3 Turbo MLX model downloads on first launch."
