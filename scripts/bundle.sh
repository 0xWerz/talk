#!/usr/bin/env bash
# Builds Talk.app from the SwiftPM executable, bakes in the sidecar's paths and
# ad-hoc signs it so macOS will hand it microphone and accessibility access.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
SIDECAR_DIR="${SIDECAR_DIR:-$REPO_ROOT/sidecar}"
CONFIGURATION="${CONFIGURATION:-release}"
DEST="${DEST:-$REPO_ROOT/build}"
APP="$DEST/Talk.app"
VERSION="0.1.0"

PYTHON_BIN="$SIDECAR_DIR/.venv/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "error: sidecar venv missing. Run: cd sidecar && uv sync" >&2
  exit 1
fi

echo "==> Building Talk ($CONFIGURATION)"
swift build --package-path "$APP_DIR" -c "$CONFIGURATION"
BINARY="$(swift build --package-path "$APP_DIR" -c "$CONFIGURATION" --show-bin-path)/Talk"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Talk"

echo "==> Rendering icon"
ICONSET="$DEST/Talk.iconset"
rm -rf "$ICONSET"
swift "$REPO_ROOT/scripts/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Talk.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Talk</string>
  <key>CFBundleDisplayName</key><string>Talk</string>
  <key>CFBundleIdentifier</key><string>com.talk.dictation</string>
  <key>CFBundleExecutable</key><string>Talk</string>
  <key>CFBundleIconFile</key><string>Talk.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local, private dictation.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Talk listens to your microphone only while you hold the dictation key, and transcribes it on this Mac.</string>
  <key>TalkSidecarPython</key><string>$PYTHON_BIN</string>
  <key>TalkSidecarRoot</key><string>$SIDECAR_DIR</string>
</dict>
</plist>
PLIST

cat > "$DEST/Talk.entitlements" <<ENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENTS

# A stable identity keeps macOS's permission grants attached to the app across
# rebuilds; ad-hoc signing ties them to the binary's hash and breaks them every
# single time. See scripts/make_signing_identity.sh.
IDENTITY="${TALK_SIGN_IDENTITY:-Talk Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "==> Signing as '$IDENTITY'"
  SIGN_AS="$IDENTITY"
else
  echo "==> Signing ad-hoc — run ./scripts/make_signing_identity.sh to stop"
  echo "    macOS permissions resetting on every rebuild"
  SIGN_AS="-"
fi

codesign --force --sign "$SIGN_AS" \
  --identifier com.talk.dictation \
  --entitlements "$DEST/Talk.entitlements" \
  "$APP" >/dev/null

echo
echo "Built $APP"
echo
echo "Next:"
echo "  open $APP"
echo "  Grant Microphone, Accessibility and Input Monitoring when asked."
echo "  System Settings > Keyboard > 'Press globe key to' -> Do Nothing."
