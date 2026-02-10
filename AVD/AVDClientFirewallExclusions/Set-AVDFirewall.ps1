#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configures Windows Firewall to block all internet traffic except Azure Virtual Desktop (AVD)
    connectivity through Windows App.

.DESCRIPTION
    This script locks down the Windows Firewall to only allow outbound traffic required for:
      - Azure Virtual Desktop (AVD) client connectivity via Windows App
      - DNS resolution (required for AVD name resolution)
      - DHCP (required for IP address assignment)
      - NTP (required for time sync / token validation)
      - Certificate validation (OCSP, CRL, AIA)

    The script downloads the latest Azure Service Tags JSON to obtain current IP ranges
    for AVD-related Azure services, and resolves specific FQDNs to IP addresses.
    No wildcard URLs are used.

    AVD Session Hosts are in the EastUS2 data center.

    Run with -Disable to remove all AVD firewall rules and restore default outbound policy.

.PARAMETER Enable
    Apply the AVD firewall lockdown rules and set default outbound to Block.

.PARAMETER Disable
    Remove all AVD firewall rules and restore the default outbound Allow policy.

.EXAMPLE
    .\Set-AVDFirewall.ps1 -Enable

.EXAMPLE
    .\Set-AVDFirewall.ps1 -Disable

.NOTES
    - DNS is allowed for AVD name resolution.
    - Re-run periodically to pick up Azure Service Tag IP range changes.
    - A firewall backup (.wfw) is saved before any changes.

    Sources:
      https://learn.microsoft.com/en-us/azure/virtual-desktop/required-fqdn-endpoint?tabs=azure
      https://learn.microsoft.com/en-us/azure/security/fundamentals/azure-CA-details
      https://www.microsoft.com/en-us/download/details.aspx?id=56519
#>

[CmdletBinding(DefaultParameterSetName = 'Enable')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Enable')]
    [switch]$Enable,

    [Parameter(Mandatory, ParameterSetName = 'Disable')]
    [switch]$Disable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ────────────────────────────────────────────────────────────────
$RulePrefix  = "AVD-FW"
$BackupDir   = $PSScriptRoot
$Timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$BackupPath  = Join-Path $BackupDir "FirewallBackup_$Timestamp.wfw"
$LogPath     = Join-Path $BackupDir "AVDFirewall_$Timestamp.log"

# ── Helper Functions ─────────────────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS")]
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        "ERROR"   { "Red"    }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green"  }
        default   { "Cyan"   }
    }
    Write-Host $entry -ForegroundColor $color
    Add-Content -Path $LogPath -Value $entry -ErrorAction SilentlyContinue
}

function Get-ServiceTagPrefixes {
    <#
    .SYNOPSIS
        Extracts IPv4 prefixes from the downloaded Azure Service Tags JSON for a
        given tag name (e.g. "WindowsVirtualDesktop", "AzureActiveDirectory").
    #>
    param(
        [Parameter(Mandatory)][object]$Json,
        [Parameter(Mandatory)][string]$TagName
    )
    $tag = $Json.values | Where-Object { $_.name -eq $TagName -or $_.id -eq $TagName }
    if ($tag) {
        # Return only IPv4 (exclude IPv6 entries that contain ':')
        return @($tag.properties.addressPrefixes | Where-Object { $_ -notmatch ':' })
    }
    Write-Log "Service tag '$TagName' not found in JSON." -Level WARN
    return @()
}

function Resolve-FQDNsToIPv4 {
    <#
    .SYNOPSIS
        Resolves an array of FQDNs to their current IPv4 addresses via DNS.
        Returns a deduplicated list.  Non-resolvable names are logged and skipped.
    #>
    param([string[]]$FQDNs)

    $allIPs = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($fqdn in $FQDNs) {
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($fqdn) |
                     Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                     ForEach-Object { $_.IPAddressToString }
            if ($addrs) {
                foreach ($a in $addrs) { [void]$allIPs.Add($a) }
                Write-Log "  Resolved  $fqdn  ->  $($addrs -join ', ')"
            } else {
                Write-Log "  No IPv4 result for $fqdn" -Level WARN
            }
        } catch {
            Write-Log "  DNS failure for $fqdn : $_" -Level WARN
        }
    }
    return ,[string[]]@($allIPs)
}

function Remove-AVDFirewallRules {
    Write-Log "Removing existing AVD firewall rules (prefix '$RulePrefix')..."
    $existing = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
                  Where-Object { $_.DisplayName -like "$RulePrefix*" })
    if ($existing.Count -gt 0) {
        $existing | Remove-NetFirewallRule
        Write-Log "Removed $($existing.Count) existing rule(s)." -Level SUCCESS
    } else {
        Write-Log "No existing AVD rules found."
    }
}

function New-FWRule {
    <#
    .SYNOPSIS
        Thin wrapper around New-NetFirewallRule that chunks RemoteAddress arrays
        (Windows Firewall can bog down with huge address lists in a single rule).
    #>
    param(
        [string]$Name,
        [string]$Description,
        [string]$Protocol,
        [string]$RemotePort,
        [string[]]$RemoteAddress,
        [string]$Direction = 'Outbound',
        [string]$Action    = 'Allow'
    )

    [string[]]$RemoteAddress = @($RemoteAddress)   # guarantee array even for single-element input
    $chunkSize = 800          # keep each rule under ~800 prefixes
    if ($RemoteAddress.Count -le $chunkSize) {
        $chunks = @(, $RemoteAddress)   # single chunk (wrap in array of arrays)
    } else {
        $chunks = [System.Collections.ArrayList]::new()
        for ($i = 0; $i -lt $RemoteAddress.Count; $i += $chunkSize) {
            $end = [Math]::Min($i + $chunkSize - 1, $RemoteAddress.Count - 1)
            [void]$chunks.Add(@($RemoteAddress[$i..$end]))
        }
    }

    $n = 0
    foreach ($chunk in $chunks) {
        $n++
        $suffix = if ($chunks.Count -gt 1) { " ($n of $($chunks.Count))" } else { "" }
        $params = @{
            DisplayName  = "$RulePrefix - $Name$suffix"
            Description  = $Description
            Direction    = $Direction
            Action       = $Action
            Profile      = 'Any'
            Enabled      = 'True'
            RemoteAddress = $chunk
        }
        if ($Protocol)   { $params['Protocol']   = $Protocol }
        if ($RemotePort) { $params['RemotePort'] = $RemotePort }

        New-NetFirewallRule @params | Out-Null
    }

    $script:ruleCount += $n
    Write-Log "  [+] $Name  ($($RemoteAddress.Count) addresses, $n rule(s))"
}

# ─────────────────────────────────────────────────────────────────────────────
#  DISABLE MODE
# ─────────────────────────────────────────────────────────────────────────────
if ($Disable) {
    Write-Log "===  DISABLING AVD Firewall Lockdown  ==="
    Remove-AVDFirewallRules

    Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultOutboundAction Allow
    Write-Log "Default outbound policy restored to ALLOW on all profiles." -Level SUCCESS
    Write-Log "===  Done  ==="
    Write-Host "`nAll AVD firewall rules removed.  Outbound traffic is now unrestricted." -ForegroundColor Green
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  ENABLE MODE
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "===  ENABLING AVD Firewall Lockdown  ==="
Write-Log "Target AVD region: EastUS2"

# ── 1. Backup current firewall config ────────────────────────────────────────
Write-Log "Backing up current firewall configuration..."
try {
    $null = netsh advfirewall export $BackupPath 2>&1
    Write-Log "Backup saved: $BackupPath" -Level SUCCESS
} catch {
    Write-Log "Backup failed (non-fatal): $_" -Level WARN
}

# ── 2. Download Azure Service Tags JSON ─────────────────────────────────────
Write-Log "Downloading Azure Service Tags JSON..."

$serviceTagsUrl = $null

# Method 1 – Scrape the Microsoft download confirmation page for the JSON link
try {
    $confirmPage = Invoke-WebRequest -Uri "https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519" -UseBasicParsing
    $serviceTagsUrl = ($confirmPage.Links |
                       Where-Object { $_.href -match 'ServiceTags_Public_\d+\.json$' } |
                       Select-Object -First 1).href
    if ($serviceTagsUrl) { Write-Log "Found download URL via confirmation page." }
} catch {
    Write-Log "Could not scrape confirmation page: $_" -Level WARN
}

# Method 2 – Brute-force recent Monday dates (Service Tags publish weekly)
if (-not $serviceTagsUrl) {
    Write-Log "Trying date-based URL guessing..."
    $today = Get-Date
    for ($d = 0; $d -le 21; $d++) {
        $tryDate = $today.AddDays(-$d)
        $dateStr = $tryDate.ToString("yyyyMMdd")
        $tryUrl  = "https://download.microsoft.com/download/7/1/d/71d86715-5596-4529-9b13-da13a5de5b63/ServiceTags_Public_$dateStr.json"
        try {
            $head = Invoke-WebRequest -Uri $tryUrl -Method Head -UseBasicParsing -ErrorAction Stop
            if ($head.StatusCode -eq 200) {
                $serviceTagsUrl = $tryUrl
                Write-Log "Found JSON at date $dateStr."
                break
            }
        } catch { <# next iteration #> }
    }
}

if (-not $serviceTagsUrl) {
    Write-Log "FATAL: Unable to find Service Tags JSON download URL." -Level ERROR
    Write-Log "Download manually from https://www.microsoft.com/en-us/download/details.aspx?id=56519" -Level ERROR
    exit 1
}

$jsonPath = Join-Path $env:TEMP "ServiceTags_Public_latest.json"
try {
    Invoke-WebRequest -Uri $serviceTagsUrl -OutFile $jsonPath -UseBasicParsing
    $stJson = Get-Content $jsonPath -Raw | ConvertFrom-Json
    Write-Log "Loaded Service Tags – cloud=$($stJson.cloud)  changeNumber=$($stJson.changeNumber)" -Level SUCCESS
} catch {
    Write-Log "FATAL: Failed to download/parse Service Tags JSON: $_" -Level ERROR
    exit 1
}

# ── 3. Extract IP prefixes from relevant service tags ────────────────────────
Write-Log "Extracting IP prefixes from Azure Service Tags..."

# Tags and why we need them:
#   WindowsVirtualDesktop       – all AVD gateway, broker, TURN relay IPs
#                                  (covers *.wvd.microsoft.com, *.service.windows.cloud.microsoft, 51.5.0.0/16)
#   AzureActiveDirectory        – Entra ID / login.microsoftonline.com
#   AzureFrontDoor.Frontend     – CDN, Azure Front Door endpoints
#   AzureFrontDoor.FirstParty   – First-party Front Door (OCSP, certs, etc.)
#   GuestAndHybridManagement    – Azure guest agent / management traffic
#   AzureCloud.EastUS2          – RDP Shortpath STUN direct UDP to session hosts in EastUS2

$tagNames = @(
    "WindowsVirtualDesktop"
    "AzureActiveDirectory"
    "AzureFrontDoor.Frontend"
    "AzureFrontDoor.FirstParty"
    "GuestAndHybridManagement"
    "AzureCloud.EastUS2"
)

$tagIPs = @{}   # tagName -> string[]
foreach ($tag in $tagNames) {
    $prefixes = Get-ServiceTagPrefixes -Json $stJson -TagName $tag
    $tagIPs[$tag] = $prefixes
    Write-Log "  $tag : $($prefixes.Count) IPv4 prefixes"
}

# ── 4. Resolve specific FQDNs to IP addresses ───────────────────────────────
Write-Log "Resolving specific FQDNs..."

# --- HTTPS / TCP 443 FQDNs ---------------------------------------------------
$fqdns443 = @(
    # Authentication (Entra ID / MSAL)
    "login.microsoftonline.com"
    "login.windows.net"
    "login.live.com"
    "aadcdn.msauth.net"
    "aadcdn.msftauth.net"

    # AVD service endpoints (specific – no wildcards)
    "client.wvd.microsoft.com"
    "rdweb.wvd.microsoft.com"

    # Windows App / Connection Center
    "windows.cloud.microsoft"
    "windows365.microsoft.com"
    "ecs.office.com"

    # Microsoft Graph
    "graph.microsoft.com"
    "graph.windows.net"

    # General Microsoft
    "go.microsoft.com"
    "aka.ms"
    "learn.microsoft.com"
    "privacy.microsoft.com"

    # Azure CDN / Storage
    "catalogartifact.azureedge.net"
    "mrsglobalsteus2prod.blob.core.windows.net"
    "wvdportalstorageblob.blob.core.windows.net"

    # Monitoring
    "gcs.prod.monitoring.core.windows.net"

    # Telemetry (specific subdomains for *.events.data.microsoft.com)
    "v10.events.data.microsoft.com"
    "v20.events.data.microsoft.com"
    "self.events.data.microsoft.com"

    # Windows App auto-update CDN (specific subdomains for *.cdn.office.net)
    "res.cdn.office.net"
    "officecdn.microsoft.com"
    "officecdn.microsoft.com.edgesuite.net"

    # Service Bus (specific subdomains for *.servicebus.windows.net)
    "servicebus.windows.net"

    # Connection test
    "www.msftconnecttest.com"
)

# --- HTTP / TCP 80 FQDNs (certificates, CRL, OCSP, AIA) ---------------------
$fqdns80 = @(
    # AVD-listed certificate endpoints
    "www.microsoft.com"
    "oneocsp.microsoft.com"
    "azcsprodeusaikpublish.blob.core.windows.net"
    "ctldl.windowsupdate.com"

    # Azure CA certificate downloads and revocation lists
    # (from https://learn.microsoft.com/en-us/azure/security/fundamentals/azure-CA-details)
    "cacerts.digicert.com"
    "cacerts.digicert.cn"
    "cacerts.geotrust.com"
    "caissuers.microsoft.com"
    "crl3.digicert.com"
    "crl4.digicert.com"
    "crl.digicert.cn"
    "ocsp.digicert.com"
    "ocsp.digicert.cn"

    # Connection test (also on port 80)
    "www.msftconnecttest.com"
)

$resolved443 = Resolve-FQDNsToIPv4 -FQDNs $fqdns443
$resolved80  = Resolve-FQDNsToIPv4 -FQDNs $fqdns80

Write-Log "Resolved $($resolved443.Count) unique IPv4s for TCP/443 FQDNs."
Write-Log "Resolved $($resolved80.Count) unique IPv4s for TCP/80 FQDNs."

# ── 5. Remove any previous AVD rules ────────────────────────────────────────
Remove-AVDFirewallRules

# ── 6. Create firewall rules ────────────────────────────────────────────────
Write-Log "Creating firewall allow rules..."
$script:ruleCount = 0

# ---- Infrastructure rules ----

# 6a. Loopback / localhost
New-NetFirewallRule -DisplayName "$RulePrefix - Loopback" `
    -Direction Outbound -Action Allow -Profile Any -Enabled True `
    -RemoteAddress "127.0.0.0/8" `
    -Description "Allow all loopback / localhost traffic" | Out-Null
$script:ruleCount++
Write-Log "  [+] Loopback"

# 6b. Local Subnet
New-NetFirewallRule -DisplayName "$RulePrefix - Local Subnet" `
    -Direction Outbound -Action Allow -Profile Any -Enabled True `
    -RemoteAddress LocalSubnet `
    -Description "Allow local subnet traffic (LAN)" | Out-Null
$script:ruleCount++
Write-Log "  [+] Local Subnet"

# 6c. DHCP
New-NetFirewallRule -DisplayName "$RulePrefix - DHCP" `
    -Direction Outbound -Action Allow -Profile Any -Enabled True `
    -Protocol UDP -LocalPort 68 -RemotePort 67 `
    -Description "Allow DHCP client discovery and lease renewal" | Out-Null
$script:ruleCount++
Write-Log "  [+] DHCP"

# 6d. DNS (UDP + TCP)
New-NetFirewallRule -DisplayName "$RulePrefix - DNS (UDP)" `
    -Direction Outbound -Action Allow -Profile Any -Enabled True `
    -Protocol UDP -RemotePort 53 `
    -Description "Allow DNS resolution over UDP" | Out-Null
New-NetFirewallRule -DisplayName "$RulePrefix - DNS (TCP)" `
    -Direction Outbound -Action Allow -Profile Any -Enabled True `
    -Protocol TCP -RemotePort 53 `
    -Description "Allow DNS resolution over TCP" | Out-Null
$script:ruleCount += 2
Write-Log "  [+] DNS (UDP + TCP)"

# 6e. NTP – time must be accurate for Kerberos / OAuth token validation
New-NetFirewallRule -DisplayName "$RulePrefix - NTP" `
    -Direction Outbound -Action Allow -Profile Any -Enabled True `
    -Protocol UDP -RemotePort 123 `
    -Description "Allow NTP time synchronization (required for token validation)" | Out-Null
$script:ruleCount++
Write-Log "  [+] NTP"

# 6f. ICMPv4 (optional – useful for troubleshooting)
New-NetFirewallRule -DisplayName "$RulePrefix - ICMPv4" `
    -Direction Outbound -Action Allow -Profile Any -Enabled True `
    -Protocol ICMPv4 `
    -Description "Allow ICMP for diagnostics (ping, traceroute)" | Out-Null
$script:ruleCount++
Write-Log "  [+] ICMPv4"

# ---- Azure Service Tag rules (TCP 443) ----

foreach ($tag in $tagNames) {
    $prefixes = $tagIPs[$tag]
    if ($prefixes.Count -eq 0) { continue }

    New-FWRule -Name "$tag (TCP 443)" `
               -Description "Azure Service Tag: $tag – HTTPS service traffic" `
               -Protocol TCP -RemotePort 443 `
               -RemoteAddress $prefixes
}

# Also allow TCP 80 from AzureFrontDoor tags (certificate endpoints often behind FD)
foreach ($fdTag in @("AzureFrontDoor.Frontend", "AzureFrontDoor.FirstParty")) {
    $prefixes = $tagIPs[$fdTag]
    if ($prefixes.Count -eq 0) { continue }

    New-FWRule -Name "$fdTag (TCP 80)" `
               -Description "Azure Service Tag: $fdTag – HTTP (certificates, CRL, OCSP)" `
               -Protocol TCP -RemotePort 80 `
               -RemoteAddress $prefixes
}

# Also allow TCP 80 from AzureActiveDirectory (some auth endpoints use HTTP redirect)
$aadPrefixes = $tagIPs["AzureActiveDirectory"]
if ($aadPrefixes.Count -gt 0) {
    New-FWRule -Name "AzureActiveDirectory (TCP 80)" `
               -Description "Azure Service Tag: AzureActiveDirectory – HTTP" `
               -Protocol TCP -RemotePort 80 `
               -RemoteAddress $aadPrefixes
}

# ---- AVD RDP Shortpath – STUN/TURN ----
#   TURN relay:  all RDP traffic relayed via TURN server on UDP 3478
#   STUN direct: after STUN negotiation (UDP 3478), client sends UDP directly
#                to session host on dynamically negotiated ephemeral ports

# UDP 3478 – TURN relay + STUN negotiation (51.5.0.0/16 + WVD tag)
$turnPrefixes = @("51.5.0.0/16")
$wvdPrefixes  = $tagIPs["WindowsVirtualDesktop"]
if ($wvdPrefixes.Count -gt 0) {
    [string[]]$turnPrefixes = @(@($turnPrefixes) + @($wvdPrefixes) | Sort-Object -Unique)
}

New-FWRule -Name "AVD STUN-TURN (UDP 3478)" `
           -Description "AVD RDP Shortpath STUN negotiation + TURN relay – UDP 3478" `
           -Protocol UDP -RemotePort 3478 `
           -RemoteAddress $turnPrefixes

# UDP 1024-65535 – STUN direct connection to session hosts (ephemeral ports)
$cloudEUS2 = $tagIPs["AzureCloud.EastUS2"]
if ($cloudEUS2.Count -gt 0) {
    New-FWRule -Name "AVD STUN Direct (UDP 1024-65535 EastUS2)" `
               -Description "RDP Shortpath STUN direct – UDP to EastUS2 session hosts" `
               -Protocol UDP -RemotePort "1024-65535" `
               -RemoteAddress $cloudEUS2
}

# ---- Resolved FQDN rules ----

if ($resolved443.Count -gt 0) {
    New-FWRule -Name "Resolved FQDNs (TCP 443)" `
               -Description "DNS-resolved AVD-related FQDNs – HTTPS" `
               -Protocol TCP -RemotePort 443 `
               -RemoteAddress $resolved443
}

if ($resolved80.Count -gt 0) {
    New-FWRule -Name "Resolved FQDNs (TCP 80)" `
               -Description "DNS-resolved certificate / CRL / OCSP endpoints – HTTP" `
               -Protocol TCP -RemotePort 80 `
               -RemoteAddress $resolved80
}

# ── 7. Set default outbound to BLOCK on all profiles ────────────────────────
Write-Log ""
Write-Log "Setting default outbound action to BLOCK..."

# Create rules FIRST (above), then flip the policy so we don't lock out mid-setup
Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultOutboundAction Block
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
Write-Log "Default outbound policy set to BLOCK on Domain, Private, Public profiles." -Level SUCCESS

# ── 8. Summary ───────────────────────────────────────────────────────────────
Write-Log ""
Write-Log "============================================================" -Level SUCCESS
Write-Log "  AVD Firewall Lockdown  –  ENABLED" -Level SUCCESS
Write-Log "============================================================" -Level SUCCESS
Write-Log "  Total rules created : $script:ruleCount"
Write-Log "  Firewall backup     : $BackupPath"
Write-Log "  Log file            : $LogPath"
Write-Log ""
Write-Log "  Azure Service Tags used:"
foreach ($tag in $tagNames) {
    Write-Log "    $tag  ($($tagIPs[$tag].Count) prefixes)"
}
Write-Log ""
Write-Log "  IMPORTANT NOTES:"
Write-Log "    - DNS is allowed so AVD names can resolve."
Write-Log "    - Run  .\Set-AVDFirewall.ps1 -Disable  to remove all rules and restore defaults."
Write-Log "    - Re-run  .\Set-AVDFirewall.ps1 -Enable  periodically to refresh Azure IP ranges."
Write-Log "    - To restore the original firewall from backup:"
Write-Log "        netsh advfirewall import `"$BackupPath`""
Write-Log ""
Write-Log "===  Done  ===" -Level SUCCESS
