#!/bin/bash
#
# git's gpg.program (wired up by post-start.d/20-gpg-signing.sh).
#
# Headless signing here can break in two ways after the post-start step has
# already run once successfully:
#
#   1. VS Code's gpg-agent socket forwarding lands on $GNUPGHOME/S.gpg-agent
#      -- at boot, on a later reconnect, or after a rebuild -- clobbering the
#      local agent with a restricted, host-forwarded one. It still answers
#      `keyinfo` queries, so gpg *looks* configured, but every signature then
#      fails with "... Forbidden".
#   2. The local agent gets killed/restarted (container restart, `gpgconf
#      --kill`, hitting the agent's own idle limits some other way) and comes
#      back with an empty passphrase cache, so signing fails with "cannot
#      open '/dev/tty'" instead.
#
# Rather than special-case each cause, run a silent, isolated preflight sign
# (its own stdin/stdout/status-fd, untouched by git's real invocation below)
# to find out if signing actually works right now. If it doesn't, repair
# (kill+restart the agent if it's forwarded, re-import the key, re-prime the
# passphrase cache -- see gpg_import_and_configure) before the real sign.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GNUPGHOME="${GNUPGHOME:-/home/vscode/.gnupg-signing}"
# shellcheck source=lib/gpg-agent.sh
source "$SCRIPT_DIR/lib/gpg-agent.sh"

SIGNING_KEY="$(git config --get user.signingkey 2>/dev/null || true)"
if [ -n "$SIGNING_KEY" ] && [ -n "${GPG_PRIVATE_KEY:-}" ]; then
    if ! echo "gpg-wrapper preflight" | gpg --homedir "$GNUPGHOME" --batch --pinentry-mode loopback \
            --local-user "$SIGNING_KEY" --sign --armor >/dev/null 2>/dev/null; then
        gpg_import_and_configure >/dev/null
    fi
fi

exec gpg --homedir "$GNUPGHOME" "$@"
