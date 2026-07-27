#!/bin/bash
#
# post-start step: import the GPG signing key and configure git to sign commits.
#
# WHY A DEDICATED GNUPGHOME
# -------------------------
# VS Code Remote-Containers forwards the *host* gpg-agent socket into the
# container at the default ~/.gnupg/S.gpg-agent. That forwarded agent forbids
# loopback pinentry, so every headless signing attempt against ~/.gnupg fails
# with "setting pinentry mode 'loopback' failed: Forbidden" — no amount of
# gpg-agent.conf tweaking helps, because we are not talking to our own agent.
#
# The fix is to keep our keyring somewhere the forward does NOT cover.
# devcontainer.json sets GNUPGHOME=/home/vscode/.gnupg-signing (containerEnv), so
# gpg — and therefore git — spawns and talks to a container-local agent there and
# loopback pinentry works. We still honour an externally-set GNUPGHOME and only
# fall back to a sensible default when run standalone.
#
# WHY A SELF-HEALING gpg.program (see lib/gpg-agent.sh, gpg-wrapper.sh)
# -----------------------------------------------------------------------
# In practice this step winning that race once at boot isn't good enough:
# the forward can still land on $GNUPGHOME/S.gpg-agent later (a VS Code
# reconnect, a rebuild), and even a genuinely local agent loses its primed
# passphrase cache if it gets killed/restarted for any reason. Either way,
# gpg can look configured (the key still shows up in --list-secret-keys)
# while every signature actually fails. Rather than assume this step's setup
# holds for the container's whole lifetime, git's gpg.program is pointed at
# gpg-wrapper.sh, which runs an isolated preflight sign before every real one
# and repairs (kill+restart the agent if forwarded, re-import, re-prime) on
# failure.
#
# This step is best-effort: a missing key or a transient gpg hiccup logs and
# skips rather than failing the whole container start.

# -u: undefined vars are errors; -o pipefail: catch failures in pipelines.
# NOTE: no -e here on purpose — individual steps degrade gracefully below.
set -uo pipefail

if [ -z "${GPG_PRIVATE_KEY:-}" ]; then
    echo "GPG_PRIVATE_KEY not set in host environment; skipping GPG setup."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVCONTAINER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/gpg-agent.sh
source "$DEVCONTAINER_DIR/lib/gpg-agent.sh"

# Container-local keyring, outside the forwarded ~/.gnupg (see header).
export GNUPGHOME="${GNUPGHOME:-/home/vscode/.gnupg-signing}"

FPR="$(gpg_import_and_configure)"
if [ -z "$FPR" ]; then
    echo "Could not determine the imported key fingerprint; skipping git signing config."
    exit 0
fi

# Configure git to sign commits and tags with it, via the self-healing wrapper.
git config --global user.signingkey "$FPR"
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global gpg.program "$DEVCONTAINER_DIR/gpg-wrapper.sh"

# Set git identity from the key's UID (e.g. "pgcyan Developer <dev@example.com>").
KEY_UID=$(gpg --homedir "$GNUPGHOME" --with-colons --list-keys "$FPR" | awk -F: '/^uid:/ {print $10; exit}')
KEY_NAME=$(echo "$KEY_UID" | sed -E 's/[[:space:]]*<[^>]*>[[:space:]]*$//')
KEY_EMAIL=$(echo "$KEY_UID" | sed -E 's/.*<([^>]*)>.*/\1/')
if [ -n "$KEY_NAME" ] && [ -n "$KEY_EMAIL" ]; then
    git config --global user.name "$KEY_NAME"
    git config --global user.email "$KEY_EMAIL"
    echo "git user.name/user.email set from GPG key UID: $KEY_NAME <$KEY_EMAIL>"
fi

echo "GPG signing configured with key $FPR (GNUPGHOME=$GNUPGHOME, gpg.program=$DEVCONTAINER_DIR/gpg-wrapper.sh)"
