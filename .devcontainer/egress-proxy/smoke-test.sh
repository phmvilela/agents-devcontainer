#!/bin/bash
#
# smoke-test.sh -- run ON THE HOST, before rebuilding the dev container: builds
# the egress proxy by itself, starts it, and checks what it lets through.
#
#   bash .devcontainer/egress-proxy/smoke-test.sh
#
# Nothing here touches a running dev container. A proxy that fails this must
# not be switched to: with it, the dev container would have no way out.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# The compose file needs it to be read at all; nothing here mounts the workspace.
export LOCAL_WORKSPACE_FOLDER_BASENAME="$(basename "$(cd .. && pwd)")"
# Its own project: the proxy the dev container uses is not touched.
COMPOSE=(docker compose -p egress-proxy-smoke -f docker-compose.yml)
failed=0

# What the proxy did with a request. curl's exit code alone cannot say: a
# refusal arrives as an ordinary 403 error page, and curl calls that a success.
# Squid stamps its own answers with X-Squid-Error, so an answer carrying it
# never came from the far side.
verdict() {   # verdict curl-args... -- prints "allowed <why>" or "refused <why>"
    local headers rc
    headers="$("${COMPOSE[@]}" exec -T egress-proxy curl -sS -D - -o /dev/null \
               --max-time 15 -x http://127.0.0.1:3128 "$@" 2>&1)"; rc=$?
    local status
    status="$(printf '%s' "$headers" | head -1 | tr -d '\r')"
    if [ "$rc" -ne 0 ]; then echo "refused (curl exit $rc)"
    elif printf '%s' "$headers" | grep -qiE '^(x-squid-error:|server: *squid)'; then
        echo "refused ($status, written by the proxy)"
    else echo "allowed ($status)"; fi
}

check() {   # check "what" expected-outcome curl-args...
    local what="$1" expected="$2"; shift 2
    local got; got="$(verdict "$@")"
    if [ "${got%% *}" = "$expected" ]; then echo "  ok    $what -- $got"
    else echo "  FAIL  $what: expected $expected, was $got"; failed=1; fi
}

check_cmd() {   # check_cmd "what" expected-outcome command...
    local what="$1" expected="$2"; shift 2
    local got=refused
    "${COMPOSE[@]}" exec -T egress-proxy "$@" >/dev/null 2>&1 && got=allowed
    if [ "$got" = "$expected" ]; then echo "  ok    $what ($got)"
    else echo "  FAIL  $what: expected $expected, was $got"; failed=1; fi
}

echo "Building and starting the proxy..."
"${COMPOSE[@]}" up -d --build --wait egress-proxy || {
    echo "The proxy did not start. Its log:"; "${COMPOSE[@]}" logs --tail 40 egress-proxy; exit 1; }

check "a listed hostname (api.github.com)"             allowed https://api.github.com/zen
check "a hostname that is not listed (example.com)"    refused https://example.com/
check "plain HTTP to a listed hostname"                refused http://github.com/
check "a listed hostname on another port"              refused https://github.com:8443/
check "a bare address"                                 refused -k https://140.82.112.3/
# Asks the proxy for a listed name, then names another host in the handshake.
check_cmd "an unlisted name in the TLS handshake"      refused \
    sh -c 'echo | openssl s_client -proxy 127.0.0.1:3128 -connect api.github.com:443 \
           -servername example.com 2>/dev/null | grep -q "BEGIN CERTIFICATE"'

echo
echo "What the proxy logged:"
"${COMPOSE[@]}" logs --tail 12 --no-log-prefix egress-proxy
echo
"${COMPOSE[@]}" down >/dev/null 2>&1
if [ "$failed" = 0 ]; then echo "All checks passed. Rebuild the dev container to use the proxy."
else echo "Some checks FAILED. Do not rebuild the dev container on this."; fi
exit "$failed"
