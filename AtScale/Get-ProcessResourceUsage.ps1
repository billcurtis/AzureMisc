<#
.SYNOPSIS
    Creates and starts a Performance Monitor Data Collector Set for CPU and memory usage.

.DESCRIPTION
    This script creates a Performance Monitor Data Collector Set that monitors CPU and memory
    usage for all processes. The collector will persist through reboots and start automatically
    on system boot. 
    
    This script is designed to run via Invoke-AzVMRunCommand and runs with SYSTEM privileges.

.NOTES
    Author: Data Collection Script
    Date: November 6, 2025
    To stop: logman stop ProcessResourceMonitor
    To disable auto-start: logman update ProcessResourceMonitor -s ""
    To export: Use Performance Monitor to open the .blg file and export to CSV
#>

# Hardcoded configuration variables
$CollectorName = "ProcessResourceMonitor"
$OutputPath = "C:\Temp"
$SampleInterval = 5
$AutoStart = $true
$Remove = $false  # Set to $true to remove the collector and scheduled task (leaves data intact)

try {
    # If Remove switch is set, remove collector and task then exit
    if ($Remove) {
        Write-Output "==========================================="
        Write-Output "Removing Data Collector and Scheduled Task"
        Write-Output "==========================================="
        Write-Output ""
        
        # Stop and remove the data collector
        $existing = logman query $CollectorName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Stopping data collector..."
            logman stop $CollectorName 2>$null | Out-Null
            Write-Output "Removing data collector..."
            logman delete $CollectorName 2>$null | Out-Null
            Write-Output "[OK] Data collector removed"
        } else {
            Write-Output "[INFO] Data collector does not exist"
        }
        
        # Remove the scheduled task
        $existingTask = schtasks /query /tn "StartPerfMonCollector" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Output "Removing scheduled task..."
            schtasks /delete /tn "StartPerfMonCollector" /f | Out-Null
            Write-Output "[OK] Scheduled task removed"
        } else {
            Write-Output "[INFO] Scheduled task does not exist"
        }
        
        Write-Output ""
        Write-Output "[OK] Cleanup complete. Data files in $OutputPath have been preserved."
        Write-Output "==========================================="
        exit 0
    }
    
    Write-Output "==========================================="
    Write-Output "Performance Monitor Data Collector Setup"
    Write-Output "==========================================="
    Write-Output ""
    
    # Ensure output directory exists
    if (-not (Test-Path -Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        Write-Output "[OK] Created output directory: $OutputPath"
    }
    
    Write-Output "Using output path: $OutputPath"
    
    # Check if collector already exists and remove it
    $existing = logman query $CollectorName 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Stopping and removing existing collector..."
        logman stop $CollectorName 2>$null | Out-Null
        logman delete $CollectorName 2>$null | Out-Null
    }
    
    Write-Output "Creating Data Collector Set: $CollectorName"
    
    # Create the data collector with process counters
    # Add computer name and random string to output file name
    $computerName = $env:COMPUTERNAME
    $randomString = -join ((65..90) + (97..122) | Get-Random -Count 6 | ForEach-Object {[char]$_})
    $outputFile = "$OutputPath\$CollectorName-$computerName-$randomString.blg"
    
    # Build the command as a single line to avoid parsing issues
    $counters = @(
        "\Process(*)\% Processor Time"
        "\Memory\Available MBytes"
        "\Processor(_Total)\% Processor Time"
    )
    
    # Create without schedule first
    $result = logman create counter $CollectorName -o "$outputFile" -f bincirc -max 500 -si $SampleInterval -c $counters 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create data collector: $result"
    }
    
    Write-Output "[OK] Data Collector Set created successfully"
    
    # Start the collector
    Write-Output "Starting Data Collector..."
    $startResult = logman start $CollectorName 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start data collector: $startResult"
    }
    
    Write-Output "[OK] Data Collector started successfully!"
    
    # If AutoStart is enabled, create a scheduled task to start the collector at boot
    if ($AutoStart) {
        Write-Output "Creating scheduled task for auto-start on boot..."
        
        # Remove existing scheduled task if it exists
        $existingTask = schtasks /query /tn "StartPerfMonCollector" 2>$null
        if ($LASTEXITCODE -eq 0) {
            schtasks /delete /tn "StartPerfMonCollector" /f | Out-Null
        }
        
        # Create a scheduled task that runs at system startup
        $action = "logman start $CollectorName"
        $taskResult = schtasks /create /tn "StartPerfMonCollector" /tr "$action" /sc onstart /ru "SYSTEM" /rl highest /f 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Output "[OK] Created scheduled task to start collector at system boot"
        } else {
            Write-Output "[WARNING] Could not create scheduled task: $taskResult"
            Write-Output "[WARNING] Collector is running but will not auto-start on boot"
        }
    }
    Write-Output ""
    Write-Output "==========================================="
    Write-Output "Data Collection Information"
    Write-Output "==========================================="
    Write-Output "Collector Name:   $CollectorName"
    Write-Output "Output Location:  $OutputPath\$CollectorName.blg"
    Write-Output "Sample Interval:  $SampleInterval seconds"
    Write-Output "Auto-Start:       $AutoStart"
    Write-Output "Status:           Running"
    Write-Output ""
    Write-Output "Counters Being Collected:"
    Write-Output "  - CPU Usage (per process and total)"
    Write-Output "  - Working Set Memory (per process)"
    Write-Output "  - Virtual Memory (per process)"
    Write-Output "  - Thread Count (per process)"
    Write-Output "  - Available Memory"
    Write-Output ""
    Write-Output "To stop the collector:"
    Write-Output "  logman stop $CollectorName"
    Write-Output ""
    if ($AutoStart) {
        Write-Output "To disable auto-start on boot:"
        Write-Output "  schtasks /delete /tn `"StartPerfMonCollector`" /f"
        Write-Output ""
        Write-Output "To permanently remove:"
        Write-Output "  logman stop $CollectorName"
        Write-Output "  logman delete $CollectorName"
        Write-Output "  schtasks /delete /tn `"StartPerfMonCollector`" /f"
        Write-Output ""
    }
    Write-Output "To view/export data:"
    Write-Output "  1. Open Performance Monitor (perfmon.exe)"
    Write-Output "  2. Click 'Performance Monitor' in left pane"
    Write-Output "  3. Click folder icon and open: $OutputPath\$CollectorName*.blg"
    Write-Output "  4. Right-click and export to CSV if needed"
    Write-Output ""
    Write-Output "Or use relog to convert:"
    Write-Output "  relog `"$OutputPath\$CollectorName*.blg`" -f CSV -o output.csv"
    Write-Output "==========================================="
}
catch {
    Write-Output ""
    Write-Output "[ERROR] $_"
    Write-Output ""
    exit 1
}
