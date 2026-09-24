#!/bin/bash
#
# refresh-portproxy.sh -- WSL-side convenience wrapper: re-runs the portproxy
# refresh after a `wsl --shutdown` mid-session, WITHOUT needing to log out of
# Windows or open an elevated PowerShell yourself.
#
# RUNS ON THE HOST (your WSL2 distro), NOT in the devcontainer.
#
# No UAC prompt: this just asks the Scheduled Task (registered once by
# bootstrap-portproxy.sh / setup-portproxy.ps1 with "run with highest
# privileges") to fire now. Windows' Task Scheduler grants the elevated token
# to the TASK when it starts, regardless of whether the caller that triggered
# it is elevated -- that's the whole point of using a scheduled task here
# instead of calling setup-portproxy.ps1 directly.
#
# Run this any time `curl host-lan-workaround:8081/...` from the container
# starts hanging again after you restart WSL2 mid-session (the WSL2 VM gets a
# new IP on every restart, which leaves the portproxy mapping stale until the
# next Windows logon or this refresh).
#
# See also: bootstrap-portproxy.sh (one-time, elevated setup),
#           refresh-wsl-portproxy.ps1 (what the task actually runs),
#           README.md (the whole workaround, explained).

set -euo pipefail
IFS=$'\n\t'

TASK_NAME="${TASK_NAME:-pgcyan-wsl-portproxy-refresh}"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v powershell.exe >/dev/null 2>&1 \
    || die "powershell.exe not found -- this must run from a WSL2 terminal, not the devcontainer."

if ! powershell.exe -NoProfile -Command "Get-ScheduledTask -TaskName '$TASK_NAME'" >/dev/null 2>&1; then
    die "Scheduled task '$TASK_NAME' not found. Run ./bootstrap-portproxy.sh first (one-time setup)."
fi

powershell.exe -NoProfile -Command "Start-ScheduledTask -TaskName '$TASK_NAME'"
log "Triggered '$TASK_NAME'. Give it a couple seconds, then retest from the container."
