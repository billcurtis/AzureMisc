<#
    .DESCRIPTION
       This example script will go through a selected DNS zone and find all Dynamic DNS A records that have a SID as the owner. 
        It will then prompt the user to select which records to delete and which records to change the owner to the corresponding AD computer account.

    .PARAMETER dnsServerName
        The DNS server that you want to query for DNS records. Not mandatory if the script is run from a domain joined computer.
    .PARAMETER zoneName
        Mandatory. The DNS zone that you want to query for DNS records.
    .PARAMETER NetbiosDomainName
        The Netbios domain name of the domain that you want to query for DNS records. Not mandatory if the script is run from a domain joined computer.
    .PARAMETER csvpath
        The path to the csv file that you want to export the results to. Not mandatory.

    .EXAMPLE
        Get-DynamicDNSRecordInfo.ps1 -zoneName "contoso.com" -dnsServerName "dns.contoso.com" -NetbiosDomainName "contoso" -csvpath "c:\temp\DNSReport.csv"

    .NOTES    
        Requires the ActiveDirectory, DNSServer, and DNSClient PS modules.

#>

param (

    [Parameter(Mandatory = $false)]
    [string]$zoneName = (Get-ADDomain).DnsRoot,

    [Parameter(Mandatory = $false)]
    [string]$dnsServerName = (Get-ADDomain).ReplicaDirectoryServers[0],

    [Parameter(Mandatory = $false)]
    [string]$NetbiosDomainName = (Get-ADDomain).NetbiosName,

    [Parameter(Mandatory = $false)]
    [string]$csvpath = $null
)

# static variables

$dnsReport = @()

# import modules

$ErrorActionPreference = "stop"
try {
    Import-Module activedirectory
    Import-Module dnsserver
    Import-Module dnsclient
}
catch {
    Write-Error -Message "One or more required modules is missing. You must have the ActiveDirectory and DNSServer modules installed to use this script."
}

# set preferences

$ErrorActionPreference = "stop"
$VerbosePreference = "continue"

# get domain root

$domainRoot = (Get-ADDomain | Where-Object { $_.NetbiosName -eq $NetbiosDomainName }).DNSRoot

# get all dns resource records with RecordType of A and not set to static dns.

$dnsRecordsA = Get-DnsServerResourceRecord -ZoneName $zoneName -ComputerName $dnsServerName -RRType A | `
    Where-Object { $_.Timestamp -and $_.HostName -notcontains $domainRoot -and $_.HostName -notmatch '^ForestDnsZones$' -and $_.HostName -notmatch '^DomainDnsZones$' -and $_.HostName -notmatch '^@$' }


# get list of all reverse lookup zones 

$reverseZones = Get-DnsServerZone -ComputerName $dnsServerName | `
    Where-Object { $_.IsReverseLookupZone -and $_.ZoneName -notmatch "127.in-addr" -and $_.ZoneName -notmatch "255.in-addr" -and $_.ZoneName -notmatch "0.in-addr.arpa" }


# cycle through all DNS records and get the owners of the records and match an unknown sid

foreach ($dnsRecord in $dnsRecordsA) {

    $ptrRecordExist = $null
    $ptrDns = $null
    $aclDns = $null
    $computerAccountExists = $null

    # check to see if computer account exists in ad
    $computerAccount = $dnsrecord.Hostname.Replace($domainRoot, '')
    Write-Verbose -Message "Looking for Computer Account: $computerAccount"

    try {

        $getComputer = Get-AdComputer -Identity $computerAccount  
        if ($getComputer) { $computerAccountExists = $true }

    }
    catch {

        $computerAccountExists = $false

    }

    # get the reverse lookup zone

    Write-Verbose -Message "INFO: Processing DNS A Record: $($dnsRecord.HostName)"
    $aRecordIP = $dnsRecord.RecordData.IPv4Address.IPAddressToString
    $reversedIP = ($aRecordIP.Split('.') | ForEach-Object { $_ })[3..0] -join '.'

    # check to see if ptr record exists 

    Write-Verbose -Message "INFO: Resolving $reversedIP.in-addr.arpa)"
    $VerbosePreference = "silentlycontinue"       
    $ptrRecordExist = Resolve-DnsName -Name "$reversedIP.in-addr.arpa" -Type PTR -DnsOnly -ErrorAction SilentlyContinue 
    $VerbosePreference = "continue"

    # if record exists, let's check to see if hostname is identical

    if ($ptrRecordExist) {
        Write-Verbose -Message "INFO: $reversedIP.in-addr.arpa record exists and resolves to $($ptrRecordExist.NameHost)"
        if ( $dnsRecord.HostName -ne $domainRoot) {
            $ptrLookupName = $ptrRecordExist.NameHost.Replace($domainRoot, '')
            Write-Verbose -Message "INFO: PTR Record Name is: $ptrLookupName"
            if ($ptrLookupName -match ($dnsRecord.HostName).Replace($domainRoot, "")) {

                Write-Verbose -Message "INFO: $reversedIP.in-addr.arpa record exists and the hostname matches DNS A record $($dnsRecord.HostName)"
                $ptrExistForHostRecord = $true
                
                # ugly way of doing this, but cycle through all reverse lookup zones looking for record
    
                foreach ($reverseZone in $reverseZones) {

                    $params = @{

                        Computername = $dnsServerName
                        ZoneName     = $reverseZone.ZoneName
                        RRType       = 'Ptr'

                    }

                    $ptrDistinguishedName = Get-DnsServerResourceRecord @params
                    if ($ptrDistinguishedName) {
                        
                        $ptrDistinguishedName = ($ptrDistinguishedName | Where-Object { $_.RecordData.PtrDomainName -match $ptrLookupName })

                        if ($ptrDistinguishedName) {

                            $ptrDistinguishedName = $ptrDistinguishedName[0].DistinguishedName
                            $ptrDns = Get-Acl -Path "ActiveDirectory:://RootDSE/$($ptrDistinguishedName)" -ErrorAction SilentlyContinue

                            if ($ptrDns) {
                                if (($ptrDns.Owner).EndsWith('$')) { $ptrSID = ((Get-AdComputer -Identity $ptrDns.Owner.Split("\")[1]).Sid).AccountDomainSid.Value }      
                                elseif ($ptrDns.Owner -match "S-1-5-21") { $ptrSID = $ptrDns.Owner }
                                elseif ($ptrDns.Owner -match "\\" -and $ptrDns.Owner -notmatch '\$$') { 
   
                                    $ptrSID = Get-ADUser -Identity  $ptrDns.Owner.Split("\")[1].AccountDomainSid.Value

                                }
                        
                            }  
                                            
                        }  
      
                    }   

                }

            }
            else {
            
                Write-Verbose -Message "WARN: $reversedIP.in-addr.arpa record exists but the hostname does not match DNS A record $($dnsRecord.HostName). Likely a stale record."
                $ptrExistForHostRecord = $false
            
            }

        }

    }

    # evaluate the owner of the dns record

    $aclDns = Get-Acl -Path "ActiveDirectory:://RootDSE/$($dnsRecord.DistinguishedName)" -ErrorAction SilentlyContinue
    if ($aclDns) {

        try {

            
            if (($aclDns.Owner).EndsWith('$')) {            
                Write-Verbose -Message "INFO: Querying Active Directory for $($aclDns.Owner)"
                $aclSID = ((Get-AdComputer -Identity $aclDns.Owner.Split("\")[1]).Sid).Value
                $ADAccountExists = $true
                if (($aclDns.Owner.Split("\")[1]).Sid -notmatch $dnsRecord.HostName) {
                    $RecordOwnerMismatch = $false
                }
                else { $RecordOwnerMismatch = $true }
                        
            }
            elseif ($aclDns.Owner -match "S-1-5-21") {
                Write-Verbose -Message "WARN: $($aclDns.Owner) is a orphan SID" 
                $aclSID = "Does not exist - Orphaned SID?" 
                $ADAccountExists = $false
                $RecordOwnerMismatch = 'Not Applicable'

            }
            elseif ($aclDns.Owner -match "\\" -and $aclDns.Owner -notmatch '\$$') { 
                Write-Verbose -Message "INFO: $($aclDns.Owner) is a user account"
                Write-Verbose -Message "INFO: Querying AD for AD User:$($aclDns.Owner) "
                $aclSID = (Get-ADUser -Identity($aclDns.Owner.Split("\")[1])).SID
                $ADAccountExists = $true
                $RecordOwnerMismatch = $true
            }           
            elseif (!$aclSID) { $ADAccountExists = $false }
        }
        catch {
            Write-Verbose -Message "ERROR: $_"
            $aclSID = "Does not exist"            
            $ADAccountExists = $false
            $RecordOwnerMismatch = "Not Applicable Due to Lookup Error"

        }

        # add to report

        $dnsReport += [pscustomobject]@{

            Hostname                                    = $dnsRecord.HostName            
            ARecordOwner                                = $aclDns.Owner
            'AD Account Exists for A Record'            = $ADAccountExists
            'Computer Account Not Match A Record'       = $RecordOwnerMismatch
            'Matching Computer Account Exists'          = $computerAccountExists
            'Remediate Account Match'                   = $false
            'Reverse Lookup Exists for A Record'        = $ptrExistForHostRecord 
            'AD Account SID'                            = $aclSID            
            PTROwner                                    = $ptrDns.Owner
            DNSServername                               = $dnsServerName
            DNSZone                                     = $zoneName
            NetBiosDomainName                           = $NetbiosDomainName
            'A Record DistinguishedName'                = $dnsRecord.DistinguishedName
            'Reverse Lookup Account Distinguished Name' = $ptrDistinguishedName             

        }


    }


}


# output to gridview for quick results
$dnsReport | Out-GridView


# output to csv if csvpath is specified
if ($csvpath) {
    
    Write-Verbose -Message "Writing CSV file to: $csvpath"
    $dnsReport | Export-Csv -Path $csvpath -NoTypeInformation -Force -NoClobber 
}

$VerbosePreference = "silentlycontinue"