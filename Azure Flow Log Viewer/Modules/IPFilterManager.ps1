#Requires -Version 5.1
<#
.SYNOPSIS
    IP Filter Manager Module
.DESCRIPTION
    Handles IP address and CIDR range exclusions for flow log filtering
    Uses a radix tree (trie) for O(1) CIDR range lookups
#>

# Radix Tree Node class for fast CIDR matching
class IPRadixNode {
    [IPRadixNode]$Left   # 0 bit
    [IPRadixNode]$Right  # 1 bit
    [bool]$IsTerminal    # True if this node represents an excluded network
    
    IPRadixNode() {
        $this.Left = $null
        $this.Right = $null
        $this.IsTerminal = $false
    }
}

function New-IPRadixTree {
    <#
    .SYNOPSIS
        Creates a new radix tree from a list of CIDR ranges
    .DESCRIPTION
        Builds a binary trie where each CIDR range marks a terminal node.
        Lookup is O(32) - constant time regardless of number of ranges.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [array]$CIDRRanges = @(),
        
        [Parameter(Mandatory = $false)]
        [scriptblock]$ProgressCallback = $null
    )
    
    $root = [IPRadixNode]::new()
    $addedCount = 0
    $totalCount = $CIDRRanges.Count
    
    foreach ($cidr in $CIDRRanges) {
        if ([string]::IsNullOrEmpty($cidr)) { continue }
        
        $addedCount++
        if ($ProgressCallback -and ($addedCount % 1000 -eq 0)) {
            & $ProgressCallback "Building IP tree: $addedCount / $totalCount ranges..."
        }
        
        try {
            $parts = $cidr -split '/'
            if ($parts.Count -ne 2) { continue }
            
            $networkIP = $parts[0]
            $prefixLength = [int]$parts[1]
            
            if ($prefixLength -lt 0 -or $prefixLength -gt 32) { continue }
            
            # Convert IP to 32-bit integer
            $ipBytes = ([System.Net.IPAddress]::Parse($networkIP)).GetAddressBytes()
            if ([BitConverter]::IsLittleEndian) {
                [Array]::Reverse($ipBytes)
            }
            $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)
            
            # Traverse/create tree based on prefix bits
            $node = $root
            for ($i = 31; $i -ge (32 - $prefixLength); $i--) {
                $bit = ($ipInt -shr $i) -band 1
                
                if ($bit -eq 0) {
                    if ($null -eq $node.Left) {
                        $node.Left = [IPRadixNode]::new()
                    }
                    $node = $node.Left
                }
                else {
                    if ($null -eq $node.Right) {
                        $node.Right = [IPRadixNode]::new()
                    }
                    $node = $node.Right
                }
                
                # If we hit a terminal node, this range is already covered
                if ($node.IsTerminal) { break }
            }
            
            # Mark this node as terminal (represents an excluded network)
            $node.IsTerminal = $true
        }
        catch {
            # Skip invalid CIDR
            continue
        }
    }
    
    return $root
}

function Test-IPInRadixTree {
    <#
    .SYNOPSIS
        Tests if an IP address matches any CIDR range in the radix tree
    .DESCRIPTION
        O(32) lookup - checks at most 32 bits regardless of tree size
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,
        
        [Parameter(Mandatory = $true)]
        [IPRadixNode]$Tree
    )
    
    try {
        # Convert IP to 32-bit integer
        $ipBytes = ([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
        if ([BitConverter]::IsLittleEndian) {
            [Array]::Reverse($ipBytes)
        }
        $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)
        
        # Traverse tree following IP bits
        $node = $Tree
        for ($i = 31; $i -ge 0; $i--) {
            if ($null -eq $node) { return $false }
            if ($node.IsTerminal) { return $true }  # Matched a network prefix
            
            $bit = ($ipInt -shr $i) -band 1
            
            if ($bit -eq 0) {
                $node = $node.Left
            }
            else {
                $node = $node.Right
            }
        }
        
        # Check final node
        return ($null -ne $node -and $node.IsTerminal)
    }
    catch {
        return $false
    }
}

function Test-ValidIP {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress
    )
    
    try {
        $null = [System.Net.IPAddress]::Parse($IPAddress)
        return $true
    }
    catch {
        return $false
    }
}

function Test-ValidCIDR {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CIDR
    )
    
    try {
        if ($CIDR -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') {
            $ip = $Matches[1]
            $prefix = [int]$Matches[2]
            
            if ($prefix -lt 0 -or $prefix -gt 32) {
                return $false
            }
            
            return Test-ValidIP -IPAddress $ip
        }
        return $false
    }
    catch {
        return $false
    }
}

function Test-IPInRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,
        
        [Parameter(Mandatory = $true)]
        [string]$CIDR
    )
    
    try {
        if (-not (Test-ValidIP -IPAddress $IPAddress)) {
            return $false
        }
        
        if (-not (Test-ValidCIDR -CIDR $CIDR)) {
            return $false
        }
        
        $parts = $CIDR -split '/'
        $networkIP = $parts[0]
        $prefixLength = [int]$parts[1]
        
        # Convert IPs to integers
        $ipBytes = ([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
        $networkBytes = ([System.Net.IPAddress]::Parse($networkIP)).GetAddressBytes()
        
        # Reverse for little-endian systems
        if ([BitConverter]::IsLittleEndian) {
            [Array]::Reverse($ipBytes)
            [Array]::Reverse($networkBytes)
        }
        
        $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)
        $networkInt = [BitConverter]::ToUInt32($networkBytes, 0)
        
        # Create subnet mask
        $mask = [uint32]::MaxValue -shl (32 - $prefixLength)
        
        # Check if IP is in range
        return ($ipInt -band $mask) -eq ($networkInt -band $mask)
    }
    catch {
        Write-Warning "Error checking IP in range: $_"
        return $false
    }
}

function Test-IPExcluded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress,
        
        [Parameter(Mandatory = $false)]
        [array]$ExcludedIPs = @(),
        
        [Parameter(Mandatory = $false)]
        [array]$ExcludedRanges = @()
    )
    
    # Check if IP is in the excluded IPs list
    if ($ExcludedIPs -contains $IPAddress) {
        return $true
    }
    
    # Check if IP is in any excluded CIDR range
    foreach ($range in $ExcludedRanges) {
        if (Test-IPInRange -IPAddress $IPAddress -CIDR $range) {
            return $true
        }
    }
    
    return $false
}

function Apply-IPExclusions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$FlowData,
        
        [Parameter(Mandatory = $false)]
        [array]$ExcludedIPs = @(),
        
        [Parameter(Mandatory = $false)]
        [array]$ExcludedRanges = @(),
        
        [Parameter(Mandatory = $false)]
        [scriptblock]$ProgressCallback = $null
    )
    
    # Handle null or empty input
    if ($null -eq $FlowData -or $FlowData.Count -eq 0) {
        return @()
    }
    
    if (($ExcludedIPs.Count -eq 0) -and ($ExcludedRanges.Count -eq 0)) {
        return @($FlowData)
    }
    
    # Build a hashtable of excluded IPs for O(1) lookup
    if ($ProgressCallback) { & $ProgressCallback "Building IP exclusion hashtable ($($ExcludedIPs.Count) IPs)..." }
    $excludedIPHash = @{}
    foreach ($ip in $ExcludedIPs) {
        if (-not [string]::IsNullOrEmpty($ip)) {
            $excludedIPHash[$ip] = $true
        }
    }
    
    # Build radix tree for O(1) CIDR range lookups
    if ($ProgressCallback) { & $ProgressCallback "Building IP radix tree for $($ExcludedRanges.Count) CIDR ranges..." }
    $radixTree = New-IPRadixTree -CIDRRanges $ExcludedRanges -ProgressCallback $ProgressCallback
    $hasRanges = $ExcludedRanges.Count -gt 0
    
    $filteredData = [System.Collections.ArrayList]@()
    $totalRecords = $FlowData.Count
    $processedCount = 0
    $lastProgressUpdate = 0
    $excludedCount = 0
    
    if ($ProgressCallback) { & $ProgressCallback "Filtering $totalRecords records (using radix tree for fast CIDR matching)..." }

    foreach ($record in $FlowData) {
        $processedCount++
        
        # Update progress every 5000 records
        if ($ProgressCallback -and ($processedCount - $lastProgressUpdate -ge 5000 -or $processedCount -eq $totalRecords)) {
            $pct = [math]::Round(($processedCount / $totalRecords) * 100, 1)
            & $ProgressCallback "Filtering records: $processedCount / $totalRecords ($pct%) - $excludedCount excluded..."
            $lastProgressUpdate = $processedCount
        }
        
        $sourceExcluded = $false
        $destExcluded = $false
        
        # Quick check against excluded IPs hashtable - O(1)
        if ($record.SourceIP -and $excludedIPHash.ContainsKey($record.SourceIP)) {
            $sourceExcluded = $true
        }
        if ($record.DestinationIP -and $excludedIPHash.ContainsKey($record.DestinationIP)) {
            $destExcluded = $true
        }
        
        # Check against CIDR ranges using radix tree - O(32) constant time
        if ($hasRanges) {
            if (-not $sourceExcluded -and $record.SourceIP) {
                $sourceExcluded = Test-IPInRadixTree -IPAddress $record.SourceIP -Tree $radixTree
            }
            
            if (-not $destExcluded -and $record.DestinationIP) {
                $destExcluded = Test-IPInRadixTree -IPAddress $record.DestinationIP -Tree $radixTree
            }
        }
        
        # Include record only if neither source nor destination is excluded
        if (-not $sourceExcluded -and -not $destExcluded) {
            $null = $filteredData.Add($record)
        }
        else {
            $excludedCount++
        }
    }
    
    if ($ProgressCallback) { & $ProgressCallback "Filtering complete. $excludedCount records excluded, $($filteredData.Count) remaining." }
    
    return @($filteredData)
}

function Get-CommonPrivateRanges {
    <#
    .SYNOPSIS
        Returns common private IP ranges for quick exclusion
    #>
    return @(
        [PSCustomObject]@{ Name = "RFC1918 Class A"; Range = "10.0.0.0/8" }
        [PSCustomObject]@{ Name = "RFC1918 Class B"; Range = "172.16.0.0/12" }
        [PSCustomObject]@{ Name = "RFC1918 Class C"; Range = "192.168.0.0/16" }
        [PSCustomObject]@{ Name = "Loopback"; Range = "127.0.0.0/8" }
        [PSCustomObject]@{ Name = "Link-Local"; Range = "169.254.0.0/16" }
        [PSCustomObject]@{ Name = "Azure Internal"; Range = "168.63.129.16/32" }
        [PSCustomObject]@{ Name = "Azure IMDS"; Range = "169.254.169.254/32" }
    )
}

function Export-Exclusions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        
        [Parameter(Mandatory = $false)]
        [array]$ExcludedIPs = @(),
        
        [Parameter(Mandatory = $false)]
        [array]$ExcludedRanges = @()
    )
    
    $exclusions = @{
        ExcludedIPs = $ExcludedIPs
        ExcludedRanges = $ExcludedRanges
        ExportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
    
    $exclusions | ConvertTo-Json -Depth 3 | Out-File -FilePath $FilePath -Encoding UTF8
}

function Import-Exclusions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )
    
    try {
        $content = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
        return @{
            ExcludedIPs = @($content.ExcludedIPs)
            ExcludedRanges = @($content.ExcludedRanges)
        }
    }
    catch {
        Write-Error "Error importing exclusions: $_"
        return @{
            ExcludedIPs = @()
            ExcludedRanges = @()
        }
    }
}
