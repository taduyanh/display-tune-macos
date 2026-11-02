#!/bin/zsh
# Build DisplayTune.app (menu bar app). Usage: ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"
APP=build/DisplayTune.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
# Target the build machine's architecture but macOS 14 as the minimum, so the result is not tied to the SDK version it was built with.
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -import-objc-header Bridge.h \
  -framework Cocoa -framework IOKit -framework ServiceManagement \
  Sources/*.swift -o "$APP/Contents/MacOS/DisplayTune"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"
# Sign with the stable local identity when it exists (tools/make_signing_cert.sh), otherwise ad-hoc.
# A stable identity keeps the Accessibility permission valid across rebuilds; an ad-hoc signature changes every build.
SIGN_NAME="DisplayTune Local Signing"
SIGN_KC="$HOME/Library/Keychains/displaytune-signing.keychain-db"
if [[ -f "$SIGN_KC" ]]; then
  security unlock-keychain -p displaytune "$SIGN_KC"
  codesign --force --sign "$SIGN_NAME" --keychain "$SIGN_KC" "$APP"
else
  echo "note: no signing identity found, signing ad-hoc (run tools/make_signing_cert.sh for a stable signature)"
  codesign --force --sign - "$APP"
fi
echo "Built: $PWD/$APP"
if [[ "${1:-}" == "install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/DisplayTune.app"
  cp -R "$APP" "$HOME/Applications/DisplayTune.app"
  echo "Installed: $HOME/Applications/DisplayTune.app"
fi
