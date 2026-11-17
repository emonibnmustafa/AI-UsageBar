#!/bin/bash
# Build and install every limit bar in this repo. Add new providers to BARS.
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BARS=(claude)   # Codex is shown inside the Claude bar panel
for bar in "${BARS[@]}"; do
    echo "=== $bar ==="
    "$ROOT/$bar/scripts/install.sh"
done
