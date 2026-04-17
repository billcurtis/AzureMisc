#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Queries the Security event log for Windows Defender Firewall block events
    from the past hour and outputs blocked IPs with the associated rule.

.DESCRIPTION
    Pulls Event IDs 5152 (packet drop) and 5157 (connection block) from the
    Windows Filtering Platform in the Security log. Maps FilterRTID to the
    Windows Defender Firewall rule DisplayName where possible.

.NOTES
    Requires: Audit Filtering Platform Connection / Packet Drop enabled.
    Run as administrator.
#>

$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$OutputFile = Join-Path $ScriptDir "FirewallBlocks_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$LookbackMinutes = 60

# ── Build a FilterRTID -> Rule DisplayName lookup via WFP filter dump ─────────
Write-Host "Building WFP filter lookup table (this may take a moment)..."
$ruleLookup = @{}
try {
    $wfpTempFile = Join-Path $env:TEMP "wfpfilters_$PID.xml"
    $null = & netsh wfp show filters file="$wfpTempFile" 2>&1
    if (Test-Path $wfpTempFile) {
        # WFP XML has: <displayData><name>RuleName</name></displayData> ... <filterId>NNN</filterId>
        # Nested <item> tags inside <filterCondition>/<flags> do NOT contain <displayData>,
        # so we simply track the last <displayData><name> seen and map it when <filterId> appears.
        $currentName   = $null
        $inDisplayData = $false
        foreach ($line in [System.IO.File]::ReadLines($wfpTempFile)) {
            if ($line -match '<displayData>') {
                $inDisplayData = $true
            }
            elseif ($line -match '</displayData>') {
                $inDisplayData = $false
            }
            elseif ($inDisplayData -and $line -match '<name>(.*?)</name>') {
                $currentName = $Matches[1]
            }
            elseif ($line -match '<filterId>(\d+)</filterId>') {
                if ($currentName) {
                    $ruleLookup[$Matches[1]] = $currentName
                }
            }
        }
        Remove-Item $wfpTempFile -Force -ErrorAction SilentlyContinue
        Write-Host "  Loaded $($ruleLookup.Count) WFP filter-to-rule mappings."
    } else {
        Write-Host "  Warning: netsh wfp show filters did not produce output."
    }
} catch {
    Write-Host "  Warning: Could not enumerate WFP filters: $_"
}

# ── Query Security log for WFP block events ──────────────────────────────────
$startTime = (Get-Date).AddMinutes(-$LookbackMinutes)
Write-Host "Querying Security log for firewall blocks since $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))..."

$filterXml = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">
      *[System[(EventID=5152 or EventID=5157) and TimeCreated[timediff(@SystemTime) &lt;= $(${LookbackMinutes} * 60 * 1000)]]]
    </Select>
  </Query>
</QueryList>
"@

try {
    $events = Get-WinEvent -FilterXml $filterXml -ErrorAction Stop
} catch {
    if ($_.Exception.Message -match "No events were found") {
        Write-Host "No firewall block events found in the past $LookbackMinutes minutes."
        "No firewall block events found in the past $LookbackMinutes minutes (queried $(Get-Date))." | Out-File $OutputFile -Encoding UTF8
        Write-Host "Output: $OutputFile"
        exit 0
    }
    Write-Host "Error querying Security log: $_"
    exit 1
}

Write-Host "Found $($events.Count) block events. Parsing..."

# ── Parse each event ─────────────────────────────────────────────────────────
$results = [System.Collections.ArrayList]::new()

foreach ($evt in $events) {
    $xml = [xml]$evt.ToXml()
    $data = @{}
    foreach ($node in $xml.Event.EventData.Data) {
        $data[$node.Name] = $node.'#text'
    }

    $srcAddr  = $data['SourceAddress']
    $dstAddr  = $data['DestAddress']
    $srcPort  = $data['SourcePort']
    $dstPort  = $data['DestPort']
    $protocol = $data['Protocol']
    $filterID = $data['FilterRTID']
    $layerName = $data['LayerName']
    $appPath  = $data['Application']
    $direction = $data['Direction']

    # Map protocol number to name
    $protoName = switch ($protocol) {
        '6'  { 'TCP' }
        '17' { 'UDP' }
        '1'  { 'ICMP' }
        default { "Proto-$protocol" }
    }

    # Map direction
    $dirLabel = switch ($direction) {
        '%%14592' { 'Inbound' }
        '%%14593' { 'Outbound' }
        default   { $direction }
    }

    # Try to resolve FilterRTID to a rule name
    $ruleName = "FilterRTID: $filterID"
    if ($ruleLookup.ContainsKey($filterID)) {
        $ruleName = $ruleLookup[$filterID]
    }

    [void]$results.Add([PSCustomObject]@{
        TimeUTC     = $evt.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        EventID     = $evt.Id
        Direction   = $dirLabel
        SourceIP    = $srcAddr
        SourcePort  = $srcPort
        DestIP      = $dstAddr
        DestPort    = $dstPort
        Protocol    = $protoName
        Application = $appPath
        RuleName    = $ruleName
    })
}

# ── Write output file ────────────────────────────────────────────────────────
$header = @"
========================================================================
  Windows Defender Firewall - Blocked Traffic Report
  Generated : $(Get-Date)
  Host      : $env:COMPUTERNAME
  Lookback  : Past $LookbackMinutes minutes
  Events    : $($results.Count)
========================================================================

"@

$body = $results | Format-Table -AutoSize -Wrap | Out-String

# Summary: unique destination IPs and the rules that blocked them
$summary = $results |
    Group-Object -Property DestIP, DestPort, Protocol, RuleName |
    Sort-Object Count -Descending |
    Select-Object @{N='Count';E={$_.Count}},
                  @{N='DestIP';E={($_.Group[0]).DestIP}},
                  @{N='DestPort';E={($_.Group[0]).DestPort}},
                  @{N='Protocol';E={($_.Group[0]).Protocol}},
                  @{N='RuleName';E={($_.Group[0]).RuleName}} |
    Format-Table -AutoSize -Wrap | Out-String

$output = @"
$header
--- SUMMARY (grouped by destination) ---
$summary

--- FULL EVENT DETAIL ---
$body
"@

$output | Out-File -FilePath $OutputFile -Encoding UTF8
Write-Host "`nReport written to: $OutputFile"
Write-Host "`n--- Top blocked destinations ---"
$results |
    Group-Object -Property DestIP, DestPort, Protocol |
    Sort-Object Count -Descending |
    Select-Object -First 15 Count, @{N='DestIP';E={$_.Group[0].DestIP}},
        @{N='Port';E={$_.Group[0].DestPort}},
        @{N='Proto';E={$_.Group[0].Protocol}},
        @{N='Rule';E={$_.Group[0].RuleName}} |
    Format-Table -AutoSize
