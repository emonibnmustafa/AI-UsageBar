# AILimitBar: notes for AI agents

To install or set up AILimitBar for the user, follow `.claude/skills/install-ailimitbar/SKILL.md` step by step. It says what to ask the user (how many Claude accounts, Codex, Antigravity), which scripts to run, and the safety rules (never sign the user out or touch their tokens).

Code map: `claude/main.swift` is the whole menu bar app (accounts config, fetchers, SwiftUI panel, menu bar art). `claude/accounts/` holds the scripts that make per-account Claude apps. `codex/` is an older standalone Codex bar, not installed by default.

Build and test: `claude/scripts/install.sh` (runs `--self-test`). Do not run `--check` repeatedly: Claude rate-limits usage requests.
