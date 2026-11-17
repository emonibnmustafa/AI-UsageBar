#!/bin/bash
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for bar in codex claude; do "$ROOT/$bar/scripts/uninstall.sh"; done
