#!/bin/bash

# --- Robustness Settings ---
# -e: Exit immediately if a command fails
# -u: Treat unset variables as an error
# -o pipefail: Pipeline exit code is the code of the last command to fail
set -euo pipefail

echo "--- 1. Installing Python ---"

echo "--- 2. Initializing Claude ---"

cat > ~/.claude.json << 'EOF'
{
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "2.1.29",
  "oauthAccount": {
    "accountUuid": "b556c7ba-a37b-4b10-bdd8-e97999271881",
    "emailAddress": "pedromv@gmail.com",
    "organizationUuid": "5c759cb8-08c3-4e01-8dee-d51527e00c78"
  }
}
EOF

echo "--- 3. Configuring GitHub CLI ---"

if [ -n "${GH_TOKEN:-}" ]; then
    gh auth setup-git
    echo "gh authenticated as: $(gh api user --jq .login 2>/dev/null || echo 'unknown')"
else
    echo "GH_TOKEN not set in host environment; skipping gh setup."
fi

echo "--- All systems go! ---"