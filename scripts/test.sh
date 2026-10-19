#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Swift 6.4 CLT's build-system integration may omit the bundled Testing macro plugin.
# Resolve within the selected toolchain; do not install tools or change xcode-select.
SWIFT_BIN="$(dirname "$(xcrun --find swiftc)")"
PLUGIN="$SWIFT_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
ARGS=()
if [[ -f "$PLUGIN" ]]; then
    ARGS=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
fi
swift test --disable-xctest "${ARGS[@]}" "$@"
