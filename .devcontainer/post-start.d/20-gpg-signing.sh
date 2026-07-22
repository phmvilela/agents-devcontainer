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
# This step is best-effort: a missing key or a transient gpg hiccup logs and
# skips rather than failing the whole container start.

# -u: undefined vars are errors; -o pipefail: catch failures in pipelines.
# NOTE: no -e here on purpose — individual steps degrade gracefully below.
set -uo pipefail

if [ -z "${GPG_PRIVATE_KEY:-}" ]; then
    echo "GPG_PRIVATE_KEY not set in host environment; skipping GPG setup."
    exit 0
fi

# Container-local keyring, outside the forwarded ~/.gnupg (see header).
export GNUPGHOME="${GNUPGHOME:-/home/vscode/.gnupg-signing}"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

# Import the ASCII-armored private key (passed base64-encoded to survive env
# vars). Capture status output so we can target the *just-imported* key (handles
# rotation).
IMPORT_STATUS=$(echo "$GPG_PRIVATE_KEY" | base64 -d | gpg --batch --import --status-fd 1 2>/dev/null || true)
FPR=$(echo "$IMPORT_STATUS" | awk '/IMPORT_OK/ {print $4; exit}')

if [ -z "$FPR" ]; then
    echo "Could not determine the imported key fingerprint; skipping git signing config."
    exit 0
fi

# Mark the imported key as ultimately trusted.
echo -e "5\ny\n" | gpg --batch --command-fd 0 --edit-key "$FPR" trust quit >/dev/null 2>&1 || true

# Configure git to sign commits and tags with it.
git config --global user.signingkey "$FPR"
git config --global commit.gpgsign true
git config --global tag.gpgsign true

# Set git identity from the key's UID (e.g. "pgcyan Developer <dev@example.com>").
KEY_UID=$(gpg --with-colons --list-keys "$FPR" | awk -F: '/^uid:/ {print $10; exit}')
KEY_NAME=$(echo "$KEY_UID" | sed -E 's/[[:space:]]*<[^>]*>[[:space:]]*$//')
KEY_EMAIL=$(echo "$KEY_UID" | sed -E 's/.*<([^>]*)>.*/\1/')
if [ -n "$KEY_NAME" ] && [ -n "$KEY_EMAIL" ]; then
    git config --global user.name "$KEY_NAME"
    git config --global user.email "$KEY_EMAIL"
    echo "git user.name/user.email set from GPG key UID: $KEY_NAME <$KEY_EMAIL>"
fi

# Allow non-interactive (loopback) passphrase entry so signing works headless.
grep -qxF "allow-loopback-pinentry" "$GNUPGHOME/gpg-agent.conf" 2>/dev/null || \
    echo "allow-loopback-pinentry" >> "$GNUPGHOME/gpg-agent.conf"
grep -qxF "pinentry-mode loopback" "$GNUPGHOME/gpg.conf" 2>/dev/null || \
    echo "pinentry-mode loopback" >> "$GNUPGHOME/gpg.conf"

# Keep the primed passphrase cached for the container's lifetime. gpg-agent
# defaults (600s idle / 7200s max) would evict it within a couple of hours,
# after which headless signing fails with "cannot open '/dev/tty'". The
# passphrase already lives in $GPG_PASSPHRASE, so caching it long-term here does
# not change the security posture of an ephemeral dev container.
grep -qxF "default-cache-ttl 34560000" "$GNUPGHOME/gpg-agent.conf" 2>/dev/null || \
    echo "default-cache-ttl 34560000" >> "$GNUPGHOME/gpg-agent.conf"
grep -qxF "max-cache-ttl 34560000" "$GNUPGHOME/gpg-agent.conf" 2>/dev/null || \
    echo "max-cache-ttl 34560000" >> "$GNUPGHOME/gpg-agent.conf"
gpgconf --reload gpg-agent >/dev/null 2>&1 || true

# If the key has a passphrase, prime the agent cache so git doesn't prompt.
if [ -n "${GPG_PASSPHRASE:-}" ]; then
    echo "test" | gpg --batch --yes --pinentry-mode loopback \
        --passphrase "$GPG_PASSPHRASE" --local-user "$FPR" \
        --sign --armor >/dev/null 2>&1 || true
fi

echo "GPG signing configured with key $FPR (GNUPGHOME=$GNUPGHOME)"
