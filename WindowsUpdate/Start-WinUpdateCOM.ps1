<#
.SYNOPSIS
    Initiates Windows Update using COM objects while respecting Intune policies.

.DESCRIPTION
    This script uses the Microsoft.Update.Session COM object to search for and install
    Windows updates. It does not override any Intune or Group Policy settings and works
    within the existing update management framework.

.PARAMETER AutoRestart
    If specified, automatically restarts the computer if updates require it.

.PARAMETER RestartDelaySeconds
    Number of seconds to wait before restarting (default: 60). Only applies when -AutoRestart is used.

.EXAMPLE
    .\Start-WinUpdateCOM.ps1
    Searches for updates and installs them if available.

.EXAMPLE
    .\Start-WinUpdateCOM.ps1 -AutoRestart
    Searches for, installs updates, and automatically restarts if required (60 second delay).

.EXAMPLE
    .\Start-WinUpdateCOM.ps1 -AutoRestart -RestartDelaySeconds 120
    Searches for, installs updates, and automatically restarts with a 2 minute delay.

.NOTES
    Author: Created on November 10, 2025
    Requirements: Must be run with administrative privileges
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [switch]$AutoRestart,
    
    [Parameter(Mandatory=$false)]
    [int]$RestartDelaySeconds = 60
)

# Requires -RunAsAdministrator

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

try {
    Write-Log "Starting Windows Update process using COM objects..."
    
    # Create Microsoft Update Session
    Write-Log "Creating Update Session..."
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    
    # Create Update Searcher
    Write-Log "Creating Update Searcher..."
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    
    # The searcher will respect existing policies (Intune, GPO, etc.)
    Write-Log "Searching for updates (respecting existing policies)..."
    $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    
    if ($searchResult.Updates.Count -eq 0) {
        Write-Log "No updates available to install." "INFO"
        exit 0
    }
    
    Write-Log "Found $($searchResult.Updates.Count) update(s) available." "INFO"
    
    # Display available updates
    foreach ($update in $searchResult.Updates) {
        Write-Log "  - $($update.Title)" "INFO"
    }
    
    # Create collection of updates to install
    $updatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    
    foreach ($update in $searchResult.Updates) {
        if ($update.EulaAccepted -eq $false) {
            Write-Log "Accepting EULA for: $($update.Title)" "INFO"
            $update.AcceptEula()
        }
        
        # Add update to collection
        $updatesToInstall.Add($update) | Out-Null
    }
    
    if ($updatesToInstall.Count -eq 0) {
        Write-Log "No updates to install after filtering." "INFO"
        exit 0
    }
    
    # Create Update Downloader
    Write-Log "Downloading updates..."
    $downloader = $updateSession.CreateUpdateDownloader()
    $downloader.Updates = $updatesToInstall
    $downloadResult = $downloader.Download()
    
    if ($downloadResult.ResultCode -eq 2) {
        Write-Log "Updates downloaded successfully." "INFO"
    } else {
        Write-Log "Download completed with result code: $($downloadResult.ResultCode)" "WARNING"
    }
    
    # Create Update Installer
    Write-Log "Installing updates..."
    $installer = $updateSession.CreateUpdateInstaller()
    $installer.Updates = $updatesToInstall
    $installResult = $installer.Install()
    
    # Display results
    Write-Log "Installation completed with result code: $($installResult.ResultCode)" "INFO"
    
    # ResultCode: 2 = Succeeded, 3 = Succeeded with errors, 4 = Failed, 5 = Aborted
    switch ($installResult.ResultCode) {
        2 { Write-Log "All updates installed successfully." "INFO" }
        3 { Write-Log "Updates installed with some errors." "WARNING" }
        4 { Write-Log "Update installation failed." "ERROR" }
        5 { Write-Log "Update installation was aborted." "WARNING" }
    }
    
    # Check if reboot is required
    if ($installResult.RebootRequired) {
        Write-Log "A system reboot is required to complete the installation." "WARNING"
        
        if ($AutoRestart) {
            Write-Log "AutoRestart is enabled. System will restart in $RestartDelaySeconds seconds..." "WARNING"
            Write-Log "Press Ctrl+C to cancel the restart." "WARNING"
            
            # Countdown
            for ($i = $RestartDelaySeconds; $i -gt 0; $i--) {
                Write-Host "`rRestarting in $i seconds... " -NoNewline -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            Write-Host ""
            
            Write-Log "Initiating system restart..." "WARNING"
            Restart-Computer -Force
        } else {
            Write-Log "Use the -AutoRestart switch to automatically restart the computer." "INFO"
        }
    }
    
    # Detailed results for each update
    Write-Log "Detailed results:" "INFO"
    for ($i = 0; $i -lt $updatesToInstall.Count; $i++) {
        $update = $updatesToInstall.Item($i)
        $result = $installResult.GetUpdateResult($i)
        Write-Log "  - $($update.Title): ResultCode=$($result.ResultCode)" "INFO"
    }
    
} catch {
    Write-Log "An error occurred: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack Trace: $($_.Exception.StackTrace)" "ERROR"
    exit 1
}

Write-Log "Windows Update process completed."
