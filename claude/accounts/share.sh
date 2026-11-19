#!/bin/bash
# Move Code-tab chats that an account app saved in its own profile into the shared
# folder (the main app's), and remove the old symlinks from earlier versions.
# Account apps built by make-app.sh already save new chats in the shared folder.
# Run with that app quit. Safe to re-run. Never touches Cookies, config.json or sign-in data.
set -euo pipefail
AS="$HOME/Library/Application Support"
CONFIG="$HOME/.config/ailimitbar/accounts.json"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES=()
while IFS= read -r p; do PROFILES+=("$p"); done < <(jq -r '.accounts[] | select(.type == "claude") | .profile // "Claude" | select(. != "Claude")' "$CONFIG")
[ ${#PROFILES[@]} -gt 0 ] || { echo "No extra Claude profiles in $CONFIG; nothing to share."; exit 0; }
CANON=$("$DIR/shared-folder.sh")
echo "Shared chat folder: $CANON"

for prof in "${PROFILES[@]}"; do
    P="$AS/$prof"
    for link in "$P"/claude-code-sessions/*/*; do
        [ -e "$link" ] || [ -L "$link" ] || continue
        # Claude 5.11+ refuses symlinked chat folders; the patched app writes to the shared folder itself.
        [ -L "$link" ] && { rm "$link"; echo "$prof: removed old symlink $(basename "$link")."; continue; }
        [ -d "$link" ] || continue
        if pgrep -af -- "--user-data-dir=$P\$" >/dev/null; then
            echo "$prof: still running, skipped; quit it and re-run." >&2; continue
        fi
        for f in "$link"/* "$link"/.[!.]*; do
            [ -f "$f" ] || continue
            dest="$CANON/$(basename "$f")"
            # The newer copy of a chat record wins; an older or identical copy is dropped.
            if [ ! -e "$dest" ] || [ "$f" -nt "$dest" ]; then mv -f "$f" "$dest"; else rm "$f"; fi
        done
        find "$link" -mindepth 1 -type d -empty -delete
        rmdir "$link" 2>/dev/null && echo "$prof: chats moved to the shared folder." \
            || echo "$prof: $link has subfolders, left as is."
    done
done
