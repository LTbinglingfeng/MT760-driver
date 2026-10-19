#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
if [[ ! "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo '用法 / Usage: ./scripts/package-release.sh v1.2.3[-rc.1]' >&2
    exit 1
fi
RELEASE_VERSION="${BASH_REMATCH[1]}"
ARCH="$(uname -m)"
if [[ "$ARCH" != arm64 ]]; then
    echo "发布包仅支持 Apple Silicon / Release packages require Apple Silicon: $ARCH" >&2
    exit 1
fi
BUILD_NUMBER="${BUILD_NUMBER:-1}"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo 'BUILD_NUMBER 必须是正整数 / BUILD_NUMBER must be a positive integer' >&2
    exit 1
fi

# Use a consistent, secret-free signing mode for CI and local release packaging.
RELEASE_VERSION="$RELEASE_VERSION" BUILD_NUMBER="$BUILD_NUMBER" CODE_SIGN_IDENTITY=- ./scripts/build-app.sh
APP="$PWD/dist/MT760 Control.app"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
# Verify the helper and diagnostic tool as well as the main executable.
for binary in "$APP/Contents/MacOS/MT760Control" "$APP/Contents/MacOS/mt760-read-helper" dist/mt760-diagnostics; do
    lipo "$binary" -verify_arch "$ARCH"
done

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$APP" "$STAGING/MT760 Control.app"
cp dist/mt760-diagnostics README.md README.en.md "$STAGING/"
ARCHIVE="$PWD/dist/MT760Control_${TAG#v}_macos_${ARCH}.zip"
rm -f "$ARCHIVE"
# ditto preserves the app bundle, executable bits and macOS metadata.
/usr/bin/ditto -c -k --sequesterRsrc "$STAGING" "$ARCHIVE"
echo "已打包 / Packaged: $ARCHIVE"
