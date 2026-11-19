#!/bin/bash
# Put a staged account app (from make-app.sh) in place of the old one.
# Usage: swap.sh "Claude Account 3" "Claude Account 2"   (app name, profile folder)
# Refuses while the app runs. Backs up the old app and the profile (APFS clone) first.
set -euo pipefail
NAME="$1"; PROFILE="$2"
APP="/Applications/$NAME.app"; NEW="/Applications/.$NAME.new.app"
P="$HOME/Library/Application Support/$PROFILE"
BK="$HOME/Library/Application Support/AccountAppBackups/$(date +%Y%m%d-%H%M%S) $NAME"
[ -d "$NEW" ] || { echo "No staged build at $NEW; run make-app.sh first." >&2; exit 1; }
if pgrep -af -- "--user-data-dir=$P\$" >/dev/null; then echo "Quit \"$NAME\" first (normal quit, not log out)." >&2; exit 1; fi
mkdir -p "$BK"
cp -cR "$P" "$BK/profile"
mv "$APP" "$BK/$NAME.app"
mv "$NEW" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
open "$APP"
echo "Done. Backup: $BK (restore: quit app, move $NAME.app and profile back)."
