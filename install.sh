#!/usr/bin/env bash
set -euo pipefail
umask 077
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${DESKPILOT_TARGET_DIR:-$HOME/.hammerspoon}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP_DIR="$TARGET_DIR/backups/deskpilot-$STAMP"
mkdir -p "$BACKUP_DIR"
chmod 700 "$TARGET_DIR" "$TARGET_DIR/backups" "$BACKUP_DIR"
for name in init.lua deskpilot.lua deskpilot_manager.lua deskpilot_follow.lua deskpilot_layout.lua deskpilot_session.lua deskpilot_session_adapter.lua deskpilot_display_policy.lua deskpilot_births.lua deskpilot_wire.lua deskpilot_policy.lua deskpilot_chrome.lua deskpilot_chrome_profiles.lua deskpilot_panel.lua deskpilot_panel_model.lua deskpilot_panel_guard.lua deskpilot_previews.lua deskpilot_panel.html deskpilot-move; do
  if [[ -e "$TARGET_DIR/$name" || -L "$TARGET_DIR/$name" ]]; then
    cp -p "$TARGET_DIR/$name" "$BACKUP_DIR/$name"
    if [[ "$name" == deskpilot-move ]]; then
      chmod 700 "$BACKUP_DIR/$name"
    else
      chmod 600 "$BACKUP_DIR/$name"
    fi
  fi
done
/usr/bin/defaults export org.hammerspoon.Hammerspoon "$BACKUP_DIR/settings.plist" 2>/dev/null || true
for name in init.lua deskpilot.lua deskpilot_manager.lua deskpilot_follow.lua deskpilot_layout.lua deskpilot_session.lua deskpilot_session_adapter.lua deskpilot_display_policy.lua deskpilot_births.lua deskpilot_wire.lua deskpilot_policy.lua deskpilot_chrome.lua deskpilot_chrome_profiles.lua deskpilot_panel.lua deskpilot_panel_model.lua deskpilot_panel_guard.lua deskpilot_previews.lua deskpilot_panel.html; do
  cp "$SOURCE_DIR/$name" "$TARGET_DIR/$name"
  chmod 600 "$TARGET_DIR/$name"
done
if [[ -x "$SOURCE_DIR/native/bin/deskpilot-space-move" ]]; then
  cp "$SOURCE_DIR/native/bin/deskpilot-space-move" "$TARGET_DIR/deskpilot-move"
  chmod 700 "$TARGET_DIR/deskpilot-move"
fi
echo "DeskPilot installed in $TARGET_DIR"
echo "Backup: $BACKUP_DIR"
echo "First v2 start is paused. Use DeskPilot > Wznow automatyke after diagnostics."
