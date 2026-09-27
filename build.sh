#!/bin/bash
# Builds Murmur.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Murmur.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Murmur"

cp Info.plist "$APP/Contents/Info.plist"
cp whisper/murmur_whisper.py "$APP/Contents/Resources/"

# Sign the installed copy (Desktop folders can carry Finder metadata that codesign rejects).
mkdir -p ~/Applications
pkill -x Murmur 2>/dev/null || true
rm -rf ~/Applications/Murmur.app
ditto --norsrc --noextattr "$APP" ~/Applications/Murmur.app
xattr -cr ~/Applications/Murmur.app
# A stable identity keeps macOS permissions (Accessibility etc.) across rebuilds.
IDENTITY="Murmur Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier com.local.murmur ~/Applications/Murmur.app
else
  echo "warning: '$IDENTITY' not found; ad-hoc signing (permissions reset on every rebuild)"
  codesign --force --sign - --identifier com.local.murmur ~/Applications/Murmur.app
fi
echo "Installed ~/Applications/Murmur.app"
