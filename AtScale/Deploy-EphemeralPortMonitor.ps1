<#
.SYNOPSIS
    Deploys an ephemeral port monitoring script and scheduled task to an Azure VM.

.DESCRIPTION
    Run this script via Azure CLI (Invoke-AzVMRunCommand / az vm run-command invoke)
    to install a recurring monitoring script on the target VM. It:
      1. Writes a monitoring script to C:\Monitoring\EphemeralPortMonitor.ps1
      2. Registers a scheduled task that runs as SYSTEM at system startup (no logon required)
      3. The task triggers the monitoring script, which loops every 60 seconds collecting:
         - Total ephemeral port usage (TCP connections in the dynamic port range)
         - Top 10 processes by port consumption
         - Writes timestamped entries to C:\Monitoring\Logs\EphemeralPortUsage.csv

.EXAMPLE
    # Azure CLI
    az vm run-command invoke `
        --resource-group MyRG `
        --name MyVM `
        --command-id RunPowerShellScript `
        --scripts @Deploy-EphemeralPortMonitor.ps1

    # Azure PowerShell
    Invoke-AzVMRunCommand `
        -ResourceGroupName 'MyRG' `
        -VMName 'MyVM' `
        -CommandId 'RunPowerShellScript' `
        -ScriptPath '.\Deploy-EphemeralPortMonitor.ps1'
#>

# ── Configuration ────────────────────────────────────────────────────────────
$MonitoringDir = 'C:\Monitoring'
$LogDir        = Join-Path $MonitoringDir 'Logs'
$ScriptPath    = Join-Path $MonitoringDir 'EphemeralPortMonitor.ps1'
$TaskName      = 'EphemeralPortMonitor'

# ── Ensure directories exist ─────────────────────────────────────────────────
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

# ── Write the monitoring script to disk ──────────────────────────────────────
$MonitorScript = @'
<#
.SYNOPSIS
    Collects ephemeral port usage every 60 seconds and logs results.
#>

$LogDir  = 'C:\Monitoring\Logs'
$LogFile = Join-Path $LogDir 'EphemeralPortUsage.csv'

# Ensure log directory exists
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

# Write CSV header if file does not exist
if (-not (Test-Path $LogFile)) {
    $header = 'Timestamp,EphemeralRangeStart,EphemeralRangeEnd,MaxPorts,TotalPortsInUse,UsagePercent,Rank,PID,ProcessName,PortCount'
    Set-Content -Path $LogFile -Value $header -Encoding UTF8
}

# Determine the dynamic port range configured on this machine
try {
    $portOutput = netsh int ipv4 show dynamicport tcp
    $startPort  = [int]($portOutput | Select-String 'Start Port\s*:\s*(\d+)').Matches.Groups[1].Value
    $portCount  = [int]($portOutput | Select-String 'Number of Ports\s*:\s*(\d+)').Matches.Groups[1].Value
    $endPort    = $startPort + $portCount - 1
} catch {
    # Default Windows dynamic range
    $startPort = 49152
    $endPort   = 65535
}

while ($true) {
    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

        # Get all TCP connections
        $tcpConnections = Get-NetTCPConnection -ErrorAction SilentlyContinue

        # Filter to ephemeral port range (local port)
        $ephemeralConnections = $tcpConnections | Where-Object {
            $_.LocalPort -ge $startPort -and $_.LocalPort -le $endPort
        }

        $totalEphemeral  = ($ephemeralConnections | Measure-Object).Count
        $maxPorts         = $portCount
        $usagePercent     = if ($maxPorts -gt 0) { [math]::Round(($totalEphemeral / $maxPorts) * 100, 2) } else { 0 }

        # Group by owning process and get top 10
        $rank = 0
        $csvLines = $ephemeralConnections |
            Group-Object -Property OwningProcess |
            Sort-Object -Property Count -Descending |
            Select-Object -First 10 |
            ForEach-Object {
                $rank++
                $procId   = $_.Name
                $procName = try { (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName } catch { 'Unknown' }
                if (-not $procName) { $procName = 'Unknown' }
                # Escape any commas/quotes in process name for CSV safety
                $safeName = $procName -replace '"', '""'
                '{0},{1},{2},{3},{4},{5},{6},{7},"{8}",{9}' -f `
                    $timestamp, $startPort, $endPort, $maxPorts, `
                    $totalEphemeral, $usagePercent, $rank, $procId, $safeName, $_.Count
            }

        # If no ephemeral connections, still log a summary row
        if (-not $csvLines) {
            $csvLines = '{0},{1},{2},{3},{4},{5},,,,' -f `
                $timestamp, $startPort, $endPort, $maxPorts, $totalEphemeral, $usagePercent
        }

        # Append CSV rows to log file
        $csvLines | Add-Content -Path $LogFile -Encoding UTF8 -ErrorAction SilentlyContinue

        # Roll the log if it exceeds 50 MB
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 50MB)) {
            $archiveName = Join-Path $LogDir ("EphemeralPortUsage_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Move-Item -Path $LogFile -Destination $archiveName -Force
            # Re-create header in the new file
            $header = 'Timestamp,EphemeralRangeStart,EphemeralRangeEnd,MaxPorts,TotalPortsInUse,UsagePercent,Rank,PID,ProcessName,PortCount'
            Set-Content -Path $LogFile -Value $header -Encoding UTF8
        }
    } catch {
        $errMsg = "[{0}] ERROR: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message
        Add-Content -Path $LogFile -Value $errMsg -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 60
}
'@

Set-Content -Path $ScriptPath -Value $MonitorScript -Force -Encoding UTF8
Write-Output "Monitoring script written to $ScriptPath"

# ── Create / update the scheduled task ───────────────────────────────────────

# Remove existing task if present
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "Removed existing scheduled task '$TaskName'."
}

# Action: run PowerShell hidden, executing the monitoring script
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""

# Trigger: at system startup (runs with or without user logged on)
$trigger = New-ScheduledTaskTrigger -AtStartup

# Principal: run as SYSTEM with highest privileges
$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

# Settings: allow the task to run indefinitely; restart on failure
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 0) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Monitors ephemeral TCP port usage every 60 seconds and logs top consumers.' |
    Out-Null

Write-Output "Scheduled task '$TaskName' registered (runs as SYSTEM at startup)."

# ── Start the task immediately so monitoring begins now ──────────────────────
Start-ScheduledTask -TaskName $TaskName
Write-Output "Task started. Logs will appear in $LogDir\EphemeralPortUsage.csv"
