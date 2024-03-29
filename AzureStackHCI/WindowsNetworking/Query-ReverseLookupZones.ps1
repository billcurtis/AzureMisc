<#
    .DESCRIPTION
        This script will query a Reverse Lookup Zone for all PTR records that are dynamic and then attempt resolve these records to an A record.
         After resolving these records to an A record, the script will attempt to match the A record to an AD computer account. 
         The script will output results to a CSV file.  

    .PARAMETER dnsServerName
        The DNS server that you want to query for DNS records. Not mandatory if the script is run from a domain joined computer.

    .PARAMETER csvpath
        The path to the csv file that you want to export the results to. Not mandatory.

    .PARAMETER NetbiosDomainName
        The Netbios domain name of the domain that you want to query for DNS records. Not mandatory if the script is run from a domain joined computer.

    .EXAMPLE
        .\Query-ReverseLookupZones.ps1 -csvpath "c:\temp\DNSReport.csv"

    .NOTES    
        Requires the ActiveDirectory, DNSServer, and DNSClient PS modules.

#>

param (

    [Parameter(Mandatory = $false)]
    [string]$dnsServerName = (Get-ADDomain).ReplicaDirectoryServers[0],

    [Parameter(Mandatory = $false)]
    [string]$csvpath = $null,

    [Parameter(Mandatory = $false)]
    [string]$NetbiosDomainName = (Get-ADDomain).NetbiosName

)


# static variables
$dnsReport = @()

# import modules

$ErrorActionPreference = "stop"
try {
    $VerbosePreference = "silentlycontinue"
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

# get dns zones

$getReverseZones = Get-DnsServerZone -ComputerName $dnsServerName | Where-Object { $_.IsAutoCreated -eq $false -and $_.IsReverseLookupZone -eq $true } 
$ReverseLookupZoneNames = ($getReverseZones | Out-GridView -Title "Select Reverse Lookup Zone" -OutputMode Multiple ).ZoneName 

foreach ($ReverseLookupZoneName in $ReverseLookupZoneNames) {


    if ($ReverseLookupZoneName) {

        # get all records in specified DNS Zone that are dynamic

        $dnsRecords = Get-DnsServerResourceRecord -ZoneName $ReverseLookupZoneName -RRType PTR -ComputerName $dnsServerName | Where-Object { $_.Timestamp }

        # cycle through each record and get the host name associated with the record. then try to resolve the DNS name to an A record.

        foreach ($dnsRecord in $dnsRecords) {


            # set variables
            $resolveDNS = $null
            $dnsResolved = $false
            $remediateAcctString = $false

            if ($dnsRecord.RecordData) {

                Write-Verbose -Message "INFO: Resolving $($dnsRecord.RecordData.PtrDomainName)"
                $VerbosePreference = "silentlycontinue"
                $resolveDNS = Resolve-DnsName -Name $dnsRecord.RecordData.PtrDomainName -ErrorAction SilentlyContinue 
                $VerbosePreference = "continue"

                if ($resolveDNS.Name -ne $null) { $dnsResolved = $true }

                # get owner
                $ptrDnsSddl = (Get-Acl -Path "ActiveDirectory:://RootDSE/$($dnsRecord.DistinguishedName)" -ErrorAction SilentlyContinue).Sddl
                $ptrDnsOwnerSID = $ptrDnsSddl -replace 'o:(.+?)G:.+', '$1'
                $prtDnsOwnerSIDTranslate = New-Object System.Security.Principal.SecurityIdentifier($ptrDnsOwnerSID)
                try {
                    $ptrDnsOwner = $prtDnsOwnerSIDTranslate.Translate([System.Security.Principal.NTAccount])
                }
                catch {

                    $ptrDnsOwner = 'Owner Not Resolvable'

                }
                if (!$ptrDnsOwner) { $ptrDnsOwner = 'Owner Not Resolvable' }
                if ($ptrDnsOwner) {

                    # construct computer account name (if any)
                    $adComputerName = $dnsrecord.RecordData.PtrDomainName.Replace(".$domainRoot.", '') + "$"

                    try {
                        $adComputerObject = Get-ADComputer -Identity $adComputerName -ErrorAction SilentlyContinue
                        if ($ptrDnsOwner -match "S-1-5-21") { $remediateAcctString = $true }

                    }
                    catch {

                        $adComputerObject = "Not Found"
                        $remediateAcctString = "Not Possible"

                    }
 

                }
         
                $dnsReport += [pscustomobject]@{
            
            
                    ReverseDNSLookupZoneName       = $ReverseLookupZoneName
                    PtrHostName                    = $dnsRecord.RecordData.PtrDomainName
                    PTRDistinguishedName           = $dnsRecord.DistinguishedName
                    'Matching AD Computer Account' = $adComputerObject.DistinguishedName
                    PTRRecordOwner                 = $ptrDnsOwner
                    'Resolves to A Record'         = $dnsResolved
                    'Remediate Owner'              = $remediateAcctString

                }


            }

        }

    }

}

# output to gridview for quick results
$dnsReport | Out-GridView

# output to csv if csvpath is specified
if ($csvpath) {
    $dnsReport | Export-Csv -Path $csvpath -NoTypeInformation -Force -NoClobber
}

$VerbosePreference = "silentlycontinue"
