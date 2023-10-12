
<#
    .DESCRIPTION
         This example script will go through a selected CSV file and change the owner of the DNS record to the corresponding AD computer account.

    .PARAMETER csvpath 
        Mandatory. The path to the CSV file that contains the DNS records to remediate.

    .PARAMETER NetbiosDomainName
        The Netbios domain name of the domain that you want to query for DNS records. Not mandatory if the script is run from a domain joined computer.
    
    .EXAMPLE    
        Remediate-DynamicDNSRecordInfo.ps1 -csvpath "C:\temp\DNSRecords.csv" -NetbiosDomainName "contoso.com"


#>


param (

    [Parameter(Mandatory = $true)]
    [string]$csvpath = $null,

    [Parameter(Mandatory = $false)]
    [string]$NetbiosDomainName = (Get-ADDomain).NetbiosName


)

# import modules
# No Modules to import.

# set preferences

$ErrorActionPreference = "stop"
$VerbosePreference = "continue"

# import-csv

Write-Verbose -Message "INFO: Importing CSV File: $csvpath"
$csvData = (Import-Csv -Path $csvpath) | Where-Object { $_.'Remediate Account Match' -eq $true }

foreach ($dnsRecord in $csvData) {

    if ($dnsRecord.'A Record DistinguishedName') {
        if ($dnsRecord.Hostname) {

            $identity = $dnsRecord.Hostname    
            $User = New-Object System.Security.Principal.NTAccount($NetbiosDomainName, "$identity$")
            Write-Verbose -Message "INFO: Changing Permissions on $identity to its corresponding AD Computer Object."
            $acl = Get-Acl -Path "ActiveDirectory:://RootDSE/$($dnsRecord.'A Record DistinguishedName')"
            $Acl.SetOwner($User)
            Set-Acl -Path "ActiveDirectory:://RootDSE/$($dnsRecord.'A Record DistinguishedName')" -AclObject $Acl 


            # get current owner and output in verbose for logging.
            $aclDns = Get-Acl -Path “ActiveDirectory:://RootDSE/$($dnsRecord.'A Record DistinguishedName')” -ErrorAction SilentlyContinue
            Write-Verbose -Message "Queried DistinguishedName and found the following owner: $($aclDns.Owner)"

        }
        else { Write-Error -Exception "No A Record Hostname present in CSV file." }

    }
    else { Write-Error -Exception "No A Record Distinguished Name is present in CSV File." }

}

$VerbosePreference = "SilentlyContinue"