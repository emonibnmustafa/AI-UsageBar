#!/bin/bash
set -e
PLIST_FILE="$HOME/Library/LaunchAgents/com.local.claudelimitbar.plist"
killall ClaudeLimitBar 2>/dev/null || true
launchctl unload "$PLIST_FILE" 2>/dev/null || true
rm -f "$PLIST_FILE"
rm -rf "$HOME/Applications/ClaudeLimitBar.app"
echo "🗑 ClaudeLimitBar uninstalled."
