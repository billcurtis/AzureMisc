#Requires -Version 5.1
<#
.SYNOPSIS
    IP Owner Lookup Module
.DESCRIPTION
    Performs WHOIS/ownership lookups for public IP addresses using the free ip-api.com service.
    Includes caching to minimize API calls and rate limiting to stay within free tier limits.
    
    API: http://ip-api.com
    - Batch endpoint: POST http://ip-api.com/batch (up to 100 IPs per request)
    - Free tier: 45 requests/minute (batch counts as 1 request)
    - No API key required
#>

# Script-level cache for IP owner lookups
if (-not $script:IPOwnerCache) {
    $script:IPOwnerCache = @{}
}

function Test-IsPrivateIP {
    <#
    .SYNOPSIS
        Tests whether an IP address is a private/reserved IP (not publicly routable)
    .DESCRIPTION
        Checks against RFC1918, loopback, link-local, multicast, and other reserved ranges
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress
    )
    
    try {
        $ip = [System.Net.IPAddress]::Parse($IPAddress)
        $bytes = $ip.GetAddressBytes()
        
        # IPv6 - treat as non-private for lookup purposes (unless loopback)
        if ($bytes.Count -gt 4) {
            return ($IPAddress -eq '::1')
        }
        
        $first = [int]$bytes[0]
        $second = [int]$bytes[1]
        
        # 10.0.0.0/8 - RFC1918 Class A private
        if ($first -eq 10) { return $true }
        
        # 172.16.0.0/12 - RFC1918 Class B private
        if ($first -eq 172 -and $second -ge 16 -and $second -le 31) { return $true }
        
        # 192.168.0.0/16 - RFC1918 Class C private
        if ($first -eq 192 -and $second -eq 168) { return $true }
        
        # 127.0.0.0/8 - Loopback
        if ($first -eq 127) { return $true }
        
        # 169.254.0.0/16 - Link-local
        if ($first -eq 169 -and $second -eq 254) { return $true }
        
        # 0.0.0.0/8 - Current network
        if ($first -eq 0) { return $true }
        
        # 100.64.0.0/10 - Carrier-grade NAT (RFC6598)
        if ($first -eq 100 -and $second -ge 64 -and $second -le 127) { return $true }
        
        # 192.0.0.0/24 - IETF Protocol Assignments
        if ($first -eq 192 -and $second -eq 0 -and [int]$bytes[2] -eq 0) { return $true }
        
        # 192.0.2.0/24 - TEST-NET-1
        if ($first -eq 192 -and $second -eq 0 -and [int]$bytes[2] -eq 2) { return $true }
        
        # 198.51.100.0/24 - TEST-NET-2
        if ($first -eq 198 -and $second -eq 51 -and [int]$bytes[2] -eq 100) { return $true }
        
        # 203.0.113.0/24 - TEST-NET-3
        if ($first -eq 203 -and $second -eq 0 -and [int]$bytes[2] -eq 113) { return $true }
        
        # 224.0.0.0/4 - Multicast
        if ($first -ge 224 -and $first -le 239) { return $true }
        
        # 240.0.0.0/4 - Reserved for future use
        if ($first -ge 240) { return $true }
        
        # 168.63.129.16/32 - Azure internal
        if ($first -eq 168 -and $second -eq 63 -and [int]$bytes[2] -eq 129 -and [int]$bytes[3] -eq 16) { return $true }
        
        return $false
    }
    catch {
        return $false
    }
}

function Get-IPOwnerInfo {
    <#
    .SYNOPSIS
        Looks up ownership information for a single public IP address
    .DESCRIPTION
        Uses ip-api.com to retrieve ISP, organization, AS number, and country information.
        Results are cached to avoid redundant API calls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress
    )
    
    # Check cache first
    if ($script:IPOwnerCache.ContainsKey($IPAddress)) {
        return $script:IPOwnerCache[$IPAddress]
    }
    
    # Skip private IPs
    if (Test-IsPrivateIP -IPAddress $IPAddress) {
        $result = [PSCustomObject]@{
            IP      = $IPAddress
            Owner   = "Private/Reserved"
            ISP     = "N/A"
            Org     = "N/A"
            AS      = "N/A"
            Country = "N/A"
            City    = "N/A"
            Status  = "private"
        }
        $script:IPOwnerCache[$IPAddress] = $result
        return $result
    }
    
    try {
        $response = Invoke-RestMethod -Uri "http://ip-api.com/json/$($IPAddress)?fields=status,message,country,city,isp,org,as,query" -TimeoutSec 10
        
        if ($response.status -eq 'success') {
            $result = [PSCustomObject]@{
                IP      = $IPAddress
                Owner   = $response.org
                ISP     = $response.isp
                Org     = $response.org
                AS      = $response.as
                Country = $response.country
                City    = $response.city
                Status  = "success"
            }
        }
        else {
            $result = [PSCustomObject]@{
                IP      = $IPAddress
                Owner   = "Lookup failed"
                ISP     = "N/A"
                Org     = "N/A"
                AS      = "N/A"
                Country = "N/A"
                City    = "N/A"
                Status  = "failed"
            }
        }
        
        $script:IPOwnerCache[$IPAddress] = $result
        return $result
    }
    catch {
        $result = [PSCustomObject]@{
            IP      = $IPAddress
            Owner   = "Error: $($_.Exception.Message)"
            ISP     = "N/A"
            Org     = "N/A"
            AS      = "N/A"
            Country = "N/A"
            City    = "N/A"
            Status  = "error"
        }
        $script:IPOwnerCache[$IPAddress] = $result
        return $result
    }
}

function Get-BulkIPOwnerInfo {
    <#
    .SYNOPSIS
        Performs bulk IP ownership lookups for multiple public IPs
    .DESCRIPTION
        Uses ip-api.com batch endpoint (up to 100 IPs per request).
        Automatically filters out private IPs and uses cache to minimize API calls.
        Includes rate limiting to stay within free tier limits (45 req/min).
    .PARAMETER IPAddresses
        Array of IP addresses to look up
    .PARAMETER ProgressCallback
        Optional scriptblock called with progress messages
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$IPAddresses,
        
        [Parameter(Mandatory = $false)]
        [scriptblock]$ProgressCallback = $null
    )
    
    $results = @{}
    $publicIPs = [System.Collections.ArrayList]@()
    
    if ($ProgressCallback) { & $ProgressCallback "Analyzing $($IPAddresses.Count) IP addresses..." }
    
    foreach ($ip in $IPAddresses) {
        if ([string]::IsNullOrEmpty($ip)) { continue }
        
        # Check cache first
        if ($script:IPOwnerCache.ContainsKey($ip)) {
            $results[$ip] = $script:IPOwnerCache[$ip]
            continue
        }
        
        # Classify private vs public
        if (Test-IsPrivateIP -IPAddress $ip) {
            $privateResult = [PSCustomObject]@{
                IP      = $ip
                Owner   = "Private/Reserved"
                ISP     = "N/A"
                Org     = "N/A"
                AS      = "N/A"
                Country = "N/A"
                City    = "N/A"
                Status  = "private"
            }
            $script:IPOwnerCache[$ip] = $privateResult
            $results[$ip] = $privateResult
        }
        else {
            $null = $publicIPs.Add($ip)
        }
    }
    
    $cachedCount = $results.Count
    $publicCount = $publicIPs.Count
    
    if ($ProgressCallback) { 
        & $ProgressCallback "Found $publicCount public IPs to look up ($cachedCount already cached/private)..." 
    }
    
    if ($publicCount -eq 0) {
        return $results
    }
    
    # Process in batches of 100 (ip-api.com batch limit)
    $batchSize = 100
    $totalBatches = [math]::Ceiling($publicCount / $batchSize)
    $processedCount = 0
    
    for ($i = 0; $i -lt $publicCount; $i += $batchSize) {
        $batchNum = [math]::Floor($i / $batchSize) + 1
        $batch = $publicIPs[$i..([math]::Min($i + $batchSize - 1, $publicCount - 1))]
        
        if ($ProgressCallback) { 
            & $ProgressCallback "Looking up batch $batchNum of $totalBatches ($($batch.Count) IPs)..." 
        }
        
        try {
            # Build batch request body
            $batchBody = $batch | ForEach-Object {
                @{ query = $_; fields = "status,message,country,city,isp,org,as,query" }
            }
            
            $jsonBody = $batchBody | ConvertTo-Json -Depth 3
            # Ensure it's always an array in JSON even for single item
            if ($batch.Count -eq 1) {
                $jsonBody = "[$jsonBody]"
            }
            
            $response = Invoke-RestMethod -Uri "http://ip-api.com/batch?fields=status,message,country,city,isp,org,as,query" `
                -Method Post `
                -ContentType "application/json" `
                -Body $jsonBody `
                -TimeoutSec 30
            
            foreach ($entry in $response) {
                $ipAddr = $entry.query
                
                if ($entry.status -eq 'success') {
                    $result = [PSCustomObject]@{
                        IP      = $ipAddr
                        Owner   = $entry.org
                        ISP     = $entry.isp
                        Org     = $entry.org
                        AS      = $entry.as
                        Country = $entry.country
                        City    = $entry.city
                        Status  = "success"
                    }
                }
                else {
                    $result = [PSCustomObject]@{
                        IP      = $ipAddr
                        Owner   = "Lookup failed"
                        ISP     = "N/A"
                        Org     = "N/A"
                        AS      = "N/A"
                        Country = "N/A"
                        City    = "N/A"
                        Status  = "failed"
                    }
                }
                
                $script:IPOwnerCache[$ipAddr] = $result
                $results[$ipAddr] = $result
                $processedCount++
            }
        }
        catch {
            # If batch fails, mark all IPs in batch as error
            foreach ($ipAddr in $batch) {
                if (-not $results.ContainsKey($ipAddr)) {
                    $result = [PSCustomObject]@{
                        IP      = $ipAddr
                        Owner   = "Batch lookup error"
                        ISP     = "N/A"
                        Org     = "N/A"
                        AS      = "N/A"
                        Country = "N/A"
                        City    = "N/A"
                        Status  = "error"
                    }
                    $script:IPOwnerCache[$ipAddr] = $result
                    $results[$ipAddr] = $result
                    $processedCount++
                }
            }
            
            if ($ProgressCallback) { 
                & $ProgressCallback "Batch $batchNum failed: $($_.Exception.Message)" 
            }
        }
        
        # Rate limiting - wait 1.5 seconds between batches to stay under 45 req/min
        if ($i + $batchSize -lt $publicCount) {
            if ($ProgressCallback) { 
                & $ProgressCallback "Rate limiting pause... ($processedCount of $publicCount IPs done)" 
            }
            Start-Sleep -Milliseconds 1500
        }
    }
    
    if ($ProgressCallback) { 
        & $ProgressCallback "IP owner lookup complete. $processedCount public IPs resolved." 
    }
    
    return $results
}

function Clear-IPOwnerCache {
    <#
    .SYNOPSIS
        Clears the IP owner lookup cache
    #>
    $script:IPOwnerCache = @{}
}
