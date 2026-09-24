#!/bin/bash
#
# post-start step: allow-list the Windows host's real LAN IP under the
# hostname `host-lan-workaround`, so containerized processes can reach
# services bound inside the developer's WSL2 distro (e.g.
# `kubectl port-forward`) even when Docker Desktop's usual
# `host.docker.internal` gateway hangs.
#
# WORKAROUND for a WSL2/Docker Desktop networking bug (broken IPv4 loopback
# forwarding between Windows and WSL2), not standard devcontainer plumbing --
# see .devcontainer/host-lan-access-init.sh and
# .devcontainer/host-setup/README.md for the full story and the matching
# Windows-side `netsh portproxy` setup.
#
# Best-effort: a missing HOST_LAN_IP just means this workaround isn't needed
# (or isn't configured) on your machine -- log and skip rather than fail the
# whole container start (mirrors 30-kubeconfig.sh).

set -uo pipefail

if [ -z "${HOST_LAN_IP:-}" ]; then
    echo "HOST_LAN_IP not set in host environment; skipping host-LAN-access workaround."
    echo "  (See .devcontainer/host-setup/README.md if host.docker.internal hangs for you.)"
    exit 0
fi

sudo /usr/local/bin/host-lan-access-init.sh
