#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# Allow outbound DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
# Allow inbound DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# DNS over TCP as well: an answer too large for UDP (login.microsoftonline.com
# returns eight addresses behind a CNAME chain) is retried over TCP, and with
# that blocked the name never resolves -- not for the allowlist below, and not
# for the tools that need it.
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p tcp --sport 53 -m state --state ESTABLISHED -j ACCEPT
# Allow outbound SSH
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
# Allow inbound SSH responses
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add -exist allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# With the egress proxy next to this container (docker-compose.yml), hostnames
# are its business: HTTPS leaves through it and it decides by name, so nothing
# here depends on which addresses a name had when the container started. Only
# address ranges and `direct:` hosts are opened here. The proxy is found by the
# name Docker gives it and not by a variable, so that whoever may run this
# script cannot point it somewhere else.
EGRESS_PROXY_HOST="egress-proxy"
EGRESS_PROXY_URL="http://${EGRESS_PROXY_HOST}:3128"
USE_PROXY=0
if getent hosts "$EGRESS_PROXY_HOST" >/dev/null; then
    USE_PROXY=1
    echo "Egress proxy found: hostnames in the allowlist are left to it"
else
    echo "No egress proxy: resolving the allowlist's hostnames to addresses"
fi

# Resolve and add other allowed domains
ALLOWED_DOMAINS_FILE="/etc/allowed_domains"
if [ ! -f "$ALLOWED_DOMAINS_FILE" ]; then
    echo "ERROR: $ALLOWED_DOMAINS_FILE not found"
    exit 1
fi

while read -r domain; do
    domain="${domain%$'\r'}"
    # Skip blank lines and comments
    [[ -z "$domain" || "$domain" == \#* ]] && continue
    # A line that is already an address range goes in as is. For services whose
    # addresses rotate behind one name (Microsoft's sign-in endpoints publish
    # 20.190.128.0/18 and 40.126.0.0/18), the range outlives a resolution made
    # once at container start.
    if [[ "$domain" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
        echo "Adding range $domain"
        ipset add -exist allowed-domains "$domain"
        continue
    fi
    # `direct:host` is a host reached without the proxy -- Postgres, SSH --
    # and is resolved here with or without one. Every other name is the
    # proxy's when there is one (the host itself stays reachable directly).
    if [[ "$domain" == direct:* ]]; then
        domain="${domain#direct:}"
    elif [ "$USE_PROXY" = 1 ] && [ "$domain" != "host.docker.internal" ]; then
        continue
    fi
    # A wildcard only means something to the proxy.
    [[ "$domain" == .* || "$domain" == \** ]] && continue
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "WARN: Failed to resolve $domain — skipping"
        continue
    fi
    
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add -exist allowed-domains "$ip"
    done < <(echo "$ips")
done < "$ALLOWED_DOMAINS_FILE"

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify the proxy: it has to let a listed name through and refuse another,
# or every tool in this container is cut off without saying why.
if [ "$USE_PROXY" = 1 ]; then
    if curl --connect-timeout 5 -x "$EGRESS_PROXY_URL" https://example.com >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - the egress proxy let https://example.com through"
        exit 1
    fi
    if ! curl --connect-timeout 5 -x "$EGRESS_PROXY_URL" https://api.github.com/zen >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - unable to reach https://api.github.com through the egress proxy"
        exit 1
    fi
    echo "Firewall verification passed - the egress proxy allows and refuses as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
