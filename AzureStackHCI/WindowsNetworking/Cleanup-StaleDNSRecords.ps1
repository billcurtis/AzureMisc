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

    .EXAMPLE
        Cleanup-StaleDNSRecords.ps1 -dnsServerName "dns01" -zoneName "contoso.com" -DomainName "contoso.com"

    .NOTES    
        Requires the ActiveDirectory and DNSServer PS modules.

#>

param (

    [Parameter(Mandatory = $true)]
    [string]$zoneName,

    [Parameter(Mandatory = $false)]
    [string]$dnsServerName = (Get-ADDomain).ReplicaDirectoryServers[0],

    [Parameter(Mandatory = $false)]
    [string]$NetbiosDomainName= (Get-ADDomain).NetbiosName

)

# static variables

$dnsRecordSet = @()
$dnsReport = @()

# import modules
$ErrorActionPreference = "stop"
try {
    Import-Module activedirectory
    Import-Module dnsserver
}
catch {
    Write-Error -Message "One or more required modules is missing. You must have the ActiveDirectory and DNSServer modules installed to use this script."
}

# set preferences
$ErrorActionPreference = "stop"
$VerbosePreference = "continue"

# get all dns resource records with RecordType of A and not set to static DNS.

$dnsRecords = Get-DnsServerResourceRecord -ZoneName $zoneName -ComputerName $dnsServerName -RRType A | Where-Object { $_.Timestamp }


# cycle through all DNS records and get the owners of the records and match an unknown sid
foreach ($dnsRecord in $dnsRecords) {

    $aclDns = Get-Acl -Path “ActiveDirectory:://RootDSE/$($dnsRecord.DistinguishedName)” -ErrorAction SilentlyContinue
    if ($aclDns.Owner -match "S-1-5-21") {

        $dnsRecordSet += $aclDns
 

        try {

            Write-Verbose "Querying Active Directory for $($dnsRecord.HostName)"
            $adComputer = Get-ADComputer ($dnsRecord.HostName)
            if ($adComputer) { $ADAccountExists = $true }

        }
        catch {

            $ADAccountExists = $false

        }

        $dnsReport += [pscustomobject]@{

            Hostname          = $dnsRecord.HostName            
            CurrentOwner      = $aclDns.Owner
            ADAccountExists   = $ADAccountExists
            DistinguishedName = $dnsRecord.DistinguishedName

        }


    }

}

# display the dns records with their ad computer account not being the owner of the dns A record and have user select accounts to alter.

$selections = $dnsReport | Where-Object { $_.ADAccountExists } | Out-Gridview -OutputMode Multiple -Title "Select the A records to set owner to their corresponding computer account."  

if ($selections) {

    $choiceDelete = [System.Windows.MessageBox]::Show("Do you want to proceed with changing the ownership of $($selections.count) selected DNS Records?", 'CONFIRM', 'YesNoCancel', 'Warning')
    if ($choiceDelete -eq 'Yes') {

        foreach ($selection in $selections) {
            
            $identity = $selection.Hostname             
            $User = New-Object System.Security.Principal.NTAccount($NetbiosDomainName, "$identity$")
            Write-Verbose -Message "Changing Permissions on $identity to its corresponding AD computer object."
            $Acl = Get-Acl -Path "ActiveDirectory:://RootDSE/$($selection.DistinguishedName)"
            $Acl.SetOwner($User)
            Set-Acl -Path "ActiveDirectory:://RootDSE/$($selection.DistinguishedName)" -AclObject $Acl

        }

    }

}

# display the dns records with a SID as the owner. Enable user to select and delete records from DNS.

$selections = $dnsReport | Where-Object { !$_.ADAccountExists } | Out-Gridview -OutputMode Multiple -Title "Select the A records without Computer Accounts that you wish to delete." 

if ($selections) {


    $choiceDelete = [System.Windows.MessageBox]::Show("Do you want to proceed with DELETION of $($selections.count) selected DNS Records?", 'CONFIRM', 'YesNoCancel', 'Warning')
    if ($choiceDelete -eq 'Yes') {

        foreach ($selection in $selections) {

            $params = @{

                ZoneName     = $zoneName
                ComputerName = $dnsServerName
                RRType       = 'A'
                Name         = $selection.Hostname 

            }

            Write-Verbose -Message "Deleting selected DNS A Records from Zone $zoneName"
            Remove-DnsServerResourceRecord @params -Confirm:$false -Force

        }


    }

}

$VerbosePreference = "silentlycontinue"

 