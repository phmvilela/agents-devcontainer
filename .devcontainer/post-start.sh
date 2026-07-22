#!/bin/bash
#
# post-start lifecycle hook — runs on every container start.
#
# This is a thin aggregator. Each concern (firewall, GPG signing, ...) lives in
# its own script under post-start.d/, run here in lexical order — the numeric
# prefixes (10-, 20-, ...) set that order. To add a step, drop a new script into
# post-start.d/; you do not need to edit this file.

# --- Robustness Settings ---
# -e: Exit immediately if a command fails
# -u: Treat unset variables as an error
# -o pipefail: Pipeline exit code is the code of the last command to fail
set -euo pipefail

STEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/post-start.d"

if [ ! -d "$STEPS_DIR" ]; then
    echo "No steps directory at $STEPS_DIR; nothing to do."
    exit 0
fi

for step in "$STEPS_DIR"/*.sh; do
    [ -e "$step" ] || continue   # empty glob stays literal; skip it
    echo "=== post-start: running $(basename "$step") ==="
    bash "$step"
done

echo "--- Post-start complete! ---"
