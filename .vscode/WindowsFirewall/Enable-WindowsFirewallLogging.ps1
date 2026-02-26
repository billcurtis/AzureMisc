<#
.SYNOPSIS
    Enables Windows Firewall logging and outputs the current logging configuration.

.DESCRIPTION
    This script is designed to be executed via the Azure Portal VM Run Command.
    It enables Windows Firewall logging (allowed and blocked connections) for all
    firewall profiles (Domain, Private, Public), sets the log size to 32 MB,
    and outputs the resulting configuration along with the last 50 log entries
    if the log file already exists.

.NOTES
    Requires: Administrator privileges (Run Command executes as SYSTEM)
    Compatibility: Windows Server 2012 R2+, Windows 10+
    Log Location: %SystemRoot%\System32\LogFiles\Firewall\pfirewall.log

.EXAMPLE
    # Execute via Azure Portal > VM > Run Command > RunPowerShellScript
    # Paste entire script content and click Run
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# ── Helper ──────────────────────────────────────────────────────────────────────
function Write-Section ([string]$Title) {
    Write-Output "`n$('=' * 70)"
    Write-Output " $Title"
    Write-Output "$('=' * 70)"
}

# ── 1. Capture current state ────────────────────────────────────────────────────
Write-Section 'CURRENT FIREWALL LOGGING CONFIGURATION (BEFORE)'

try {
    $profilesBefore = Get-NetFirewallProfile -ErrorAction Stop |
        Select-Object Name, Enabled, LogAllowed, LogBlocked, LogFileName, LogMaxSizeKilobytes
    $profilesBefore | Format-Table -AutoSize | Out-String | Write-Output
} catch {
    Write-Output "WARNING: Unable to query current firewall profiles: $_"
}

# ── 2. Enable logging on all profiles ───────────────────────────────────────────
Write-Section 'ENABLING FIREWALL LOGGING'

$profiles = @('Domain', 'Private', 'Public')
$logSizeKB = 32768  # 32 MB

foreach ($profile in $profiles) {
    try {
        Set-NetFirewallProfile -Profile $profile `
            -LogAllowed True `
            -LogBlocked True `
            -LogMaxSizeKilobytes $logSizeKB `
            -ErrorAction Stop

        Write-Output "[SUCCESS] $profile profile - logging enabled (Allowed=True, Blocked=True, MaxSize=${logSizeKB}KB)"
    } catch {
        Write-Output "[ERROR]   $profile profile - failed to enable logging: $_"
    }
}

# ── 3. Verify new state ─────────────────────────────────────────────────────────
Write-Section 'UPDATED FIREWALL LOGGING CONFIGURATION (AFTER)'

try {
    $profilesAfter = Get-NetFirewallProfile -ErrorAction Stop |
        Select-Object Name, Enabled, LogAllowed, LogBlocked, LogFileName, LogMaxSizeKilobytes
    $profilesAfter | Format-Table -AutoSize | Out-String | Write-Output
} catch {
    Write-Output "WARNING: Unable to query firewall profiles after update: $_"
}

# ── 4. Show log file status ─────────────────────────────────────────────────────
Write-Section 'LOG FILE STATUS'

$logPath = ($profilesAfter | Select-Object -First 1).LogFileName
if (-not $logPath) {
    $logPath = "$env:SystemRoot\System32\LogFiles\Firewall\pfirewall.log"
}

Write-Output "Log file path : $logPath"

if (Test-Path -Path $logPath) {
    $logFile = Get-Item -Path $logPath
    Write-Output "File exists    : True"
    Write-Output "File size      : $([math]::Round($logFile.Length / 1KB, 2)) KB"
    Write-Output "Last modified  : $($logFile.LastWriteTime)"

    # ── 5. Output last 50 log entries ────────────────────────────────────────────
    Write-Section 'LAST 50 FIREWALL LOG ENTRIES'

    try {
        $lines = Get-Content -Path $logPath -Tail 50 -ErrorAction Stop
        if ($lines.Count -eq 0) {
            Write-Output "(Log file is empty - entries will appear after network activity)"
        } else {
            $lines | ForEach-Object { Write-Output $_ }
        }
    } catch {
        Write-Output "WARNING: Unable to read log file: $_"
    }
} else {
    Write-Output "File exists    : False"
    Write-Output ""
    Write-Output "The log file does not exist yet. It will be created automatically"
    Write-Output "once network traffic is logged. Re-run this script or check the"
    Write-Output "file after a few minutes of network activity."
}

# ── 6. Summary ──────────────────────────────────────────────────────────────────
Write-Section 'SUMMARY'
Write-Output "Firewall logging has been enabled for all profiles (Domain, Private, Public)."
Write-Output "Both ALLOWED and BLOCKED connections will be recorded."
Write-Output "Max log file size: $($logSizeKB / 1024) MB"
Write-Output "Log location: $logPath"
Write-Output ""
Write-Output "To view logs later, use:"
Write-Output "  Get-Content -Path '$logPath' -Tail 100"
Write-Output ""
Write-Output "To disable logging, run:"
Write-Output "  Set-NetFirewallProfile -Profile Domain,Private,Public -LogAllowed False -LogBlocked False"
Write-Output ""
