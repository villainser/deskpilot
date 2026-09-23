#!/bin/sh
set -eu
DESKPILOT_NATIVE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$DESKPILOT_NATIVE_DIR/bin"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
  -framework Cocoa "$DESKPILOT_NATIVE_DIR/space_move.m" \
  -o "$DESKPILOT_NATIVE_DIR/bin/deskpilot-space-move"
printf '%s\n' "$DESKPILOT_NATIVE_DIR/bin/deskpilot-space-move"
