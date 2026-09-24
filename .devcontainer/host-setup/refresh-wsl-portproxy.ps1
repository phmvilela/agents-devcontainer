<#
.SYNOPSIS
  Refresh netsh portproxy mappings from Windows' real LAN IP to the current
  WSL2 VM IP. WORKAROUND for a WSL2 bug -- see host-setup/README.md.

.DESCRIPTION
  On some machines, WSL2's automatic Windows<->WSL loopback port-forwarding
  gets stuck for IPv4: a connection to 127.0.0.1 completes its TCP handshake
  but then hangs forever (IPv6 loopback keeps working fine). When that
  happens, Docker Desktop's host.docker.internal gateway hangs too, since it
  also relays through Windows' IPv4 loopback.

  This script routes around the broken hop: it forwards Windows' real LAN IP
  (not loopback) straight to the WSL2 VM's real IP (not loopback), which
  keeps working even when the loopback layer is wedged. It re-detects the
  WSL2 VM's IP every run, since that IP changes on every `wsl --shutdown` /
  restart -- that's why this needs to be re-run periodically rather than
  configured once.

  Run manually any time you restart WSL2 mid-session. setup-portproxy.ps1
  registers a Scheduled Task that runs this automatically at every logon.

.NOTES
  Requires an elevated (Administrator) PowerShell session.
#>

param(
    # host listen port -> WSL connect port. Add more pairs here if you need
    # to reach additional services this way (keep host-setup/setup-portproxy.ps1's
    # -ListenPorts in sync so the firewall rule exists for any new port).
    [hashtable]$PortMap = @{ 8081 = 8080 }
)

$ErrorActionPreference = "Stop"

function Get-HostLanIP {
    # A real, LAN-facing IPv4 address -- NOT loopback, NOT the Docker Desktop
    # / WSL virtual adapters. Picks the first candidate on a physical/Wi-Fi
    # adapter that's actually up.
    $candidates = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $addr = $_
        $addr.IPAddress -notlike "127.*" -and
        $addr.IPAddress -notlike "169.254.*" -and
        $(
            $adapter = Get-NetAdapter -InterfaceIndex $addr.InterfaceIndex -ErrorAction SilentlyContinue
            $adapter -and $adapter.Status -eq "Up" -and
            $adapter.InterfaceDescription -notmatch "WSL|Docker|Hyper-V|Loopback"
        )
    }
    if (-not $candidates) { throw "Could not find a real LAN IPv4 address on this machine." }
    return ($candidates | Select-Object -First 1).IPAddress
}

$hostIp = Get-HostLanIP
$wslIp = (wsl.exe hostname -I 2>$null).Trim().Split(' ')[0]

if (-not $wslIp) {
    throw "Could not determine the WSL2 VM's IP -- is WSL2 running? (try 'wsl.exe' first to start it)"
}

Write-Host "Host LAN IP: $hostIp"
Write-Host "WSL2 VM IP:  $wslIp"

foreach ($listenPort in $PortMap.Keys) {
    $connectPort = $PortMap[$listenPort]

    # Idempotent: delete any stale mapping for this listen port/address first.
    # The WSL IP changing every restart is expected, not an error.
    netsh interface portproxy delete v4tov4 listenaddress=$hostIp listenport=$listenPort *>$null

    netsh interface portproxy add v4tov4 `
        listenaddress=$hostIp listenport=$listenPort `
        connectaddress=$wslIp connectport=$connectPort | Out-Null

    Write-Host "Forwarding ${hostIp}:${listenPort} -> ${wslIp}:${connectPort}"
}

netsh interface portproxy show v4tov4
