#!/bin/bash
#
# host-lan-access-init.sh -- allow-list the Windows host's real LAN IP and
# give it a stable, self-documenting hostname inside the container.
#
# WORKAROUND, not normal container networking. On some Windows machines,
# WSL2's Windows<->WSL loopback port-forwarding gets stuck for IPv4 (a
# connection to 127.0.0.1 completes its TCP handshake but then hangs forever;
# IPv6 loopback and raw IPv4 to real IPs both keep working fine). That breaks
# Docker Desktop's usual host.docker.internal gateway for reaching anything
# bound inside WSL2 (e.g. `kubectl port-forward`), because Docker Desktop's
# own proxy also relays through Windows' IPv4 loopback.
#
# The fix routes around the broken hop entirely: on Windows, a `netsh
# interface portproxy` rule forwards the host's real LAN IP straight to the
# WSL2 VM's real IP (see host-setup/refresh-wsl-portproxy.ps1 /
# host-setup/setup-portproxy.ps1, which run on the HOST, not here). This
# script is the container-side half: it allow-lists that LAN IP in the
# firewall and aliases it to the hostname `host-lan-workaround`, so code and
# commands in this repo read as "the WSL loopback workaround" --
# `curl http://host-lan-workaround:8081/...` -- rather than an unexplained
# raw IP nobody can place.
#
# If a future WSL2/Docker Desktop release fixes the underlying loopback bug,
# this file, post-start.d/40-host-lan-access.sh, the host-setup/*.ps1
# scripts, and the HOST_LAN_IP env var can all just be deleted -- nothing
# else depends on them.
#
# Runs as root via NOPASSWD sudo (see Dockerfile). HOST_LAN_IP is preserved
# through sudo by a scoped `env_keep` Default tied to this exact command --
# see the Dockerfile's sudoers block.

set -uo pipefail

HOSTNAME_ALIAS="host-lan-workaround"
HOSTS_FILE="/etc/hosts"

if [ -z "${HOST_LAN_IP:-}" ]; then
    echo "HOST_LAN_IP not set; skipping host-LAN-access workaround."
    exit 0
fi

if ! [[ "$HOST_LAN_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "ERROR: HOST_LAN_IP='$HOST_LAN_IP' does not look like an IPv4 address; skipping."
    exit 0
fi

# Rewrite the alias's /etc/hosts line fresh on every start -- the IP can
# change between Wi-Fi networks, so a stale entry would silently break this.
sed -i "/[[:space:]]${HOSTNAME_ALIAS}\$/d" "$HOSTS_FILE"
echo "$HOST_LAN_IP $HOSTNAME_ALIAS" >> "$HOSTS_FILE"
echo "Added /etc/hosts entry: $HOST_LAN_IP -> $HOSTNAME_ALIAS"

# 10-firewall.sh (runs earlier in post-start.d) already created this ipset.
if ipset add -exist allowed-domains "$HOST_LAN_IP" 2>/dev/null; then
    echo "Allow-listed $HOST_LAN_IP ($HOSTNAME_ALIAS) in the firewall."
else
    echo "WARN: could not add $HOST_LAN_IP to the allowed-domains ipset (did 10-firewall.sh run first?)."
fi
