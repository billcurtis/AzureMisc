<#
    .DESCRIPTION
        This script will query a Reverse Lookup Zone for all PTR records that are dynamic and then attempt resolve these records to an A record.  

    .PARAMETER dnsServerName
        The DNS server that you want to query for DNS records. Not mandatory if the script is run from a domain joined computer.

    .PARAMETER csvpath
        The path to the csv file that you want to export the results to. Not mandatory.

    .EXAMPLE
        .\Query-ReverseLookupZone.ps1 -ReverseLookupZoneName "10.168.192.in-addr.arpa" -dnsServerName "dns.contoso.com" -csvpath "c:\temp\DNSReport.csv"


    .NOTES    
        Requires the ActiveDirectory, DNSServer, and DNSClient PS modules.

#>

param (

    [Parameter(Mandatory = $false)]
    [string]$dnsServerName = (Get-ADDomain).ReplicaDirectoryServers[0],

    [Parameter(Mandatory = $false)]
    [string]$csvpath = $null
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

# get dns zones

$getReverseZones = Get-DnsServerZone -ComputerName $dnsServerName | Where-Object { $_.IsAutoCreated -eq $false -and $_.IsReverseLookupZone -eq $true } 
$ReverseLookupZoneName = ($getReverseZones | Out-GridView -Title "Select Reverse Lookup Zone" -PassThru).ZoneName

if ($ReverseLookupZoneName) {

# get all records in specified DNS Zone that are dynamic

$dnsRecords = Get-DnsServerResourceRecord -ZoneName $ReverseLookupZoneName -RRType PTR -ComputerName $dnsServerName | Where-Object { $_.Timestamp }

# cycle through each record and get the host name associated with the record. then try to resolve the DNS name to an A record.

foreach ($dnsRecord in $dnsRecords) {

    # set variables
    $resolveDNS = $null
    $dnsResolved = $false

    if ($dnsRecord.RecordData) {

        Write-Verbose -Message "INFO: Resolving $($dnsRecord.RecordData.PtrDomainName)"
        $VerbosePreference = "silentlycontinue"
        $resolveDNS = Resolve-DnsName -Name $dnsRecord.RecordData.PtrDomainName -ErrorAction SilentlyContinue 
        $VerbosePreference = "continue"

        if ($resolveDNS.Name -ne $null) {

            $dnsResolved = $true

        }
 
        $dnsReport += [pscustomobject]@{

            PtrHostName              = $dnsRecord.RecordData.PtrDomainName
            DistinguishedName        = $dnsRecord.DistinguishedName
            'Resolves to A Record'   = $dnsResolved
            ReverseDNSLookupZoneName = $ReverseLookupZoneName

        }


    }

}

# output to gridview for quick results
$dnsReport | Out-GridView

# output to csv if csvpath is specified
if ($csvpath) {
    $dnsReport | Export-Csv -Path $csvpath -NoTypeInformation -Force -NoClobber
}

}
$VerbosePreference = "silentlycontinue"
