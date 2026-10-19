#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/MT760 Control.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MT760Control" "$APP/Contents/MacOS/MT760Control"
cp "$BIN_DIR/mt760-read-helper" "$APP/Contents/MacOS/mt760-read-helper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Override only the packaged copy; never change tracked metadata during a release.
if [[ -n "${RELEASE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
# Regenerate with: swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/mt760-diagnostics" dist/mt760-diagnostics
# Input Monitoring (TCC) pins the App's designated requirement. Ad-hoc signatures pin the
# cdhash, so every rebuild silently invalidates the grant. Prefer a stable local identity.
IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
fi
IDENTITY="${IDENTITY:--}"
[[ "$IDENTITY" == "-" ]] && echo "warning: ad-hoc signing; Input Monitoring must be re-granted after each rebuild" >&2
# Ad-hoc releases are not notarized and are subject to Gatekeeper checks.
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/mt760-read-helper"
codesign --force --sign "$IDENTITY" "$APP"
echo "Signed with: $IDENTITY"
echo "Built: $APP"
echo "Open: open \"$APP\""
