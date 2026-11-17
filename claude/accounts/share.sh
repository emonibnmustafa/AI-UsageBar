#!/bin/bash
# Share Code-tab chats of the main Claude app with every account app.
# Each profile's claude-code-sessions/<account>/<org> becomes a symlink to the main folder.
# Run after signing in to an account app (quit that app first). Safe to re-run.
# Never touches Cookies, config.json or any sign-in data.
set -euo pipefail
AS="$HOME/Library/Application Support"
CONFIG="$HOME/.config/ailimitbar/accounts.json"
# Every extra Claude profile listed in the config (the main "Claude" profile is the shared source).
PROFILES=()
while IFS= read -r p; do PROFILES+=("$p"); done < <(jq -r '.accounts[] | select(.type == "claude") | .profile // "Claude" | select(. != "Claude")' "$CONFIG")
[ ${#PROFILES[@]} -gt 0 ] || { echo "No extra Claude profiles in $CONFIG; nothing to share."; exit 0; }

MAIN_ACCT=$(jq -r .lastKnownAccountUuid "$AS/Claude/config.json")
# Canonical folder: the main account's real (non-symlink) org folder with the most chats.
CANON=""; best=-1
for d in "$AS/Claude/claude-code-sessions/$MAIN_ACCT"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    n=$(ls "$d" | wc -l)
    [ "$n" -gt "$best" ] && { best=$n; CANON=$d; }
done
[ -n "$CANON" ] || { echo "No main chat folder found." >&2; exit 1; }
echo "Shared chat folder: $CANON"

for prof in "${PROFILES[@]}"; do
    P="$AS/$prof"
    acct=$(jq -r '.lastKnownAccountUuid // empty' "$P/config.json" 2>/dev/null || true)
    [ -n "$acct" ] || { echo "$prof: not signed in yet, skipped."; continue; }
    orgs=$( { ls "$P/claude-code-sessions/$acct" 2>/dev/null || true
              jq -r 'keys[] | select(startswith("dxt:allowlistEnabled:")) | ltrimstr("dxt:allowlistEnabled:")' "$P/config.json"; } | sort -u)
    for org in $orgs; do
        link="$P/claude-code-sessions/$acct/$org"
        [ -L "$link" ] && { echo "$prof: $org already shared."; continue; }
        if [ -d "$link" ]; then
            if pgrep -f -- "--user-data-dir=$P\$" >/dev/null; then
                echo "$prof: quit that app first, then re-run." >&2; exit 1
            fi
            # Keep this account's own chats: move them into the shared folder (no overwrite).
            for f in "$link"/* "$link"/.[!.]*; do
                [ -e "$f" ] || continue
                mv -n "$f" "$CANON/"
                # Same file already shared (e.g. empty scheduled-tasks.json): drop the duplicate.
                [ -f "$f" ] && cmp -s "$f" "$CANON/$(basename "$f")" && rm "$f"
            done
            rmdir "$link" || { echo "$prof: $link not empty, left as is." >&2; continue; }
        fi
        mkdir -p "$(dirname "$link")"
        ln -s "$CANON" "$link"
        echo "$prof: $org now shared."
    done
done
