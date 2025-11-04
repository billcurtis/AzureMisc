<#
.SYNOPSIS
    Simple Windows Image Repair and Update Script

.DESCRIPTION
    This script performs two essential maintenance tasks:
    1. Runs Repair-WindowsImage -Online -RestoreHealth to fix Windows image corruption
    2. Checks for and installs Windows Updates (excluding driver updates)
    3. Logs output to a local file in C:\temp
    4. Restarts the computer if required after updates or repairs
    


.REQUIREMENTS
    - PowerShell 5.1 or later
    - Administrator privileges
    - Internet connectivity for Windows Updates

.NOTES
    Version 1.0 - Simplified maintenance script
#>

# Initialize error handling
$ErrorActionPreference = "Continue"

# Initialize logging
$LogPath = "C:\temp"
$LogFile = Join-Path $LogPath "WindowsImageRepair-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# Create log directory if it doesn't exist
if (-not (Test-Path $LogPath)) {
    try {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
        Write-Output "Created log directory: $LogPath"
    }
    catch {
        Write-Output "Warning: Failed to create log directory: $($_.Exception.Message)"
        $LogFile = $null  # Disable file logging if we can't create the directory
    }
}

# Initialize variables
$imageRepaired = $false
$updatesInstalled = @()
$updatesFound = @()
$updatesFailed = @()
$rebootRequired = $false

# Simple logging function for console and file output
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { "Unknown" }
    $logEntry = "[$timestamp] [$computerName] [$Level] $Message"
    
    # Write to console
    Write-Output $logEntry
    
    # Write to log file if available
    if ($LogFile) {
        try {
            Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {
            # If file logging fails, continue with console only
        }
    }
}

Write-Log "========================================" "INFO"
Write-Log "Windows Image Repair and Update Script" "INFO"
Write-Log "========================================" "INFO"
if ($LogFile) {
    Write-Log "Log file: $LogFile" "INFO"
} else {
    Write-Log "File logging disabled - console output only" "WARNING"
}

# Step 1: Run Windows Image Repair
Write-Log "Running Repair-WindowsImage -Online -RestoreHealth..." "INFO"
try {
    $repairResult = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop
    Write-Log "Image repair completed successfully" "INFO"
    Write-Log "Repair Result: ImageHealthState = $($repairResult.ImageHealthState)" "INFO"
    Write-Log "Restart Needed: $($repairResult.RestartNeeded)" "INFO"
    $imageRepaired = $true
    
    if ($repairResult.RestartNeeded) {
        Write-Log "WARNING: System restart is required after image repair" "WARNING"
        $rebootRequired = $true
    }
}
catch {
    Write-Log "Image repair failed: $($_.Exception.Message)" "ERROR"
    $imageRepaired = $false
}

# Step 2: Run Windows Update
Write-Log "Checking for Windows Updates..." "INFO"
try {
    # Create Windows Update session
    $UpdateSession = New-Object -ComObject Microsoft.Update.Session
    $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
    
    Write-Log "Searching for available updates..." "INFO"
    $SearchResult = $UpdateSearcher.Search("IsInstalled=0 and IsHidden=0")
    
    Write-Log "Found $($SearchResult.Updates.Count) total updates to evaluate" "INFO"
    
    if ($SearchResult.Updates.Count -gt 0) {
        # Filter out driver updates
        $UpdatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        
        foreach ($Update in $SearchResult.Updates) {
            # Skip driver updates but include everything else
            $isDriverUpdate = $false
            foreach ($Category in $Update.Categories) {
                if ($Category.Name -like "*Driver*" -or $Category.Name -like "*Hardware*") {
                    $isDriverUpdate = $true
                    break
                }
            }
            
            if (-not $isDriverUpdate) {
                Write-Log "Selected for installation: $($Update.Title)" "INFO"
                $UpdatesToInstall.Add($Update) | Out-Null
                $updatesFound += @{
                    Title = $Update.Title
                    Size = [math]::Round($Update.MaxDownloadSize / 1MB, 2)
                    Description = $Update.Description
                }
            } else {
                Write-Log "Skipping driver update: $($Update.Title)" "INFO"
            }
        }
        
        if ($UpdatesToInstall.Count -gt 0) {
            Write-Log "Installing $($UpdatesToInstall.Count) updates..." "INFO"
            
            # Download updates
            $Downloader = $UpdateSession.CreateUpdateDownloader()
            $Downloader.Updates = $UpdatesToInstall
            $DownloadResult = $Downloader.Download()
            
            if ($DownloadResult.ResultCode -eq 2) {
                Write-Log "Updates downloaded successfully" "INFO"
                
                # Install updates
                $Installer = $UpdateSession.CreateUpdateInstaller()
                $Installer.Updates = $UpdatesToInstall
                $InstallResult = $Installer.Install()
                
                # Process results
                for ($i = 0; $i -lt $UpdatesToInstall.Count; $i++) {
                    $update = $UpdatesToInstall.Item($i)
                    $result = $InstallResult.GetUpdateResult($i)
                    
                    if ($result.ResultCode -eq 2) {
                        Write-Log "Successfully installed: $($update.Title)" "INFO"
                        $updatesInstalled += @{
                            Title = $update.Title
                            ResultCode = $result.ResultCode
                            HResult = $result.HResult
                        }
                    } else {
                        Write-Log "Failed to install: $($update.Title) (Result: $($result.ResultCode))" "ERROR"
                        $updatesFailed += @{
                            Title = $update.Title
                            ResultCode = $result.ResultCode
                            HResult = $result.HResult
                        }
                    }
                }
                
                if ($InstallResult.RebootRequired) {
                    Write-Log "System restart is required after installing updates" "WARNING"
                    $rebootRequired = $true
                }
                
                Write-Log "Update installation completed" "INFO"
                Write-Log "Updates installed: $($updatesInstalled.Count)" "INFO"
                Write-Log "Updates failed: $($updatesFailed.Count)" "INFO"
            } else {
                Write-Log "Failed to download updates (Result: $($DownloadResult.ResultCode))" "ERROR"
            }
        } else {
            Write-Log "No non-driver updates available for installation" "INFO"
        }
    } else {
        Write-Log "No updates available" "INFO"
    }
}
catch {
    Write-Log "Windows Update check/install failed: $($_.Exception.Message)" "ERROR"
}

# Final Summary
Write-Log "========================================" "INFO"
Write-Log "Script Execution Summary" "INFO"
Write-Log "========================================" "INFO"
Write-Log "Image Repair Completed: $imageRepaired" "INFO"
Write-Log "Updates Found: $($updatesFound.Count)" "INFO"
Write-Log "Updates Installed: $($updatesInstalled.Count)" "INFO"
Write-Log "Updates Failed: $($updatesFailed.Count)" "INFO"
Write-Log "Reboot Required: $rebootRequired" "INFO"

if ($rebootRequired) {
    Write-Log "IMPORTANT: System restart is required to complete the maintenance" "WARNING"
    Restart-Computer -Force -Confirm:$false 
}

Write-Log "Script completed successfully" "INFO"
