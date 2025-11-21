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
    [string]$LogPath = "$env:SystemRoot\System32\LogFiles\Firewall\pfirewall.log",

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
    [int]$Top
)

function Get-FirewallLogEntries {
    param(
        [string]$Path
    )

    # Check if log file exists
    if (-not (Test-Path -Path $Path)) {
        Write-Error "Firewall log file not found at: $Path"
        Write-Warning "To enable Windows Firewall logging:"
        Write-Warning "1. Open Windows Defender Firewall with Advanced Security"
        Write-Warning "2. Right-click 'Windows Defender Firewall with Advanced Security' and select Properties"
        Write-Warning "3. For each profile (Domain, Private, Public), go to the profile tab"
        Write-Warning "4. Click 'Customize' in the Logging section"
        Write-Warning "5. Set 'Log dropped packets' and/or 'Log successful connections' to 'Yes'"
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
Write-Host "Collecting Windows Firewall logs..." -ForegroundColor Cyan

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

# Display results
Write-Host "`nRecent Entries:" -ForegroundColor Cyan
$logEntries | Select-Object -First 20 DateTime, ActionText, ProtocolText, 
    @{Name='Source'; Expression={"$($_.'src-ip'):$($_.'src-port')"}},
    @{Name='Destination'; Expression={"$($_.'dst-ip'):$($_.'dst-port')"}},
    path | Format-Table -AutoSize

# Return the full collection
return $logEntries
