#Requires -Version 5.1
<#
.SYNOPSIS
    Flow Log Parser Module
.DESCRIPTION
    Parses Azure Flow Log JSON data into structured objects
    Supports both NSG Flow Logs (Version 2) and VNET Flow Logs (Version 4)
#>

function Parse-FlowLogJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $JsonContent,
        
        [Parameter(Mandatory = $false)]
        [string]$BlobPath = ""
    )
    
    $flowRecords = [System.Collections.ArrayList]@()
    
    try {
        if ($JsonContent.records) {
            foreach ($record in $JsonContent.records) {
                $recordTime = if ($record.time) { [DateTime]::Parse($record.time) } else { Get-Date }
                $macAddress = $record.macAddress
                $resourceId = if ($record.targetResourceID) { $record.targetResourceID } else { $record.resourceId }
                $category = $record.category
                $flowLogVersion = $record.flowLogVersion
                
                # VNET Flow Logs (Version 4) - uses flowRecords.flows
                if ($record.flowRecords -and $record.flowRecords.flows) {
                    foreach ($flow in $record.flowRecords.flows) {
                        $aclId = $flow.aclID
                        
                        # VNET uses flowGroups instead of flows
                        if ($flow.flowGroups) {
                            foreach ($flowGroup in $flow.flowGroups) {
                                $ruleName = $flowGroup.rule
                                
                                # flowTuples is a SPACE-SEPARATED STRING in VNET flow logs!
                                if ($flowGroup.flowTuples) {
                                    $tuples = $flowGroup.flowTuples -split ' '
                                    foreach ($tuple in $tuples) {
                                        if (-not [string]::IsNullOrWhiteSpace($tuple)) {
                                            $parsed = Parse-FlowTuple -Tuple $tuple -RuleName $ruleName -MacAddress $macAddress -ResourceId $resourceId -FlowLogVersion $flowLogVersion
                                            if ($parsed) {
                                                $null = $flowRecords.Add($parsed)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                # NSG Flow Logs (Version 2) - uses properties.flows
                elseif ($record.properties -and $record.properties.flows) {
                    foreach ($flow in $record.properties.flows) {
                        $ruleName = $flow.rule
                        
                        if ($flow.flows) {
                            foreach ($flowGroup in $flow.flows) {
                                $mac = $flowGroup.mac
                                
                                if ($flowGroup.flowTuples) {
                                    # flowTuples is an array in NSG flow logs
                                    $tuples = if ($flowGroup.flowTuples -is [array]) { $flowGroup.flowTuples } else { @($flowGroup.flowTuples -split ' ') }
                                    foreach ($tuple in $tuples) {
                                        if (-not [string]::IsNullOrWhiteSpace($tuple)) {
                                            $parsed = Parse-FlowTuple -Tuple $tuple -RuleName $ruleName -MacAddress ($mac ?? $macAddress) -ResourceId $resourceId -FlowLogVersion 2
                                            if ($parsed) {
                                                $null = $flowRecords.Add($parsed)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Warning "Error parsing flow log JSON: $($_.Exception.Message)"
    }
    
    return @($flowRecords)
}

function Parse-FlowTuple {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tuple,
        
        [Parameter(Mandatory = $false)]
        [string]$RuleName = "",
        
        [Parameter(Mandatory = $false)]
        [string]$MacAddress = "",
        
        [Parameter(Mandatory = $false)]
        [string]$ResourceId = "",
        
        [Parameter(Mandatory = $false)]
        [int]$FlowLogVersion = 2
    )
    
    try {
        # VNET Flow Log format (Version 4):
        # Timestamp_ms,Source_IP,Dest_IP,Source_Port,Dest_Port,Protocol,Direction,Decision,Flow_State,Packets_S2D,Bytes_S2D,Packets_D2S,Bytes_D2S
        # Example: 1770152393932,10.2.0.15,20.62.132.27,53312,443,6,O,E,NX,15,3027,17,10709
        # Protocol: 6 = TCP, 17 = UDP
        # Flow State: NX = No encryption, X = Encrypted
        # Timestamp is in MILLISECONDS (13 digits)
        
        # NSG Flow Log format (Version 2):
        # Unix_Timestamp,Source_IP,Dest_IP,Source_Port,Dest_Port,Protocol,Direction,Decision,Flow_State,Packets_S2D,Bytes_S2D,Packets_D2S,Bytes_D2S
        # Example: 1705312800,10.0.0.4,13.107.42.14,49152,443,T,O,A,B,1,100,1,200
        # Protocol: T = TCP, U = UDP
        # Timestamp is in SECONDS (10 digits)
        
        $parts = $Tuple -split ','
        
        if ($parts.Count -lt 8) {
            return $null
        }
        
        # Parse timestamp - check if milliseconds (13 digits) or seconds (10 digits)
        $rawTimestamp = [long]$parts[0]
        if ($rawTimestamp -gt 9999999999999) {
            # More than 13 digits - likely microseconds, convert to milliseconds
            $timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds($rawTimestamp / 1000).LocalDateTime
        } elseif ($rawTimestamp -gt 999999999999) {
            # 13 digits - milliseconds (VNET flow logs)
            $timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds($rawTimestamp).LocalDateTime
        } else {
            # 10 digits - seconds (NSG flow logs)
            $timestamp = [DateTimeOffset]::FromUnixTimeSeconds($rawTimestamp).LocalDateTime
        }
        
        # Parse basic fields
        $sourceIP = $parts[1]
        $destIP = $parts[2]
        $sourcePort = if ($parts[3] -ne '') { [int]$parts[3] } else { 0 }
        $destPort = if ($parts[4] -ne '') { [int]$parts[4] } else { 0 }
        
        # Protocol: T/6 = TCP, U/17 = UDP (VNET uses numbers, NSG uses letters)
        $protocol = switch ($parts[5]) {
            'T' { 'TCP' }
            'U' { 'UDP' }
            '6' { 'TCP' }
            '17' { 'UDP' }
            '1' { 'ICMP' }
            default { $parts[5] }
        }
        
        # Traffic flow direction: I = Inbound, O = Outbound
        $direction = $parts[6]
        $directionFull = switch ($parts[6]) {
            'I' { 'Inbound' }
            'O' { 'Outbound' }
            default { $parts[6] }
        }
        
        # Traffic decision: A = Allowed, D = Denied, B = Begin, E = End, C = Continuing (VNET uses B/C/E in field 7)
        $action = $parts[7]
        $actionFull = switch ($parts[7]) {
            'A' { 'Allowed' }
            'D' { 'Denied' }
            'B' { 'Begin' }       # VNET flow log - connection begin
            'C' { 'Continuing' }  # VNET flow log - connection continuing
            'E' { 'End' }         # VNET flow log - connection end
            default { $parts[7] }
        }
        
        # Flow state - position 8
        $flowState = if ($parts.Count -gt 8) { $parts[8] } else { '' }
        $flowStateFull = switch ($flowState) {
            'B' { 'Begin' }
            'C' { 'Continuing' }
            'E' { 'End' }
            'NX' { 'No Encryption' }
            'X' { 'Encrypted' }
            default { $flowState }
        }
        
        $packetsSourceToDest = if ($parts.Count -gt 9 -and $parts[9] -ne '') { [long]$parts[9] } else { 0 }
        $bytesSourceToDest = if ($parts.Count -gt 10 -and $parts[10] -ne '') { [long]$parts[10] } else { 0 }
        $packetsDestToSource = if ($parts.Count -gt 11 -and $parts[11] -ne '') { [long]$parts[11] } else { 0 }
        $bytesDestToSource = if ($parts.Count -gt 12 -and $parts[12] -ne '') { [long]$parts[12] } else { 0 }
        
        $totalBytes = $bytesSourceToDest + $bytesDestToSource
        $totalPackets = $packetsSourceToDest + $packetsDestToSource
        
        return [PSCustomObject]@{
            Timestamp           = $timestamp
            SourceIP            = $sourceIP
            SourcePort          = $sourcePort
            DestinationIP       = $destIP
            DestinationPort     = $destPort
            Protocol            = $protocol
            Direction           = $direction
            DirectionFull       = $directionFull
            Action              = $action
            ActionFull          = $actionFull
            FlowState           = $flowState
            FlowStateFull       = $flowStateFull
            PacketsSourceToDest = $packetsSourceToDest
            BytesSourceToDest   = $bytesSourceToDest
            PacketsDestToSource = $packetsDestToSource
            BytesDestToSource   = $bytesDestToSource
            TotalBytes          = $totalBytes
            TotalPackets        = $totalPackets
            RuleName            = $RuleName
            MacAddress          = $MacAddress
            ResourceId          = $ResourceId
            Date                = $timestamp.Date
            Hour                = $timestamp.Hour
            Month               = $timestamp.ToString("yyyy-MM")
            Day                 = $timestamp.ToString("yyyy-MM-dd")
        }
    }
    catch {
        Write-Warning "Error parsing flow tuple: $_"
        return $null
    }
}

function Get-IPSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Data
    )
    
    # Get unique IPs and their statistics
    $sourceIPs = $Data | Group-Object -Property SourceIP | ForEach-Object {
        $group = $_.Group
        [PSCustomObject]@{
            IPAddress       = $_.Name
            Type            = "Source"
            ConnectionCount = $_.Count
            TotalBytesSent  = ($group | Measure-Object -Property BytesSourceToDest -Sum).Sum
            TotalBytesRecv  = ($group | Measure-Object -Property BytesDestToSource -Sum).Sum
            TotalBytes      = ($group | Measure-Object -Property TotalBytes -Sum).Sum
            TotalPackets    = ($group | Measure-Object -Property TotalPackets -Sum).Sum
            UniqueDestIPs   = ($group | Select-Object -ExpandProperty DestinationIP -Unique).Count
            FirstSeen       = ($group | Measure-Object -Property Timestamp -Minimum).Minimum
            LastSeen        = ($group | Measure-Object -Property Timestamp -Maximum).Maximum
        }
    }
    
    $destIPs = $Data | Group-Object -Property DestinationIP | ForEach-Object {
        $group = $_.Group
        [PSCustomObject]@{
            IPAddress       = $_.Name
            Type            = "Destination"
            ConnectionCount = $_.Count
            TotalBytesSent  = ($group | Measure-Object -Property BytesSourceToDest -Sum).Sum
            TotalBytesRecv  = ($group | Measure-Object -Property BytesDestToSource -Sum).Sum
            TotalBytes      = ($group | Measure-Object -Property TotalBytes -Sum).Sum
            TotalPackets    = ($group | Measure-Object -Property TotalPackets -Sum).Sum
            UniqueSourceIPs = ($group | Select-Object -ExpandProperty SourceIP -Unique).Count
            FirstSeen       = ($group | Measure-Object -Property Timestamp -Minimum).Minimum
            LastSeen        = ($group | Measure-Object -Property Timestamp -Maximum).Maximum
        }
    }
    
    # Combine all unique IPs
    $allIPs = @{}
    
    foreach ($ip in $sourceIPs) {
        $allIPs[$ip.IPAddress] = [PSCustomObject]@{
            IPAddress        = $ip.IPAddress
            AsSource         = $ip.ConnectionCount
            AsDestination    = 0
            TotalConnections = $ip.ConnectionCount
            TotalBytesSent   = $ip.TotalBytesSent
            TotalBytesRecv   = $ip.TotalBytesRecv
            TotalBytes       = $ip.TotalBytes
            TotalBytesFormatted = Format-ByteSize -Bytes $ip.TotalBytes
            TotalPackets     = $ip.TotalPackets
            FirstSeen        = $ip.FirstSeen
            LastSeen         = $ip.LastSeen
        }
    }
    
    foreach ($ip in $destIPs) {
        if ($allIPs.ContainsKey($ip.IPAddress)) {
            $existing = $allIPs[$ip.IPAddress]
            $allIPs[$ip.IPAddress] = [PSCustomObject]@{
                IPAddress        = $ip.IPAddress
                AsSource         = $existing.AsSource
                AsDestination    = $ip.ConnectionCount
                TotalConnections = $existing.TotalConnections + $ip.ConnectionCount
                TotalBytesSent   = $existing.TotalBytesSent + $ip.TotalBytesSent
                TotalBytesRecv   = $existing.TotalBytesRecv + $ip.TotalBytesRecv
                TotalBytes       = $existing.TotalBytes + $ip.TotalBytes
                TotalBytesFormatted = Format-ByteSize -Bytes ($existing.TotalBytes + $ip.TotalBytes)
                TotalPackets     = $existing.TotalPackets + $ip.TotalPackets
                FirstSeen        = if ($ip.FirstSeen -lt $existing.FirstSeen) { $ip.FirstSeen } else { $existing.FirstSeen }
                LastSeen         = if ($ip.LastSeen -gt $existing.LastSeen) { $ip.LastSeen } else { $existing.LastSeen }
            }
        }
        else {
            $allIPs[$ip.IPAddress] = [PSCustomObject]@{
                IPAddress        = $ip.IPAddress
                AsSource         = 0
                AsDestination    = $ip.ConnectionCount
                TotalConnections = $ip.ConnectionCount
                TotalBytesSent   = $ip.TotalBytesSent
                TotalBytesRecv   = $ip.TotalBytesRecv
                TotalBytes       = $ip.TotalBytes
                TotalBytesFormatted = Format-ByteSize -Bytes $ip.TotalBytes
                TotalPackets     = $ip.TotalPackets
                FirstSeen        = $ip.FirstSeen
                LastSeen         = $ip.LastSeen
            }
        }
    }
    
    return $allIPs.Values | Sort-Object -Property TotalBytes -Descending
}

function Get-TimeSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Data,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet("Hourly", "Daily", "Monthly")]
        [string]$GroupBy
    )
    
    $groupProperty = switch ($GroupBy) {
        "Hourly" { { $_.Timestamp.ToString("yyyy-MM-dd HH:00") } }
        "Daily" { { $_.Day } }
        "Monthly" { { $_.Month } }
    }
    
    $summary = $Data | Group-Object -Property $groupProperty | ForEach-Object {
        $group = $_.Group
        [PSCustomObject]@{
            Period              = $_.Name
            TotalConnections    = $_.Count
            TotalBytes          = ($group | Measure-Object -Property TotalBytes -Sum).Sum
            TotalBytesFormatted = Format-ByteSize -Bytes ($group | Measure-Object -Property TotalBytes -Sum).Sum
            TotalPackets        = ($group | Measure-Object -Property TotalPackets -Sum).Sum
            BytesSent           = ($group | Measure-Object -Property BytesSourceToDest -Sum).Sum
            BytesReceived       = ($group | Measure-Object -Property BytesDestToSource -Sum).Sum
            UniqueSourceIPs     = ($group | Select-Object -ExpandProperty SourceIP -Unique).Count
            UniqueDestIPs       = ($group | Select-Object -ExpandProperty DestinationIP -Unique).Count
            AllowedCount        = ($group | Where-Object { $_.Action -eq 'A' }).Count
            DeniedCount         = ($group | Where-Object { $_.Action -eq 'D' }).Count
            InboundCount        = ($group | Where-Object { $_.Direction -eq 'I' }).Count
            OutboundCount       = ($group | Where-Object { $_.Direction -eq 'O' }).Count
        }
    } | Sort-Object -Property Period
    
    return $summary
}

function Get-FlowDataForPeriod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Data,
        
        [Parameter(Mandatory = $true)]
        [string]$Period,
        
        [Parameter(Mandatory = $true)]
        [string]$GroupBy
    )
    
    $filterProperty = switch ($GroupBy) {
        "Hourly" { { $_.Timestamp.ToString("yyyy-MM-dd HH:00") } }
        "Daily" { { $_.Day } }
        "Monthly" { { $_.Month } }
    }
    
    $periodData = $Data | Where-Object { (& $filterProperty) -eq $Period }
    
    # Return IP summary for this period
    return Get-IPSummary -Data $periodData
}

function Format-ByteSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )
    
    if ($Bytes -ge 1TB) {
        return "{0:N2} TB" -f ($Bytes / 1TB)
    }
    elseif ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }
    elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }
    else {
        return "$Bytes B"
    }
}
