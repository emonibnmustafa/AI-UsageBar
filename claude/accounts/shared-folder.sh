#!/bin/bash
# Print the shared Code-tab chat folder: the main Claude app's real
# claude-code-sessions/<account>/<org> folder with the most chats.
set -euo pipefail
AS="$HOME/Library/Application Support"
acct=$(jq -r '.lastKnownAccountUuid // empty' "$AS/Claude/config.json")
[ -n "$acct" ] || { echo "Main Claude app is not signed in." >&2; exit 1; }
best=-1; canon=""
for d in "$AS/Claude/claude-code-sessions/$acct"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    n=$(ls "$d" | wc -l)
    [ "$n" -gt "$best" ] && { best=$n; canon=$d; }
done
[ -n "$canon" ] || { echo "No main chat folder found; open a Code-tab chat in Claude first." >&2; exit 1; }
echo "$canon"
