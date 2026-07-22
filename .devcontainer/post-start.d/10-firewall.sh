#!/bin/bash
#
# post-start step: initialize the container firewall (egress allow-list).
#
# The rules themselves live in /usr/local/bin/firewall-init.sh, which the
# Dockerfile installs and grants the vscode user passwordless sudo for (see the
# sudoers line in .devcontainer/Dockerfile). A failure here is intentionally
# fatal: we do not want the container to keep running with egress wide open.

# --- Robustness Settings ---
# -e: Exit immediately if a command fails
# -u: Treat unset variables as an error
# -o pipefail: Pipeline exit code is the code of the last command to fail
set -euo pipefail

echo "Initializing firewall..."
sudo /usr/local/bin/firewall-init.sh
