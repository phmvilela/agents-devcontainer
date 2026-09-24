<#
.SYNOPSIS
  One-time setup for the WSL2 IPv4-loopback-forwarding-bug workaround: opens
  the Windows Firewall for the portproxy listen port(s) and schedules
  refresh-wsl-portproxy.ps1 to re-run at every logon.

.DESCRIPTION
  See refresh-wsl-portproxy.ps1 and host-setup/README.md for the full story.
  Run this ONCE (re-running is safe -- everything here is idempotent). After
  this, the portproxy mapping self-heals at every Windows logon.

  If you `wsl --shutdown` mid-session without logging out, the WSL2 VM gets a
  new IP and the mapping goes stale until next logon -- either re-run
  refresh-wsl-portproxy.ps1 directly, or:
    Start-ScheduledTask -TaskName pgcyan-wsl-portproxy-refresh

.NOTES
  Requires an elevated (Administrator) PowerShell session.
#>

param(
    [int[]]$ListenPorts = @(8081),
    [string]$TaskName = "pgcyan-wsl-portproxy-refresh"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RefreshScript = Join-Path $ScriptDir "refresh-wsl-portproxy.ps1"

if (-not (Test-Path $RefreshScript)) {
    throw "Expected refresh-wsl-portproxy.ps1 next to this script at $RefreshScript"
}

foreach ($port in $ListenPorts) {
    $ruleName = "pgcyan-wsl-portproxy-$port"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $port | Out-Null
        Write-Host "Added firewall allow rule for TCP $port ($ruleName)."
    } else {
        Write-Host "Firewall allow rule for TCP $port already exists ($ruleName)."
    }
}

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$RefreshScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName' to refresh the portproxy mapping at every logon."
Write-Host "Running it once now to set up the current session..."
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
Get-ScheduledTaskInfo -TaskName $TaskName | Format-List TaskName, LastRunTime, LastTaskResult
