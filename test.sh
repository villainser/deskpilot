#!/bin/sh
set -eu
DESKPILOT_PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$DESKPILOT_PROJECT/.build/test-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$DESKPILOT_PROJECT/.build/test-cache" "$DESKPILOT_PROJECT/Sources/Models.swift" "$DESKPILOT_PROJECT/Sources/AccessibilityPolicy.swift" "$DESKPILOT_PROJECT/Tests/CoreTests.swift" -o "$DESKPILOT_PROJECT/.build/core-tests"
"$DESKPILOT_PROJECT/.build/core-tests"
xcrun clang -fobjc-arc -O2 -mmacosx-version-min=14.0 -c "$DESKPILOT_PROJECT/Sources/NativeSupport.m" -o "$DESKPILOT_PROJECT/.build/test-native.o"
xcrun swiftc -swift-version 5 -module-cache-path "$DESKPILOT_PROJECT/.build/test-cache" \
  -import-objc-header "$DESKPILOT_PROJECT/Sources/NativeSupport.h" \
  "$DESKPILOT_PROJECT/Sources/Models.swift" "$DESKPILOT_PROJECT/Sources/AccessibilityPolicy.swift" "$DESKPILOT_PROJECT/Sources/SystemAccess.swift" \
  "$DESKPILOT_PROJECT/Sources/Engine.swift" "$DESKPILOT_PROJECT/Tests/EngineTests.swift" \
  "$DESKPILOT_PROJECT/.build/test-native.o" -framework Cocoa -framework ApplicationServices -framework ServiceManagement \
  -o "$DESKPILOT_PROJECT/.build/engine-tests"
"$DESKPILOT_PROJECT/.build/engine-tests"
