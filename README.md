# AILimitBar

See how much of your AI usage limits is left, for several Claude accounts, Codex and Antigravity (Gemini), in one macOS menu bar app. When one account runs out, pick another one and keep working on the same projects and chats.

![Menu bar](docs/menubar.png)

<img src="docs/panel.png" alt="AI Usage panel" width="380">

- **Menu bar**: the account you pick, with ring gauges for the 5-hour and weekly limits, percentage left and reset time. Orange under 25%, red under 10%.
- **Panel**: every account in its own colour, with plan, both limits and reset times. Click a card to show it in the menu bar. Drag the panel anywhere on screen.
- **Several Claude accounts at once**: each extra account gets its own copy of the Claude app, so you never have to sign out. All Claude apps can share the same Code-tab chats and projects.
- **Live**: the account in the menu bar refreshes about every 30 seconds; the others refresh when you open the panel.

## Install with your AI (recommended)

Give this repository's link to Claude Code, Codex or another coding agent on your Mac and say:

> Install this for me: https://github.com/emonibnmustafa/AI-UsageBar

The agent follows [`.claude/skills/install-ailimitbar/SKILL.md`](.claude/skills/install-ailimitbar/SKILL.md). It asks how many Claude accounts you use (and their names), and whether you use Codex and Antigravity. Then it creates one Claude app per extra account, asks you to sign in to each once, writes your config, and installs the menu bar app.

## Install by hand

Requirements: macOS 12+, Xcode command line tools, `jq`, and the Claude desktop app (plus Codex and/or Antigravity if you use them).

```bash
git clone https://github.com/emonibnmustafa/AI-UsageBar.git
cd AI-UsageBar
# For each extra Claude account (2, 3, ...):
claude/accounts/make-app.sh "Claude Account 2" com.local.claude.account2 "Claude Account 2"
# Open the new app, sign in, quit it. Then:
mkdir -p ~/.config/ailimitbar && cp accounts.example.json ~/.config/ailimitbar/accounts.json   # edit to match your accounts
claude/accounts/share.sh   # optional: same chats in every Claude app
./install.sh
```

The config format is described in the [install skill](.claude/skills/install-ailimitbar/SKILL.md#4-write-the-config). Remove everything with `./uninstall.sh`.

## Privacy

Everything runs on your Mac. Sign-in tokens are read from the apps' own storage, kept in memory, and sent only to each service's own usage endpoint. No names or emails are shown or stored. The account apps never change or sign out your existing Claude app.

## Repository

| Folder | What |
|---|---|
| `claude/` | The menu bar app (`main.swift`) and the account-app scripts (`accounts/`). See [claude/README.md](claude/README.md). |
| `codex/` | An older standalone Codex bar (context window, low-limit popups). Not installed by `./install.sh`; install alone with `codex/scripts/install.sh`. |

These usage endpoints are internal to each service and may change with app updates.

## License

MIT
