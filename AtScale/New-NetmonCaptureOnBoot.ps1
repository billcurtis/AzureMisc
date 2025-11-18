<#
.SYNOPSIS
    Creates a scheduled task to start Network Monitor capture on system boot.

.DESCRIPTION
    This script creates a scheduled task that automatically starts a netsh trace (network packet capture)
    when the system boots. The capture will run continuously and save to a specified location.

.EXAMPLE
    .\New-NetmonCaptureOnBoot.ps1
#>

[CmdletBinding()]
param()

# Requires elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Configuration
$taskName = "NetmonCaptureOnBoot"
$captureLocation = "C:\NetmonCaptures"
$maxCaptureSize = 1024  # MB

# Create capture directory if it doesn't exist
if (-not (Test-Path -Path $captureLocation)) {
    Write-Host "Creating capture directory: $captureLocation" -ForegroundColor Cyan
    New-Item -Path $captureLocation -ItemType Directory -Force | Out-Null
}

# Define the capture start command
$captureFile = Join-Path -Path $captureLocation -ChildPath "boot-capture.etl"
$startCaptureCommand = "netsh trace start capture=yes tracefile=`"$captureFile`" maxsize=$maxCaptureSize overwrite=yes persistent=yes"

# Define the PowerShell script that will be executed by the scheduled task
$scriptContent = @"
# Network Monitor Capture Startup Script
`$logFile = Join-Path -Path '$captureLocation' -ChildPath 'netmon-startup.log'
`$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

try {
    # Log start
    Add-Content -Path `$logFile -Value "`n=== Netmon Capture Started at `$timestamp ==="
    
    # Start the network trace
    `$result = & netsh trace start capture=yes tracefile='$captureFile' maxsize=$maxCaptureSize overwrite=yes persistent=yes 2>&1
    
    # Log result
    Add-Content -Path `$logFile -Value "Result: `$result"
    
    if (`$LASTEXITCODE -eq 0) {
        Add-Content -Path `$logFile -Value "Status: SUCCESS"
    } else {
        Add-Content -Path `$logFile -Value "Status: FAILED with exit code `$LASTEXITCODE"
    }
}
catch {
    Add-Content -Path `$logFile -Value "Error: `$(`$_.Exception.Message)"
}
"@

# Save the script to disk
$scriptPath = Join-Path -Path $captureLocation -ChildPath "Start-NetmonCapture.ps1"
Write-Host "Creating capture script: $scriptPath" -ForegroundColor Cyan
$scriptContent | Out-File -FilePath $scriptPath -Encoding UTF8 -Force

# Create the scheduled task
Write-Host "Creating scheduled task: $taskName" -ForegroundColor Cyan

# Define task action
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

# Define task trigger (at system startup)
$trigger = New-ScheduledTaskTrigger -AtStartup

# Define task settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)  # No time limit

# Define principal (run as SYSTEM with highest privileges)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Register the scheduled task
try {
    $task = Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description "Automatically starts network packet capture on system boot" `
        -Force
    
    Write-Host "`nScheduled task created successfully!" -ForegroundColor Green
    Write-Host "Task Name: $taskName" -ForegroundColor Yellow
    Write-Host "Capture Location: $captureLocation" -ForegroundColor Yellow
    Write-Host "Capture File: $captureFile" -ForegroundColor Yellow
    Write-Host "Max Capture Size: $maxCaptureSize MB" -ForegroundColor Yellow
    
    Write-Host "`nThe network capture will start automatically on next boot." -ForegroundColor Cyan
    Write-Host "To stop the capture manually, run: netsh trace stop" -ForegroundColor Cyan
    Write-Host "To disable the scheduled task, run: Disable-ScheduledTask -TaskName '$taskName'" -ForegroundColor Cyan
    Write-Host "To remove the scheduled task, run: Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to create scheduled task: $($_.Exception.Message)"
    exit 1
}

# Display the task details
Write-Host "`nScheduled Task Details:" -ForegroundColor Cyan
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName, State, TaskPath | Format-List
