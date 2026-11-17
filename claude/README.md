# ClaudeLimitBar (the AILimitBar app)

Native macOS menu bar app: one panel for several Claude accounts, Codex and Antigravity (Gemini).

## Menu bar

A coloured pill with the selected account's tag, then a ring gauge, percentage left and reset time for the 5-hour limit, and the same for the weekly limit (reset weekday). Rings turn orange under 25% and red under 10%. A faded item means the reading is old; `!` means no reading is available.

## Panel

Click the bar to open the AI Usage panel. Claude accounts come first, then (after a thin divider) Codex and Antigravity, each in its own colour, with plan, 5-hour and weekly bars and reset times. Click a card to show that account in the menu bar; the choice is remembered. The open button on a card opens that account's app. Drag the panel off the menu bar to keep it as a floating window anywhere on screen; click the bar or the window's close button to close it.

## Accounts

Accounts come from `~/.config/ailimitbar/accounts.json` (see `../accounts.example.json`; fields are described in `../.claude/skills/install-ailimitbar/SKILL.md`). Without that file the bar shows the main Claude app, plus Codex and Antigravity when they are installed.

## Refresh

The account in the menu bar is checked about every 30 seconds. The others are checked each time the panel opens. After an error (for example HTTP 429) an account waits 1 minute, doubling up to 30 minutes. The last reading and plan are kept across restarts. No account names or emails are shown or stored.

## Where the numbers come from

- **Claude**: the Claude desktop app's encrypted OAuth cache in the account's profile folder, decrypted with the existing "Claude Safe Storage" keychain key. The token stays in memory and is sent only to `https://api.anthropic.com/api/oauth/usage` (and once to `/api/oauth/profile` for the plan).
- **Codex**: `~/.codex/auth.json`, sent only to `https://chatgpt.com/backend-api/wham/usage`.
- **Antigravity**: its own local language server (`RetrieveUserQuotaSummary` on 127.0.0.1; port and CSRF token found with `ps`/`lsof`). Only the Gemini group is shown. Antigravity must be running; otherwise the last reading stays.

These are internal interfaces and may change with app updates.

## Account apps (`accounts/`)

Each extra Claude account runs in a copy of `Claude.app` with its own bundle ID and profile folder, so each keeps its own sign-in. `Claude.app` itself is never modified.

- `make-app.sh "<App Name>" <bundle id> "<Profile Folder>"` makes an account app. If the app already exists it only stages `/Applications/.<App Name>.new.app`.
- `swap.sh "<App Name>" "<Profile Folder>"` puts a staged build in place while the app is quit, after backing up the old app and profile to `~/Library/Application Support/AccountAppBackups/`.
- `patch_asar.py` (run by `make-app.sh`) makes the copy use the main app's `scratch-workspaces`, so "No folder" chats match in every app.
- `share.sh` links each extra profile's Code-tab chat folder to the main app's. Run it after signing in to a new app, with that app quit.

## Build

`scripts/install.sh` builds, runs `--self-test`, installs to `~/Applications/ClaudeLimitBar.app` and adds a LaunchAgent (`~/Library/LaunchAgents/com.local.claudelimitbar.plist`) to start at login. `scripts/uninstall.sh` removes it. `--check` queries every account once (live); `--render out.png` draws the menu bar art without network access.
