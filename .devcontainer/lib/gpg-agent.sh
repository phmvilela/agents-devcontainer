#!/bin/bash
#
# Shared helpers for keeping a container-local, non-forwarded gpg-agent alive
# at $GNUPGHOME (see post-start.d/20-gpg-signing.sh for the forwarding
# background). Sourced by that post-start step and by gpg-wrapper.sh (git's
# gpg.program) so boot-time setup and every later signing attempt share one
# detect-and-repair implementation.
#
# Meant to be sourced, not executed. Callers must export GNUPGHOME first.

# True (0) if the agent listening on $GNUPGHOME/S.gpg-agent is a forwarded
# (host) agent rather than a local one -- forwarded agents run in "restricted
# mode" and refuse loopback pinentry, which breaks headless signing.
gpg_agent_is_forwarded() {
    gpg-connect-agent --homedir "$GNUPGHOME" 'NOP' /bye 2>&1 | grep -qi 'restricted mode'
}

# Kill any forwarded agent occupying our socket and start a genuine local one.
# No-op if a healthy local agent is already running.
gpg_agent_ensure_local() {
    if ! gpg_agent_is_forwarded; then
        return 0
    fi
    # stderr, not stdout: gpg_import_and_configure's stdout is captured by its
    # caller as the key fingerprint, and a stray log line here ends up
    # concatenated into git's user.signingkey.
    echo "gpg-agent at \$GNUPGHOME is forwarded/restricted; replacing with a local one." >&2
    gpgconf --homedir "$GNUPGHOME" --kill gpg-agent >/dev/null 2>&1 || true
    rm -f "$GNUPGHOME"/S.gpg-agent*
    gpg-agent --homedir "$GNUPGHOME" --daemon --batch >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        gpg-connect-agent --homedir "$GNUPGHOME" 'NOP' /bye >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    echo "WARN: local gpg-agent did not come up in time." >&2
}

# Import $GPG_PRIVATE_KEY (base64-encoded), trust it, configure loopback
# pinentry + long cache TTLs, and prime the passphrase cache. Prints the
# imported fingerprint on success, prints nothing and returns 1 on failure.
#
# Always ensures a local agent first: a freshly (re)started agent has an
# empty private-keys-v1.d, so if the previous agent turned out to be a
# forwarded one, re-importing is required, not optional -- the key may look
# imported (pubring.kbx is a local file either way) without actually being
# usable for signing.
gpg_import_and_configure() {
    if [ -z "${GPG_PRIVATE_KEY:-}" ]; then
        return 1
    fi

    gpg_agent_ensure_local

    mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

    local import_status fpr
    import_status=$(echo "$GPG_PRIVATE_KEY" | base64 -d | gpg --homedir "$GNUPGHOME" --batch --import --status-fd 1 2>/dev/null || true)
    fpr=$(echo "$import_status" | awk '/IMPORT_OK/ {print $4; exit}')
    if [ -z "$fpr" ]; then
        return 1
    fi

    echo -e "5\ny\n" | gpg --homedir "$GNUPGHOME" --batch --command-fd 0 --edit-key "$fpr" trust quit >/dev/null 2>&1 || true

    grep -qxF "allow-loopback-pinentry" "$GNUPGHOME/gpg-agent.conf" 2>/dev/null || \
        echo "allow-loopback-pinentry" >> "$GNUPGHOME/gpg-agent.conf"
    grep -qxF "default-cache-ttl 34560000" "$GNUPGHOME/gpg-agent.conf" 2>/dev/null || \
        echo "default-cache-ttl 34560000" >> "$GNUPGHOME/gpg-agent.conf"
    grep -qxF "max-cache-ttl 34560000" "$GNUPGHOME/gpg-agent.conf" 2>/dev/null || \
        echo "max-cache-ttl 34560000" >> "$GNUPGHOME/gpg-agent.conf"
    grep -qxF "pinentry-mode loopback" "$GNUPGHOME/gpg.conf" 2>/dev/null || \
        echo "pinentry-mode loopback" >> "$GNUPGHOME/gpg.conf"
    gpgconf --homedir "$GNUPGHOME" --reload gpg-agent >/dev/null 2>&1 || true

    if [ -n "${GPG_PASSPHRASE:-}" ]; then
        echo "test" | gpg --homedir "$GNUPGHOME" --batch --yes --pinentry-mode loopback \
            --passphrase "$GPG_PASSPHRASE" --local-user "$fpr" --sign --armor >/dev/null 2>&1 || true
    fi

    echo "$fpr"
}
