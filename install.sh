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

if [[ "$SOURCE_LANGUAGE" != "de" && "$SOURCE_LANGUAGE" != "en" && "$SOURCE_LANGUAGE" != "auto" ]]; then
  fail "CTRLSPEAK_LANGUAGE must be 'de', 'en' or 'auto'."
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

# Recent Homebrew refuses to load a formula from a third-party tap until it has
# been trusted once. Left to itself that surfaces as a bare Homebrew error in
# the middle of the install, so translate it into the actual next step.
BREW_LOG="$BUILD_DIR/brew-install.log"
if ! brew install ctrlspeak ffmpeg 2>&1 | tee "$BREW_LOG"; then
  if grep -q "untrusted tap" "$BREW_LOG"; then
    cat >&2 <<'TRUST'

Homebrew will not load formulae from a third-party tap until you trust it once.

The formula builds ctrlSPEAK from its upstream repository
(https://github.com/patelnav/ctrlspeak) with a pinned checksum. Review it if you
like:

  brew cat patelnav/ctrlspeak/ctrlspeak

Then trust it and run this installer again:

  brew trust --formula patelnav/ctrlspeak/ctrlspeak
  ./install.sh

TRUST
    exit 1
  fi

  fail "Homebrew could not install ctrlSPEAK and FFmpeg. See the output above."
fi

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
backup_and_install "$PATCH_DIR/overlay.py" "$CTRLSPEAK_LIBEXEC/overlay.py" 644
backup_and_install "$PATCH_DIR/model_download.py" "$CTRLSPEAK_LIBEXEC/model_download.py" 644
backup_and_install "$PATCH_DIR/permissions.py" "$CTRLSPEAK_LIBEXEC/permissions.py" 644
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
  "$CTRLSPEAK_LIBEXEC/overlay.py" \
  "$CTRLSPEAK_LIBEXEC/model_download.py" \
  "$CTRLSPEAK_LIBEXEC/permissions.py" \
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
  if [[ "\$SAVED_LANGUAGE" == "de" || "\$SAVED_LANGUAGE" == "en" || "\$SAVED_LANGUAGE" == "auto" ]]; then
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

# macOS keys TCC permissions to the responsible process — the root of the
# process tree. Without this bundle that root is /bin/bash, which is why the
# permissions used to be granted to bash or to the Homebrew Python symlink:
# a versioned Cellar path that Input Monitoring refuses and that breaks on
# every Python upgrade. A real app bundle gives the tree one stable identity
# named "ctrlSPEAK".
echo "Building the ctrlSPEAK app bundle..."
xcrun swiftc \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR/src/ctrlspeak-launcher.swift" \
  -o "$BUILD_DIR/ctrlSPEAK-launcher"

xcrun swiftc \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR/src/ctrlspeak-icon.swift" \
  -o "$BUILD_DIR/ctrlspeak-icon"

mkdir -p "$BUILD_DIR/ctrlSPEAK.iconset"
"$BUILD_DIR/ctrlspeak-icon" "$BUILD_DIR/ctrlSPEAK.iconset"
iconutil -c icns "$BUILD_DIR/ctrlSPEAK.iconset" -o "$BUILD_DIR/ctrlSPEAK.icns"

APP_STAGE="$BUILD_DIR/ctrlSPEAK.app"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources"
install -m 755 "$BUILD_DIR/ctrlSPEAK-launcher" "$APP_STAGE/Contents/MacOS/ctrlSPEAK"
install -m 644 "$BUILD_DIR/ctrlSPEAK.icns" "$APP_STAGE/Contents/Resources/ctrlSPEAK.icns"

cat > "$APP_STAGE/Contents/Resources/launch.conf" <<EOF
command=$WRAPPER_PATH
overlay=$BREW_PREFIX/bin/ctrlspeak-overlay
path=$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin
EOF

cat > "$APP_STAGE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>ctrlSPEAK</string>
  <key>CFBundleDisplayName</key>
  <string>ctrlSPEAK</string>
  <key>CFBundleIdentifier</key>
  <string>$SERVICE_LABEL</string>
  <key>CFBundleExecutable</key>
  <string>ctrlSPEAK</string>
  <key>CFBundleIconFile</key>
  <string>ctrlSPEAK</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$SUPPORTED_CTRLSPEAK_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$SUPPORTED_CTRLSPEAK_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>ctrlSPEAK records audio so it can transcribe your speech locally on this Mac.</string>
</dict>
</plist>
EOF

plutil -lint "$APP_STAGE/Contents/Info.plist" >/dev/null

# The signature is what TCC keys the permissions to. A Developer ID identity
# is preferred when one is in the keychain: permissions then attach to the
# team + bundle ID and survive any rebuild of the launcher. Ad-hoc signing is
# the fallback and only stays stable while the binaries do.
SIGN_IDENTITY="${CTRLSPEAK_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
    awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  # Hardened runtime plus the audio-input entitlement, so the signed tree may
  # keep recording; both are also what notarization would later require.
  cat > "$BUILD_DIR/entitlements.plist" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
</dict>
</plist>
ENTITLEMENTS

  echo "Signing with: $SIGN_IDENTITY"
  echo "(macOS may ask for keychain access; choose \"Always Allow\".)"
  codesign --force --options runtime \
    --entitlements "$BUILD_DIR/entitlements.plist" \
    --sign "$SIGN_IDENTITY" "$APP_STAGE" ||
    fail "Could not sign with '$SIGN_IDENTITY'. Unlock the login keychain and try again."
else
  codesign --force --sign - "$APP_STAGE" >/dev/null 2>&1 ||
    fail "Could not sign the app bundle. Check that Xcode Command Line Tools are installed."
fi

APP_PATH="$HOME/Applications/ctrlSPEAK.app"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Stop the service before replacing the bundle it is running from.
launchctl bootout "gui/$CURRENT_UID/$SERVICE_LABEL" 2>/dev/null || true

rm -rf "$APP_PATH"
ditto "$APP_STAGE" "$APP_PATH"

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
    <string>$APP_PATH/Contents/MacOS/ctrlSPEAK</string>
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

# Guided permission setup. The app requests all three permissions itself, so
# macOS pre-lists it in the privacy panes: the user confirms a dialog or flips
# a switch, instead of digging a hidden unix path out of a file picker. It has
# to run through LaunchServices ("open") — started from this shell directly,
# macOS would attribute the requests to the terminal instead of the app.
SETUP_STATUS_FILE="$HOME/.config/ctrlspeak/setup-status"
rm -f "$SETUP_STATUS_FILE"

# Under ad-hoc signing, a rebuild changes the launcher's identity, so
# privacy-pane rows from an earlier build no longer match it. Left in place,
# they are a trap: the pane shows a "ctrlSPEAK" row, the user flips it, and
# nothing happens because the grant belongs to the old binary. Reset our own
# rows so the wizard's prompts create fresh, matching ones. With a Developer
# ID identity the rows survive rebuilds by design — keep them.
if [[ -z "$SIGN_IDENTITY" ]]; then
  tccutil reset All "$SERVICE_LABEL" >/dev/null 2>&1 || true
fi

echo
echo "Opening the guided permission setup..."
echo "macOS will now ask for Microphone, Accessibility and Input Monitoring."
echo "Approve each dialog; for Accessibility and Input Monitoring, flip the"
echo "\"ctrlSPEAK\" switch System Settings shows you. The recording pill at the"
echo "bottom of the screen tracks what is still missing."
echo

open -W "$APP_PATH" --args --setup || true

if [[ "$(cat "$SETUP_STATUS_FILE" 2>/dev/null)" == "granted" ]]; then
  launchctl bootout "gui/$CURRENT_UID/$SERVICE_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$CURRENT_UID" "$LAUNCH_AGENT_PATH"

  echo "Installation complete — all permissions granted, service started."
  echo
  echo "On this first launch the 1.6-GB Whisper model is downloaded; the pill"
  echo "shows the progress. After that everything runs offline."
  echo
  echo "Usage: triple-tap Control to start, then triple-tap Control to stop."
  echo "Click the badge in the recording pill to cycle German / English / Auto."
else
  echo "The permission setup did not finish. Grant these to ctrlSPEAK under"
  echo "System Settings > Privacy & Security (the app is already listed in"
  echo "each pane; add it with + and pick $APP_PATH if it is not):"
  echo "  - Microphone"
  echo "  - Accessibility"
  echo "  - Input Monitoring"
  echo
  echo "Then run: $PROJECT_DIR/scripts/restart.sh"
fi

echo
echo "If entries for python3.11 or bash are left over from an earlier install,"
echo "you can remove them from those lists; they are no longer used."
