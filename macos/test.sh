#!/bin/sh
set -eu
DESKPILOT_PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$DESKPILOT_PROJECT/.build/test-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$DESKPILOT_PROJECT/.build/test-cache" "$DESKPILOT_PROJECT/Sources/Models.swift" "$DESKPILOT_PROJECT/Tests/CoreTests.swift" -o "$DESKPILOT_PROJECT/.build/core-tests"
"$DESKPILOT_PROJECT/.build/core-tests"
