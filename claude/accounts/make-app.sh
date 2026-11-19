#!/bin/bash
# Make a separate Claude app for another account: copy of Claude.app, own bundle ID, own profile folder.
# Usage: make-app.sh "Claude Account 2" com.local.claude.account2 "Claude Account 2"
# Never replaces a running app: if the app exists, the new build is staged for swap.sh.
set -euo pipefail
NAME="$1"; BUNDLE_ID="$2"; PROFILE="$3"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="/Applications/$NAME.app"
TMP="/Applications/.$NAME.building.app"
FINAL="$APP"
# App exists: build next to it; swap.sh puts it in place once that app is quit.
[ -e "$APP" ] && FINAL="/Applications/.$NAME.new.app" && rm -rf "${FINAL:?}"
rm -rf "${TMP:?}"
cp -cR /Applications/Claude.app "$TMP"
mv "$TMP/Contents/MacOS/Claude" "$TMP/Contents/MacOS/Claude.real"
clang -O2 -Wall -Wextra -DPROFILE="\"$PROFILE\"" "$DIR/launcher.c" -o "$TMP/Contents/MacOS/$NAME"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleExecutable $NAME" "$TMP/Contents/Info.plist"
$PB -c "Set :CFBundleIdentifier $BUNDLE_ID" "$TMP/Contents/Info.plist"
$PB -c "Set :CFBundleDisplayName $NAME" "$TMP/Contents/Info.plist" 2>/dev/null \
  || $PB -c "Add :CFBundleDisplayName string $NAME" "$TMP/Contents/Info.plist"
# CFBundleName stays "Claude": Electron finds "Claude Helper.app" by it.
# Use main's scratch-workspaces and Code-tab chat folder so every app shows the same chats.
python3 "$DIR/patch_asar.py" "$TMP" "$("$DIR/shared-folder.sh")"
codesign --force --deep --sign - "$TMP" >/dev/null 2>&1
codesign --verify --deep --strict "$TMP"
mv "$TMP" "$FINAL"
if [ "$FINAL" != "$APP" ]; then echo "Staged $FINAL. Quit \"$NAME\", then run: swap.sh \"$NAME\" \"$PROFILE\""; exit 0; fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

# Same shared working folder as the main app (no sign-in data copied).
P="$HOME/Library/Application Support/$PROFILE"
mkdir -p "$P"
[ -f "$P/claude_desktop_config.json" ] || cp "$HOME/Library/Application Support/Claude/claude_desktop_config.json" "$P/"
echo "Made $APP (profile: $P). Open it, sign in and quit it."
