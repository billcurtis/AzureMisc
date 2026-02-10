<#
.SYNOPSIS
    Outputs all network requirements for Azure Virtual Desktop (AVD) connectivity
    through Windows App, without making any system changes.

.DESCRIPTION
    This script downloads the latest Azure Service Tags JSON and resolves AVD-related
    FQDNs to produce a comprehensive report of every IP range, FQDN, port, and protocol
    that must be allowed for AVD to function.

    The output is vendor-agnostic and can be used to configure any firewall or network
    security solution (e.g., Palo Alto, Fortinet, Cisco, Azure Firewall, NSGs, etc.).

    Output can be displayed to the console, exported to CSV, or exported to JSON.

    Use -Region to narrow Azure Service Tag IP ranges to a specific region (e.g. "eastus2").
    When no region is specified, the global (cloud-wide) IP ranges are returned.

.PARAMETER Region
    Optional Azure region name (e.g. "eastus2", "westus3", "uksouth").
    When specified, service tag lookups prefer the regional variant (e.g.
    "WindowsVirtualDesktop.EastUS2") and fall back to the global tag.
    When omitted, global (all-region) service tag ranges are returned.

.PARAMETER ExportCsv
    Path to export results as a CSV file.

.PARAMETER ExportJson
    Path to export results as a JSON file.

.PARAMETER ResolveFQDNs
    Also resolve FQDNs to their current IPv4 addresses via DNS and include them
    in the output.  Default is True.

.EXAMPLE
    .\Get-AVDNetworkRequirements.ps1
    Outputs all global AVD network requirements to the console.

.EXAMPLE
    .\Get-AVDNetworkRequirements.ps1 -Region eastus2
    Outputs AVD network requirements scoped to the EastUS2 region.

.EXAMPLE
    .\Get-AVDNetworkRequirements.ps1 -Region eastus2 -ExportCsv .\avd-requirements.csv
    Exports EastUS2-scoped requirements to CSV for import into your firewall.

.EXAMPLE
    .\Get-AVDNetworkRequirements.ps1 -Region eastus2 -ExportJson .\avd-requirements.json
    Exports EastUS2-scoped requirements to JSON for automation/API use.

.NOTES
    This script makes NO changes to your system. It is read-only / informational.
    
    The output format is designed to be easily consumed by any firewall management
    system or network security tool.

    Sources:
      https://learn.microsoft.com/en-us/azure/virtual-desktop/required-fqdn-endpoint?tabs=azure
      https://learn.microsoft.com/en-us/azure/security/fundamentals/azure-CA-details
      https://www.microsoft.com/en-us/download/details.aspx?id=56519
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Region,

    [Parameter()]
    [string]$ExportCsv,

    [Parameter()]
    [string]$ExportJson,

    [Parameter()]
    [bool]$ResolveFQDNs = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helper Functions ─────────────────────────────────────────────────────────
function Write-Status {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Cyan
}

function Get-ServiceTagPrefixes {
    <#
    .SYNOPSIS
        Extracts IPv4 prefixes from the Service Tags JSON.  When a region is
        specified, tries the regional tag first (e.g. "WindowsVirtualDesktop.EastUS2")
        then falls back to the global tag.
    #>
    param(
        [Parameter(Mandatory)][object]$Json,
        [Parameter(Mandatory)][string]$TagName,
        [string]$RegionName
    )

    $usedTag = $null

    # Try regional variant first
    if ($RegionName) {
        $regionalName = "$TagName.$RegionName"
        $tag = $Json.values | Where-Object { $_.name -eq $regionalName -or $_.id -eq $regionalName }
        if ($tag) {
            $usedTag = $regionalName
            $prefixes = @($tag.properties.addressPrefixes | Where-Object { $_ -notmatch ':' })
            return [PSCustomObject]@{ Tag = $usedTag; Prefixes = $prefixes }
        }
    }

    # Fall back to global
    $tag = $Json.values | Where-Object { $_.name -eq $TagName -or $_.id -eq $TagName }
    if ($tag) {
        $usedTag = $TagName
        $prefixes = @($tag.properties.addressPrefixes | Where-Object { $_ -notmatch ':' })
        return [PSCustomObject]@{ Tag = $usedTag; Prefixes = $prefixes }
    }

    Write-Warning "Service tag '$TagName' not found in JSON."
    return [PSCustomObject]@{ Tag = $TagName; Prefixes = @() }
}

function Resolve-FQDNToIPv4 {
    param([string]$FQDN)
    try {
        [string[]]$addrs = @([System.Net.Dns]::GetHostAddresses($FQDN) |
                 Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                 ForEach-Object { $_.IPAddressToString })
        return ,[string[]]$addrs
    } catch {
        return ,[string[]]@()
    }
}

# ── Download Azure Service Tags JSON ─────────────────────────────────────────
Write-Host "`n=== AVD Network Requirements Report ===" -ForegroundColor Green
if ($Region) {
    Write-Host "Region: $Region" -ForegroundColor Green
} else {
    Write-Host "Region: Global (all regions)" -ForegroundColor Green
}
Write-Host ""

Write-Status "Downloading Azure Service Tags JSON..."

$serviceTagsUrl = $null

try {
    $confirmPage = Invoke-WebRequest -Uri "https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519" -UseBasicParsing
    $serviceTagsUrl = ($confirmPage.Links |
                       Where-Object { $_.href -match 'ServiceTags_Public_\d+\.json$' } |
                       Select-Object -First 1).href
} catch { <# fall through #> }

if (-not $serviceTagsUrl) {
    $today = Get-Date
    for ($d = 0; $d -le 21; $d++) {
        $tryDate = $today.AddDays(-$d)
        $dateStr = $tryDate.ToString("yyyyMMdd")
        $tryUrl  = "https://download.microsoft.com/download/7/1/d/71d86715-5596-4529-9b13-da13a5de5b63/ServiceTags_Public_$dateStr.json"
        try {
            $head = Invoke-WebRequest -Uri $tryUrl -Method Head -UseBasicParsing -ErrorAction Stop
            if ($head.StatusCode -eq 200) { $serviceTagsUrl = $tryUrl; break }
        } catch { <# next #> }
    }
}

if (-not $serviceTagsUrl) {
    Write-Error "Unable to find Service Tags JSON download URL. Download manually from https://www.microsoft.com/en-us/download/details.aspx?id=56519"
    exit 1
}

$jsonPath = Join-Path $env:TEMP "ServiceTags_Public_latest.json"
Invoke-WebRequest -Uri $serviceTagsUrl -OutFile $jsonPath -UseBasicParsing
$stJson = Get-Content $jsonPath -Raw | ConvertFrom-Json
Write-Status "Loaded Service Tags – cloud=$($stJson.cloud)  changeNumber=$($stJson.changeNumber)"

# ── Normalise region name ────────────────────────────────────────────────────
# Service Tags use PascalCase region names (e.g. "EastUS2") but users may type
# "eastus2".  Find the canonical form from the JSON.
$canonicalRegion = $null
if ($Region) {
    $allRegions = @($stJson.values | ForEach-Object {
        if ($_.name -match '\.(.+)$') { $Matches[1] }
    } | Sort-Object -Unique)

    $canonicalRegion = $allRegions | Where-Object { $_ -ieq $Region } | Select-Object -First 1
    if (-not $canonicalRegion) {
        Write-Warning "Region '$Region' not found in Service Tags JSON.  Using global tags instead."
        Write-Warning "Available regions (sample): $($allRegions | Select-Object -First 20 | Join-String -Separator ', ')"
    } else {
        Write-Status "Matched region: $canonicalRegion"
    }
}

# ── Define all exclusion data ────────────────────────────────────────────────
$allExclusions = [System.Collections.ArrayList]::new()

# ── Infrastructure exclusions (not IP-specific) ─────────────────────────────
$infraExclusions = @(
    [PSCustomObject]@{ Category="Infrastructure"; Direction="Outbound"; Protocol="UDP"; Port="53";  FQDN="Any DNS Server";  IPRanges="Any";     ServiceTag=""; Purpose="DNS resolution (UDP)" }
    [PSCustomObject]@{ Category="Infrastructure"; Direction="Outbound"; Protocol="TCP"; Port="53";  FQDN="Any DNS Server";  IPRanges="Any";     ServiceTag=""; Purpose="DNS resolution (TCP)" }
    [PSCustomObject]@{ Category="Infrastructure"; Direction="Outbound"; Protocol="UDP"; Port="67";  FQDN="";                IPRanges="Any";     ServiceTag=""; Purpose="DHCP (client port 68 -> server port 67)" }
    [PSCustomObject]@{ Category="Infrastructure"; Direction="Outbound"; Protocol="UDP"; Port="123"; FQDN="";                IPRanges="Any";     ServiceTag=""; Purpose="NTP time synchronization" }
    [PSCustomObject]@{ Category="Infrastructure"; Direction="Outbound"; Protocol="ICMPv4"; Port=""; FQDN="";                IPRanges="Any";     ServiceTag=""; Purpose="ICMP for diagnostics" }
    [PSCustomObject]@{ Category="Infrastructure"; Direction="Outbound"; Protocol="Any"; Port="Any"; FQDN="";                IPRanges="127.0.0.0/8";   ServiceTag=""; Purpose="Loopback" }
    [PSCustomObject]@{ Category="Infrastructure"; Direction="Outbound"; Protocol="Any"; Port="Any"; FQDN="";                IPRanges="LocalSubnet";   ServiceTag=""; Purpose="Local subnet / LAN" }
)
foreach ($item in $infraExclusions) { [void]$allExclusions.Add($item) }

# ── Service Tag exclusions ───────────────────────────────────────────────────
Write-Status "Extracting service tag IP ranges..."

$serviceTagDefs = @(
    @{ Tag="WindowsVirtualDesktop"; Ports=@(@{Proto="TCP";Port="443"},@{Proto="UDP";Port="3478"}); Purpose="AVD gateways, brokers, TURN relay, RDP Shortpath" }
    @{ Tag="AzureCloud";            Ports=@(@{Proto="UDP";Port="1024-65535"});                       Purpose="RDP Shortpath STUN direct – UDP to session hosts" }
    @{ Tag="AzureActiveDirectory";  Ports=@(@{Proto="TCP";Port="443"},@{Proto="TCP";Port="80"});   Purpose="Entra ID / authentication" }
    @{ Tag="AzureFrontDoor.Frontend"; Ports=@(@{Proto="TCP";Port="443"},@{Proto="TCP";Port="80"}); Purpose="Azure Front Door – CDN, certificates" }
    @{ Tag="AzureFrontDoor.FirstParty"; Ports=@(@{Proto="TCP";Port="443"},@{Proto="TCP";Port="80"}); Purpose="Azure Front Door – first-party OCSP, certs" }
    @{ Tag="GuestAndHybridManagement"; Ports=@(@{Proto="TCP";Port="443"});                          Purpose="Azure guest agent / management" }
)

foreach ($def in $serviceTagDefs) {
    $result = Get-ServiceTagPrefixes -Json $stJson -TagName $def.Tag -RegionName $canonicalRegion
    $ipList = ($result.Prefixes | Sort-Object) -join "; "

    foreach ($portDef in $def.Ports) {
        [void]$allExclusions.Add([PSCustomObject]@{
            Category   = "Azure Service Tag"
            Direction  = "Outbound"
            Protocol   = $portDef.Proto
            Port       = $portDef.Port
            FQDN       = ""
            IPRanges   = $ipList
            ServiceTag = $result.Tag
            Purpose    = "$($def.Purpose) ($($result.Prefixes.Count) prefixes)"
        })
    }

    Write-Status "  $($result.Tag): $($result.Prefixes.Count) IPv4 prefixes"
}

# ── AVD RDP Shortpath – STUN/TURN ────────────────────────────────────────────
# TURN relay: all traffic relayed through TURN server on UDP 3478 (51.5.0.0/16)
# STUN direct: after STUN negotiation on UDP 3478, client sends UDP directly to
#              session host on dynamically negotiated ephemeral ports (covered by
#              AzureCloud tag above)
[void]$allExclusions.Add([PSCustomObject]@{
    Category   = "RDP Shortpath"
    Direction  = "Outbound"
    Protocol   = "UDP"
    Port       = "3478"
    FQDN       = ""
    IPRanges   = "51.5.0.0/16"
    ServiceTag = ""
    Purpose    = "AVD TURN relay – documented static range (supplements WVD service tag)"
})

# ── FQDN-based exclusions ───────────────────────────────────────────────────
Write-Status "Building FQDN exclusion list..."

$fqdnDefs = @(
    # TCP 443
    @{ FQDN="login.microsoftonline.com";              Proto="TCP"; Port="443"; Purpose="Authentication – Entra ID" }
    @{ FQDN="login.windows.net";                      Proto="TCP"; Port="443"; Purpose="Authentication – Entra ID" }
    @{ FQDN="login.live.com";                          Proto="TCP"; Port="443"; Purpose="Authentication – Microsoft Account" }
    @{ FQDN="aadcdn.msauth.net";                      Proto="TCP"; Port="443"; Purpose="Authentication – MSAL CDN" }
    @{ FQDN="aadcdn.msftauth.net";                    Proto="TCP"; Port="443"; Purpose="Authentication – MSAL CDN" }
    @{ FQDN="client.wvd.microsoft.com";               Proto="TCP"; Port="443"; Purpose="AVD service endpoint" }
    @{ FQDN="rdweb.wvd.microsoft.com";                Proto="TCP"; Port="443"; Purpose="AVD service endpoint" }
    @{ FQDN="windows.cloud.microsoft";                Proto="TCP"; Port="443"; Purpose="Windows App – Connection Center" }
    @{ FQDN="windows365.microsoft.com";               Proto="TCP"; Port="443"; Purpose="Windows App – service traffic" }
    @{ FQDN="ecs.office.com";                          Proto="TCP"; Port="443"; Purpose="Windows App – Connection Center" }
    @{ FQDN="graph.microsoft.com";                    Proto="TCP"; Port="443"; Purpose="Microsoft Graph API" }
    @{ FQDN="graph.windows.net";                      Proto="TCP"; Port="443"; Purpose="Azure AD Graph" }
    @{ FQDN="go.microsoft.com";                       Proto="TCP"; Port="443"; Purpose="Microsoft FWLinks" }
    @{ FQDN="aka.ms";                                  Proto="TCP"; Port="443"; Purpose="Microsoft URL shortener" }
    @{ FQDN="learn.microsoft.com";                    Proto="TCP"; Port="443"; Purpose="Documentation" }
    @{ FQDN="privacy.microsoft.com";                  Proto="TCP"; Port="443"; Purpose="Privacy statement" }
    @{ FQDN="catalogartifact.azureedge.net";          Proto="TCP"; Port="443"; Purpose="Azure Marketplace CDN" }
    @{ FQDN="mrsglobalsteus2prod.blob.core.windows.net"; Proto="TCP"; Port="443"; Purpose="AVD agent / SXS stack updates" }
    @{ FQDN="wvdportalstorageblob.blob.core.windows.net"; Proto="TCP"; Port="443"; Purpose="Azure portal support" }
    @{ FQDN="gcs.prod.monitoring.core.windows.net";   Proto="TCP"; Port="443"; Purpose="Azure Monitor agent traffic" }
    @{ FQDN="v10.events.data.microsoft.com";          Proto="TCP"; Port="443"; Purpose="Telemetry" }
    @{ FQDN="v20.events.data.microsoft.com";          Proto="TCP"; Port="443"; Purpose="Telemetry" }
    @{ FQDN="self.events.data.microsoft.com";         Proto="TCP"; Port="443"; Purpose="Telemetry" }
    @{ FQDN="res.cdn.office.net";                     Proto="TCP"; Port="443"; Purpose="Windows App auto-update CDN" }
    @{ FQDN="officecdn.microsoft.com";                Proto="TCP"; Port="443"; Purpose="Windows App auto-update CDN" }
    @{ FQDN="officecdn.microsoft.com.edgesuite.net";  Proto="TCP"; Port="443"; Purpose="Windows App auto-update CDN" }
    @{ FQDN="servicebus.windows.net";                 Proto="TCP"; Port="443"; Purpose="Service Bus – troubleshooting data" }
    @{ FQDN="www.msftconnecttest.com";                Proto="TCP"; Port="443"; Purpose="Internet connectivity test" }

    # TCP 80 – Certificates, CRL, OCSP, AIA
    @{ FQDN="www.microsoft.com";                      Proto="TCP"; Port="80";  Purpose="Certificate AIA / CRL" }
    @{ FQDN="oneocsp.microsoft.com";                  Proto="TCP"; Port="80";  Purpose="OCSP responder" }
    @{ FQDN="azcsprodeusaikpublish.blob.core.windows.net"; Proto="TCP"; Port="80"; Purpose="Certificate AIA" }
    @{ FQDN="ctldl.windowsupdate.com";                Proto="TCP"; Port="80";  Purpose="Certificate Trust List download" }
    @{ FQDN="cacerts.digicert.com";                   Proto="TCP"; Port="80";  Purpose="DigiCert CA certificates" }
    @{ FQDN="cacerts.digicert.cn";                    Proto="TCP"; Port="80";  Purpose="DigiCert CN CA certificates" }
    @{ FQDN="cacerts.geotrust.com";                   Proto="TCP"; Port="80";  Purpose="GeoTrust CA certificates" }
    @{ FQDN="caissuers.microsoft.com";                Proto="TCP"; Port="80";  Purpose="Microsoft CA issuers (AIA)" }
    @{ FQDN="crl3.digicert.com";                      Proto="TCP"; Port="80";  Purpose="DigiCert CRL" }
    @{ FQDN="crl4.digicert.com";                      Proto="TCP"; Port="80";  Purpose="DigiCert CRL" }
    @{ FQDN="crl.digicert.cn";                        Proto="TCP"; Port="80";  Purpose="DigiCert CN CRL" }
    @{ FQDN="ocsp.digicert.com";                      Proto="TCP"; Port="80";  Purpose="DigiCert OCSP" }
    @{ FQDN="ocsp.digicert.cn";                       Proto="TCP"; Port="80";  Purpose="DigiCert CN OCSP" }
    @{ FQDN="www.msftconnecttest.com";                Proto="TCP"; Port="80";  Purpose="Internet connectivity test" }
)

if ($ResolveFQDNs) {
    Write-Status "Resolving FQDNs to IPv4 addresses..."
}

foreach ($def in $fqdnDefs) {
    $resolvedIPs = ""
    if ($ResolveFQDNs) {
        [string[]]$ips = @(Resolve-FQDNToIPv4 -FQDN $def.FQDN)
        if ($ips.Count -gt 0) {
            $resolvedIPs = ($ips | Sort-Object) -join "; "
        } else {
            $resolvedIPs = "(unresolvable)"
        }
    }

    [void]$allExclusions.Add([PSCustomObject]@{
        Category   = "FQDN"
        Direction  = "Outbound"
        Protocol   = $def.Proto
        Port       = $def.Port
        FQDN       = $def.FQDN
        IPRanges   = $resolvedIPs
        ServiceTag = ""
        Purpose    = $def.Purpose
    })
}

# ── Output ───────────────────────────────────────────────────────────────────
Write-Host ""

# Console display – grouped by category
$grouped = $allExclusions | Group-Object -Property Category

foreach ($group in $grouped) {
    Write-Host "─── $($group.Name) ($($group.Count) entries) ───" -ForegroundColor Yellow
    $group.Group | Format-Table -Property Direction, Protocol, Port, FQDN, ServiceTag, Purpose -AutoSize -Wrap | Out-String | Write-Host
}

# Summary
$totalServiceTagPrefixes = 0
foreach ($def in $serviceTagDefs) {
    $result = Get-ServiceTagPrefixes -Json $stJson -TagName $def.Tag -RegionName $canonicalRegion
    $totalServiceTagPrefixes += $result.Prefixes.Count
}

Write-Host "=== Summary ===" -ForegroundColor Green
Write-Host "  Total exclusion entries : $($allExclusions.Count)"
Write-Host "  Service tag IP prefixes : $totalServiceTagPrefixes"
Write-Host "  FQDNs                   : $(($allExclusions | Where-Object { $_.Category -eq 'FQDN' }).Count)"
Write-Host "  Infrastructure rules    : $(($allExclusions | Where-Object { $_.Category -eq 'Infrastructure' }).Count)"
if ($Region) {
    Write-Host "  Region filter           : $Region$(if ($canonicalRegion) { " (matched: $canonicalRegion)" })"
} else {
    Write-Host "  Region filter           : None (global)"
}
Write-Host ""

# CSV export
if ($ExportCsv) {
    $allExclusions | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Exported to CSV: $ExportCsv" -ForegroundColor Green
}

# JSON export
if ($ExportJson) {
    $allExclusions | ConvertTo-Json -Depth 5 | Set-Content -Path $ExportJson -Encoding UTF8
    Write-Host "Exported to JSON: $ExportJson" -ForegroundColor Green
}

if (-not $ExportCsv -and -not $ExportJson) {
    Write-Host "Tip: Use -ExportCsv or -ExportJson to save this data to a file." -ForegroundColor DarkGray
}

# Return objects to pipeline for further processing
$allExclusions
