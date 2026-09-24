#!/bin/bash
#
# bootstrap-portproxy.sh -- WSL-side convenience wrapper: launches
# setup-portproxy.ps1 (elevated) from your WSL terminal via `powershell.exe`
# interop, so you don't have to manually open an Administrator PowerShell.
#
# RUNS ON THE HOST (your WSL2 distro), NOT in the devcontainer -- container
# processes have no path back to Windows binaries. One-time use; re-running
# is safe (setup-portproxy.ps1 is idempotent).
#
# `powershell.exe` itself does not need to be elevated to ask Windows to
# elevate something else: this uses `Start-Process -Verb RunAs`, which pops a
# single UAC prompt for setup-portproxy.ps1 specifically. Accept that prompt.
#
# See also: setup-portproxy.ps1 (what actually runs, elevated),
#           refresh-portproxy.sh (the no-prompt day-to-day companion),
#           README.md (the whole workaround, explained).

set -euo pipefail
IFS=$'\n\t'

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v powershell.exe >/dev/null 2>&1 \
    || die "powershell.exe not found -- this must run from a WSL2 terminal, not the devcontainer."
command -v wslpath >/dev/null 2>&1 \
    || die "wslpath not found -- this must run from a WSL2 terminal, not the devcontainer."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_PS1_WSL="$SCRIPT_DIR/setup-portproxy.ps1"
[ -f "$SETUP_PS1_WSL" ] || die "setup-portproxy.ps1 not found next to this script at $SETUP_PS1_WSL"

SETUP_PS1_WIN="$(wslpath -w "$SETUP_PS1_WSL")"

log "Launching setup-portproxy.ps1 elevated -- accept the UAC prompt that appears."
powershell.exe -NoProfile -Command \
    "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"$SETUP_PS1_WIN\"'"

log "Done. From now on, the portproxy mapping refreshes automatically at every Windows logon."
log "If you 'wsl --shutdown' mid-session, run ./refresh-portproxy.sh instead of logging out."
