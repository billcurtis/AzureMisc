<#
.SYNOPSIS
    Checks the event log for evidence of MMR (Multimedia Redirection) session initiation.

.DESCRIPTION
    Scans the Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational log
    for Event ID 132 entries where the ChannelName contains "mmr", indicating
    that a Multimedia Redirection DVC channel was connected.

.PARAMETER ComputerName
    One or more remote computer names to query. Defaults to the local machine.

.PARAMETER MaxEvents
    Maximum number of matching events to return. Defaults to 50.

.PARAMETER StartTime
    Optional. Only return events after this date/time.

.PARAMETER EndTime
    Optional. Only return events before this date/time.

.EXAMPLE
    .\Check-MMRSession.ps1

.EXAMPLE
    .\Check-MMRSession.ps1 -ComputerName "avdmmrtst-1","avdmmrtst-2"

.EXAMPLE
    .\Check-MMRSession.ps1 -StartTime (Get-Date).AddDays(-7)
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true)]
    [string[]]$ComputerName = $env:COMPUTERNAME,

    [int]$MaxEvents = 50,

    [datetime]$StartTime,

    [datetime]$EndTime
)

begin {
    $logName   = 'Microsoft-Windows-RemoteDesktopServices-RdpCoreCDV/Operational'
    $eventId   = 132
    $mmrFilter = '*mmr*'

    # Build the hash-table filter for Get-WinEvent
    $filter = @{
        LogName = $logName
        Id      = $eventId
    }
    if ($StartTime) { $filter['StartTime'] = $StartTime }
    if ($EndTime)   { $filter['EndTime']   = $EndTime }
}

process {
    foreach ($computer in $ComputerName) {
        Write-Host "`n===== Checking $computer =====" -ForegroundColor Cyan

        try {
            $params = @{
                FilterHashtable = $filter
                MaxEvents       = $MaxEvents
                ErrorAction     = 'Stop'
            }
            if ($computer -ne $env:COMPUTERNAME) {
                $params['ComputerName'] = $computer
            }

            $events = Get-WinEvent @params |
                Where-Object {
                    # Parse the XML payload and check the ChannelName for "mmr"
                    $xml = [xml]$_.ToXml()
                    $channelName = ($xml.Event.EventData.Data |
                        Where-Object { $_.Name -eq 'ChannelName' }).'#text'
                    $channelName -like $mmrFilter
                }

            if ($events) {
                Write-Host "[FOUND] $($events.Count) MMR session event(s) detected on $computer." -ForegroundColor Green

                $events | ForEach-Object {
                    $xml = [xml]$_.ToXml()
                    $channelName = ($xml.Event.EventData.Data |
                        Where-Object { $_.Name -eq 'ChannelName' }).'#text'
                    $tunnelId = ($xml.Event.EventData.Data |
                        Where-Object { $_.Name -eq 'TunnelID' }).'#text'

                    [PSCustomObject]@{
                        Computer    = $computer
                        TimeCreated = $_.TimeCreated
                        RecordId    = $_.RecordId
                        ChannelName = $channelName
                        TunnelID    = $tunnelId
                        Message     = $_.Message
                    }
                } | Format-Table -AutoSize -Wrap
            }
            else {
                Write-Host "[NOT FOUND] No MMR session events on $computer." -ForegroundColor Yellow
            }
        }
        catch [Exception] {
            if ($_.Exception.Message -match 'No events were found') {
                Write-Host "[NOT FOUND] No Event ID $eventId entries in the log on $computer." -ForegroundColor Yellow
            }
            elseif ($_.Exception.Message -match 'could not be found|is not a valid') {
                Write-Host "[ERROR] Log '$logName' does not exist on $computer. RDP Core CDV component may not be installed." -ForegroundColor Red
            }
            else {
                Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

end {
    Write-Host "`nScan complete." -ForegroundColor Cyan
}
