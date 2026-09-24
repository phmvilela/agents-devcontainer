#!/bin/bash

# --- Robustness Settings ---
# -e: Exit immediately if a command fails
# -u: Treat unset variables as an error
# -o pipefail: Pipeline exit code is the code of the last command to fail
set -euo pipefail

echo "--- 1. Configuring Claude ---"

for rcfile in ~/.bashrc ~/.zshrc; do
    if [ -f "$rcfile" ] && ! grep -q "alias superclaude=" "$rcfile"; then
        echo "alias superclaude='claude --dangerously-skip-permissions'" >> "$rcfile"
    fi
done

# Claude Code's state (sessions, transcripts, credentials, settings, plugins)
# lives in its config home, which devcontainer.json pins to /home/vscode/.claude
# and backs with a named Docker volume so it survives container rebuilds.
# CLAUDE_CONFIG_DIR also relocates the global config file into that directory.
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_GLOBAL_CONFIG="$CLAUDE_HOME/.claude.json"
mkdir -p "$CLAUDE_HOME"

# One-time migration for containers created before the volume existed, when the
# global config still sat at ~/.claude.json.
if [ ! -f "$CLAUDE_GLOBAL_CONFIG" ] && [ -f "$HOME/.claude.json" ]; then
    echo "Migrating legacy ~/.claude.json into $CLAUDE_GLOBAL_CONFIG"
    mv "$HOME/.claude.json" "$CLAUDE_GLOBAL_CONFIG"
fi

# Seed the identity/onboarding keys. This MERGES into any config restored from
# the volume rather than overwriting it -- a plain `cat >` here would discard
# the persisted project trust, history and MCP server definitions on every
# rebuild, which is exactly what the volume exists to prevent.
node -e '
const fs = require("fs");
const path = process.argv[1];
const seed = {
  hasCompletedOnboarding: true,
  lastOnboardingVersion: "2.1.29",
  oauthAccount: {
    accountUuid: "b556c7ba-a37b-4b10-bdd8-e97999271881",
    emailAddress: "pedromv@gmail.com",
    organizationUuid: "5c759cb8-08c3-4e01-8dee-d51527e00c78",
  },
};
let config = {};
try {
  config = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (err) {
  // Missing file on a fresh volume is expected; anything else means the file is
  // unreadable or corrupt, so start clean rather than aborting post-create.
  if (err.code !== "ENOENT") console.warn(`Ignoring unreadable ${path}: ${err.message}`);
}
fs.writeFileSync(path, JSON.stringify({ ...config, ...seed }, null, 2) + "\n");
' "$CLAUDE_GLOBAL_CONFIG"

echo "Claude config home: $CLAUDE_HOME"

echo "--- 2. Configuring GitHub CLI ---"

if [ -n "${GH_TOKEN:-}" ]; then
    gh auth setup-git
    echo "gh authenticated as: $(gh api user --jq .login 2>/dev/null || echo 'unknown')"
else
    echo "GH_TOKEN not set in host environment; skipping gh setup."
fi

echo "--- All systems go! ---"
