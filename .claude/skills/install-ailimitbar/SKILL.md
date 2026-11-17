---
name: install-ailimitbar
description: Install AILimitBar on the user's Mac from this repository, set up for their own Claude, Codex and Antigravity accounts. Use when the user shares this repo and asks to install or set it up, or asks to add or remove an account.
---

# Install AILimitBar

AILimitBar is a macOS menu bar app. It shows the 5-hour and weekly usage limits of several AI accounts (Claude, Codex, Antigravity/Gemini) in one panel. The account picked in the panel is shown in the menu bar. Each extra Claude account runs in its own copy of the Claude desktop app, so the user can switch to another account when one runs out.

Work from the repository root. Run the commands yourself; ask the user only for the things listed in step 1 and for the sign-ins in step 3.

## 0. Check the Mac

- macOS 12 or later on Apple silicon or Intel.
- Command line tools: `xcode-select -p` must succeed (otherwise ask the user to run `xcode-select --install`).
- `jq` on the PATH (built into macOS 15+; otherwise `brew install jq`).
- For Claude accounts: the Claude desktop app at `/Applications/Claude.app`, signed in.
- For Codex: the Codex app or CLI signed in (`~/.codex/auth.json` exists).
- For Antigravity: `/Applications/Antigravity.app` installed and signed in.

## 1. Ask the user (one message, then wait)

Ask:
1. How many Claude accounts do you want to track? The first one is the normal Claude app. Each extra one gets its own app ("Claude Account 2", "Claude Account 3", …) where you sign in once.
2. A display name for each Claude account (default "Claude Account 1", "Claude Account 2", …) and, optionally, a plan label to show (for example "Max 5x"). The plan is otherwise read from Claude.
3. Track Codex? (yes/no)
4. Track Antigravity (Gemini models only)? (yes/no)
5. Should every Claude app show the same Code-tab chats and "No folder" chats? (recommended: yes)

Use the defaults for anything the user leaves out.

## 2. Make one app per extra Claude account

For each extra Claude account `N` (2, 3, …), with app name `Claude Account N` and profile folder `Claude Account N`:

```bash
claude/accounts/make-app.sh "Claude Account N" com.local.claude.accountN "Claude Account N"
```

This copies `/Applications/Claude.app`, gives the copy its own bundle ID and its own profile folder (`~/Library/Application Support/Claude Account N`), and makes it use the main app's no-folder chat folder. It never changes `Claude.app`. If the app already exists it only stages a new build; see "Update" below.

## 3. Ask the user to sign in

Tell the user, for each new app: open `/Applications/Claude Account N.app`, sign in to that account, then quit the app normally (Claude ▸ Quit, not Log out). If macOS asks to use "Claude Safe Storage", choose Always Allow. Wait until they confirm.

## 4. Write the config

Write `~/.config/ailimitbar/accounts.json` (create the folder). Order = order in the panel. Tags are 2–3 characters shown in the menu bar pill. Example for three Claude accounts plus Codex and Antigravity:

```json
{
  "accounts": [
    { "name": "Claude Account 1", "tag": "C1", "type": "claude", "profile": "Claude" },
    { "name": "Claude Account 2", "tag": "C2", "type": "claude", "profile": "Claude Account 2" },
    { "name": "Claude Account 3", "tag": "C3", "type": "claude", "profile": "Claude Account 3" },
    { "name": "Codex", "tag": "CX", "type": "codex" },
    { "name": "Antigravity", "tag": "AG", "type": "antigravity" }
  ]
}
```

Fields: `name`, `tag`, `type` (`claude`, `codex` or `antigravity`) are required. `profile` is the Claude profile folder (`Claude` for the main app). `plan` (optional) overrides the plan label. `app` (optional) is the app path or bundle ID opened by the card's open button. Leave out Codex or Antigravity if the user does not use them. Without a config file the bar shows the main Claude account, plus Codex and Antigravity when installed.

## 5. Share chats between the Claude apps (if the user said yes)

After every new app has been signed in and quit:

```bash
claude/accounts/share.sh
```

It links each extra profile's Code-tab chat folder to the main app's folder. It never touches sign-in data and is safe to re-run. Run it again after adding an account.

## 6. Install and check

```bash
./install.sh
~/Applications/ClaudeLimitBar.app/Contents/MacOS/ClaudeLimitBar --self-test
```

`install.sh` builds the app, installs it to `~/Applications/ClaudeLimitBar.app` and starts it at login. Then ask the user to click the bar item: the panel lists each account; clicking a card shows that account in the menu bar. The first run may ask for keychain access to "Claude Safe Storage": choose Always Allow.

`--check` makes one live request per account; do not run it in a loop, Claude rate-limits usage checks (HTTP 429).

## Rules

- Never sign the user out, and never edit, copy, print or send `Cookies`, `config.json`, tokens or keychain items. The bar only reads the Claude app's own token, in memory, to call `api.anthropic.com/api/oauth/usage`.
- Never replace an account app while it is running.
- macOS permission prompts (keychain, removable volumes, screen recording) are the user's choice; tell them what each is for and let them click.

## Update after a Claude app update

Account apps are copies, so they keep the old version. To update one: `claude/accounts/make-app.sh` with the same arguments (it stages `/Applications/.<App Name>.new.app`), ask the user to quit that app, then run `claude/accounts/swap.sh "<App Name>" "<Profile Folder>"`. It backs up the old app and profile to `~/Library/Application Support/AccountAppBackups/` first.

## Uninstall

`./uninstall.sh` removes the bar. Account apps are ordinary apps in `/Applications`; their profiles are in `~/Library/Application Support/<Profile Folder>`. Ask before deleting those, since that signs the account out.
