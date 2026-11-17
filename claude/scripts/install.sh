#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClaudeLimitBar"
BUNDLE="$DIR/build/$APP_NAME.app"
DEST_APP="$HOME/Applications/$APP_NAME.app"
PLIST_FILE="$HOME/Library/LaunchAgents/com.local.claudelimitbar.plist"

echo "🔨 Building $APP_NAME..."
rm -rf "$DIR/build"
mkdir -p "$BUNDLE/Contents/MacOS"
swiftc -O -target "$(uname -m)-apple-macos12.0" "$DIR/main.swift" -framework Cocoa -o "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$DIR/Info.plist" "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1
"$BUNDLE/Contents/MacOS/$APP_NAME" --self-test

echo "🚀 Installing to $DEST_APP..."
killall "$APP_NAME" 2>/dev/null || true
sleep 0.5
mkdir -p "$HOME/Applications"
rm -rf "$DEST_APP"
cp -R "$BUNDLE" "$DEST_APP"

mkdir -p "$(dirname "$PLIST_FILE")"
cat << PLIST > "$PLIST_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.local.claudelimitbar</string>
<key>ProgramArguments</key><array><string>$DEST_APP/Contents/MacOS/$APP_NAME</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><false/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST

open -a "$DEST_APP"
echo "🎉 $APP_NAME installed. Click it in the menu bar to open the AI Usage panel."
