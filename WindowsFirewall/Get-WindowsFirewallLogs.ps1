<#
.SYNOPSIS
    Collects Windows Firewall logging of denied and accepted connections.

.DESCRIPTION
    This script parses Windows Firewall log files to extract information about
    denied and accepted connections. It can filter by connection type, date range,
    and export results to CSV format.

.PARAMETER LogPath
    Path to the Windows Firewall log file. Defaults to the standard location.

.PARAMETER ConnectionType
    Filter by connection type: 'All', 'Denied', or 'Accepted'. Default is 'All'.

.PARAMETER StartDate
    Filter connections from this date onwards.

.PARAMETER EndDate
    Filter connections up to this date.

.PARAMETER ExportPath
    Optional path to export results to CSV file.

.PARAMETER Top
    Return only the top N results. Default is all results.

.EXAMPLE
    .\Get-WindowsFirewallLogs.ps1 -EnableLogging
    Enables Windows Firewall logging for all profiles (requires administrator privileges).

.EXAMPLE
    .\Get-WindowsFirewallLogs.ps1 -DisableLogging
    Disables Windows Firewall logging for all profiles (requires administrator privileges).

.EXAMPLE
    .\Get-WindowsFirewallLogs.ps1
    Collects all firewall log entries.

.EXAMPLE
    .\Get-WindowsFirewallLogs.ps1 -ConnectionType Denied -Top 100
    Collects the top 100 denied connections.

.EXAMPLE
    .\Get-WindowsFirewallLogs.ps1 -StartDate (Get-Date).AddDays(-7) -ExportPath "C:\Logs\firewall.csv"
    Collects all connections from the last 7 days and exports to CSV.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$LogPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'Denied', 'Accepted')]
    [string]$ConnectionType = 'All',

    [Parameter(Mandatory = $false)]
    [datetime]$StartDate,

    [Parameter(Mandatory = $false)]
    [datetime]$EndDate,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath,

    [Parameter(Mandatory = $false)]
    [int]$Top,

    [Parameter(Mandatory = $false)]
    [switch]$EnableLogging,

    [Parameter(Mandatory = $false)]
    [switch]$DisableLogging
)

function Disable-FirewallLogging {
    <#
    .SYNOPSIS
        Disables Windows Firewall logging for all profiles.
    #>
    
    Write-Host "`nDisabling Windows Firewall logging..." -ForegroundColor Yellow
    
    try {
        # Check if running as administrator
        $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if (-not $isAdmin) {
            Write-Error "Administrator privileges required to disable firewall logging."
            Write-Warning "Please run this script as Administrator with the -DisableLogging switch."
            return $false
        }
        
        # Disable logging for all profiles
        $profiles = @('Domain', 'Private', 'Public')
        foreach ($profile in $profiles) {
            Write-Verbose "Disabling logging for $profile profile..."
            Set-NetFirewallProfile -Profile $profile -LogAllowed False -LogBlocked False -ErrorAction Stop
        }
        
        Write-Host "Firewall logging disabled successfully for all profiles." -ForegroundColor Green
        
        return $true
        
    } catch {
        Write-Error "Failed to disable firewall logging: $_"
        return $false
    }
}

function Enable-FirewallLogging {
    <#
    .SYNOPSIS
        Enables Windows Firewall logging for all profiles.
    #>
    
    Write-Host "`nEnabling Windows Firewall logging..." -ForegroundColor Yellow
    
    try {
        # Check if running as administrator
        $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        if (-not $isAdmin) {
            Write-Error "Administrator privileges required to enable firewall logging."
            Write-Warning "Please run this script as Administrator with the -EnableLogging switch."
            return $false
        }
        
        # Enable logging for all profiles
        $profiles = @('Domain', 'Private', 'Public')
        foreach ($profile in $profiles) {
            Write-Verbose "Enabling logging for $profile profile..."
            Set-NetFirewallProfile -Profile $profile -LogAllowed True -LogBlocked True -LogMaxSizeKilobytes 4096 -ErrorAction Stop
        }
        
        Write-Host "Firewall logging enabled successfully for all profiles." -ForegroundColor Green
        $logFile = [Environment]::ExpandEnvironmentVariables((Get-NetFirewallProfile -Profile Domain | Select-Object -ExpandProperty LogFileName))
        Write-Host "Log file location: $logFile" -ForegroundColor Green
        Write-Warning "Note: It may take a few moments for log entries to appear."
        
        return $true
        
    } catch {
        Write-Error "Failed to enable firewall logging: $_"
        return $false
    }
}

function Get-FirewallLogPath {
    <#
    .SYNOPSIS
        Gets the configured firewall log path from the active profile.
    #>
    
    try {
        # Try to get log path from Domain profile first, then Private, then Public
        $profiles = @('Domain', 'Private', 'Public')
        foreach ($profile in $profiles) {
            $logFile = Get-NetFirewallProfile -Profile $profile -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LogFileName
            if ($logFile) {
                # Expand cmd-style %var% environment variables (e.g. %systemroot%)
                $logFile = [Environment]::ExpandEnvironmentVariables($logFile)
                if (Test-Path -Path $logFile) {
                    return $logFile
                }
            }
        }
        
        # If no existing log found, return the first configured path (expanded)
        $logFile = Get-NetFirewallProfile -Profile Domain -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LogFileName
        if ($logFile) {
            return [Environment]::ExpandEnvironmentVariables($logFile)
        }
        
        # Fallback to default location
        return "$env:SystemRoot\System32\LogFiles\Firewall\pfirewall.log"
        
    } catch {
        return "$env:SystemRoot\System32\LogFiles\Firewall\pfirewall.log"
    }
}

function Get-FirewallLogEntries {
    param(
        [string]$Path
    )

    # Check if log file exists
    if (-not (Test-Path -Path $Path)) {
        Write-Warning "Firewall log file not found at: $Path"
        
        # Check if logging is enabled
        $profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        $loggingEnabled = $profiles | Where-Object { $_.LogAllowed -eq $true -or $_.LogBlocked -eq $true }
        
        if (-not $loggingEnabled) {
            Write-Warning "Windows Firewall logging is not enabled."
            Write-Host "`nTo enable logging, run this script with the -EnableLogging switch:" -ForegroundColor Cyan
            Write-Host "  .\Get-WindowsFirewallLogs.ps1 -EnableLogging" -ForegroundColor Cyan
            Write-Host "`nOr enable manually:" -ForegroundColor Yellow
            Write-Host "  Set-NetFirewallProfile -Profile Domain,Private,Public -LogAllowed True -LogBlocked True" -ForegroundColor Yellow
        } else {
            Write-Warning "Logging is enabled but no log entries exist yet. Generate some network traffic and try again."
        }
        
        return $null
    }

    Write-Verbose "Reading firewall log from: $Path"
    
    try {
        $logContent = Get-Content -Path $Path -ErrorAction Stop
        
        # Find the header line (starts with #Fields:)
        $headerLine = $logContent | Where-Object { $_ -match '^#Fields:' } | Select-Object -First 1
        
        if (-not $headerLine) {
            Write-Error "Could not find header line in log file"
            return $null
        }

        # Parse header to get field names
        $fields = $headerLine -replace '^#Fields:\s*', '' -split '\s+'
        
        # Get log entries (skip comment lines)
        $entries = $logContent | Where-Object { $_ -notmatch '^#' -and $_.Trim() -ne '' }
        
        Write-Verbose "Found $($entries.Count) log entries"
        
        # Parse each entry
        $parsedEntries = foreach ($entry in $entries) {
            $values = $entry -split '\s+'
            
            # Create custom object with field names
            $logEntry = [PSCustomObject]@{}
            for ($i = 0; $i -lt $fields.Count; $i++) {
                if ($i -lt $values.Count) {
                    $logEntry | Add-Member -NotePropertyName $fields[$i] -NotePropertyValue $values[$i]
                }
            }
            
            # Add computed properties for better readability
            if ($logEntry.date -and $logEntry.time) {
                try {
                    $logEntry | Add-Member -NotePropertyName 'DateTime' -NotePropertyValue ([datetime]::Parse("$($logEntry.date) $($logEntry.time)"))
                } catch {
                    $logEntry | Add-Member -NotePropertyName 'DateTime' -NotePropertyValue $null
                }
            }
            
            if ($logEntry.action) {
                $actionText = switch ($logEntry.action) {
                    'DROP' { 'Denied' }
                    'ALLOW' { 'Accepted' }
                    default { $logEntry.action }
                }
                $logEntry | Add-Member -NotePropertyName 'ActionText' -NotePropertyValue $actionText
            }
            
            if ($logEntry.protocol) {
                $protocolText = switch ($logEntry.protocol) {
                    '6' { 'TCP' }
                    '17' { 'UDP' }
                    '1' { 'ICMP' }
                    default { $logEntry.protocol }
                }
                $logEntry | Add-Member -NotePropertyName 'ProtocolText' -NotePropertyValue $protocolText
            }
            
            $logEntry
        }
        
        return $parsedEntries
        
    } catch {
        Write-Error "Error reading firewall log: $_"
        return $null
    }
}

# Main script execution

# Handle mutually exclusive switches
if ($EnableLogging -and $DisableLogging) {
    Write-Error "Cannot use both -EnableLogging and -DisableLogging switches at the same time."
    exit 1
}

# Handle EnableLogging switch
if ($EnableLogging) {
    $enabled = Enable-FirewallLogging
    if (-not $enabled) {
        exit 1
    }
    Write-Host "\nWaiting for log entries to be generated..." -ForegroundColor Yellow
    Write-Host "Generate some network traffic and run the script again without -EnableLogging to view logs.\n" -ForegroundColor Yellow
    exit 0
}

# Handle DisableLogging switch
if ($DisableLogging) {
    $disabled = Disable-FirewallLogging
    if (-not $disabled) {
        exit 1
    }
    exit 0
}

Write-Host "Collecting Windows Firewall logs..." -ForegroundColor Cyan

# Determine log path
if (-not $LogPath) {
    $LogPath = Get-FirewallLogPath
    Write-Verbose "Using log path: $LogPath"
}

# Get firewall log entries
$logEntries = Get-FirewallLogEntries -Path $LogPath

if (-not $logEntries) {
    exit 1
}

# Filter by connection type
if ($ConnectionType -ne 'All') {
    $filterAction = switch ($ConnectionType) {
        'Denied' { 'DROP' }
        'Accepted' { 'ALLOW' }
    }
    $logEntries = $logEntries | Where-Object { $_.action -eq $filterAction }
    Write-Verbose "Filtered to $($logEntries.Count) $ConnectionType connections"
}

# Filter by date range
if ($StartDate) {
    $logEntries = $logEntries | Where-Object { $_.DateTime -ge $StartDate }
    Write-Verbose "Filtered to $($logEntries.Count) entries after $StartDate"
}

if ($EndDate) {
    $logEntries = $logEntries | Where-Object { $_.DateTime -le $EndDate }
    Write-Verbose "Filtered to $($logEntries.Count) entries before $EndDate"
}

# Limit results if Top parameter is specified
if ($Top -and $Top -gt 0) {
    $logEntries = $logEntries | Select-Object -First $Top
    Write-Verbose "Limited to top $Top entries"
}

# Display summary
Write-Host "`nFirewall Log Summary:" -ForegroundColor Green
Write-Host "Total Entries: $($logEntries.Count)"

if ($logEntries.Count -gt 0) {
    $deniedCount = ($logEntries | Where-Object { $_.action -eq 'DROP' }).Count
    $acceptedCount = ($logEntries | Where-Object { $_.action -eq 'ALLOW' }).Count
    
    Write-Host "Denied Connections: $deniedCount" -ForegroundColor Red
    Write-Host "Accepted Connections: $acceptedCount" -ForegroundColor Green
    
    if ($logEntries[0].DateTime) {
        $dateRange = $logEntries | Where-Object { $_.DateTime } | Measure-Object -Property DateTime -Minimum -Maximum
        if ($dateRange.Minimum) {
            Write-Host "Date Range: $($dateRange.Minimum) to $($dateRange.Maximum)"
        }
    }
}

# Export to CSV if specified
if ($ExportPath) {
    try {
        $logEntries | Export-Csv -Path $ExportPath -NoTypeInformation -ErrorAction Stop
        Write-Host "`nResults exported to: $ExportPath" -ForegroundColor Green
    } catch {
        Write-Error "Failed to export to CSV: $_"
    }
}

# Exclude ALLOW entries and select only the desired columns
$logEntries = $logEntries | Where-Object { $_.action -ne 'ALLOW' } |
    Select-Object date, time, action, protocol, 'src-ip', 'dst-ip', 'src-port'

# Display results
Write-Host "`nRecent Entries (non-ALLOW only):" -ForegroundColor Cyan
$logEntries | Select-Object -First 20 | Format-Table -AutoSize

# Return the full collection
return $logEntries
