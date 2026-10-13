#!/bin/sh
#
# Entrypoint of the egress proxy: writes Squid's allowlist and configuration,
# then runs Squid in the foreground with its logs on the container's output.
#
#   entrypoint.sh           start the proxy
#   entrypoint.sh reload    read ~/allowed_domains again (docker exec, no restart)
#
# EGRESS_PROXY_SNI_CHECK (default 1): also require the hostname in the TLS
# handshake to be on the list, so that a tunnel asked for under an allowed
# name cannot be used to reach another site at the same address. Nothing is
# decrypted. 0 turns it off: the name in the CONNECT request alone decides.
set -eu

ALLOWED_FILES="/etc/egress-proxy/baseline_domains /etc/egress-proxy/allowed_domains"
LIST=/etc/squid/allowed.dstdomain
CONF=/etc/squid/squid.conf
PEEK_CERT=/etc/squid/peek.pem
SNI_CHECK="${EGRESS_PROXY_SNI_CHECK:-1}"

write_list() {
    files=""
    for f in $ALLOWED_FILES; do
        # A host file that does not exist is mounted by Docker as a directory.
        if [ -f "$f" ]; then files="$files $f"; else echo "egress-proxy: no file at $f"; fi
    done
    # shellcheck disable=SC2086
    gen-allowlist.sh $files > "$LIST.new"
    mv "$LIST.new" "$LIST"
    echo "egress-proxy: $(wc -l < "$LIST") hostnames allowed"
}

write_conf() {
    if [ "$SNI_CHECK" = "1" ]; then
        # The peeking port has to be given a certificate although it never
        # presents one: every connection is spliced or terminated, none bumped.
        if [ ! -s "$PEEK_CERT" ]; then
            openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=egress-proxy" \
                -keyout "$PEEK_CERT" -out "$PEEK_CERT" 2>/dev/null
            chown proxy:proxy "$PEEK_CERT"; chmod 0600 "$PEEK_CERT"
        fi
        port="http_port 3128 ssl-bump tls-cert=$PEEK_CERT generate-host-certificates=off"
        bump="acl allowed_sni ssl::server_name \"$LIST\"
acl tls_hello at_step SslBump1
ssl_bump peek tls_hello
ssl_bump splice allowed_sni
ssl_bump terminate all"
    else
        port="http_port 3128"
        bump=""
    fi
    cat > "$CONF" <<CONF
$port

acl allowed dstdomain "$LIST"
acl https_port port 443
acl CONNECT method CONNECT

# HTTPS tunnels to listed hostnames, and nothing else: no plain HTTP, no other
# port, no request for a bare address.
http_access deny !CONNECT
http_access deny !https_port
http_access allow allowed
http_access deny all

$bump

# A gate, not a cache.
cache deny all
via off
forwarded_for delete
shutdown_lifetime 1 seconds
pid_filename /run/squid.pid
coredump_dir /var/spool/squid

# One line per request: when, who, what Squid decided, and the hostname. A
# refused name reads TCP_DENIED/403; one stopped at the handshake NONE_NONE/000
# after its CONNECT.
logformat egress %tl %>a %Ss/%03>Hs %rm %ru sni=%ssl::>sni
access_log stdio:/var/log/squid/access.log egress
cache_log /var/log/squid/cache.log
CONF
}

if [ "${1:-}" = "reload" ]; then
    write_list
    # Signal Squid directly instead of `squid -k reconfigure`: that one reads
    # /run/squid.pid and refuses a PID of 1 ("unreasonably small"), which is
    # exactly what the PID is here, since the entrypoint execs Squid as the
    # container's first process. SIGHUP is what `-k reconfigure` sends anyway.
    if kill -HUP 1 2>/dev/null; then
        echo "egress-proxy: Squid told to re-read it (docker logs shows the reconfigure)"
    else
        echo "egress-proxy: could not signal Squid; restart this container instead" >&2
        exit 1
    fi
    exit 0
fi

write_list
write_conf
if ! squid -k parse -f "$CONF" > /tmp/parse.log 2>&1; then
    cat /tmp/parse.log
    echo "egress-proxy: Squid refused its configuration"
    exit 1
fi

rm -f /run/squid.pid
mkdir -p /var/log/squid
: > /var/log/squid/access.log; : > /var/log/squid/cache.log
chown -R proxy:proxy /var/log/squid

# Squid drops to the proxy user and cannot write to the container's output
# from there, so it logs to files and these follow them.
tail -F /var/log/squid/access.log /var/log/squid/cache.log 2>/dev/null &
exec squid -N -f "$CONF"
