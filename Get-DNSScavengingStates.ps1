
<#
    .DESCRIPTION

       Gets a list of DNS scavenging settings from a list of domain controllers specified in a CSV file.

    .INPUTS

        -CSVFile = Input path to CSV file that contains the FQDN names of the domain controllers in comma delimited format.

    .EXAMPLE

        .\Get-DNSScavengingStates.ps1 -dcComputers @("wcurtisnetdc.wcurtis.net","serva.contoso.com")

    .NOTES
    
        - Script needs to be run by person able to provide admin credentials for the domain controllers to be tested.
        - Ensure that the DNS Server role has been installed OR the RSAT role has been installed if running from a 
            member server or running from a Windows client machine.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [array]
    $dcComputers
)

# Set preferences

$ErrorActionPreference = "Stop"
$VerbosePreference = "SilentlyContinue"

# Set variables

$report = @()

# Import required modules

$modCheck = Get-Module | Where-Object { $_.Name -eq "DnsServer" }
if (!$modCheck) { Write-Error "Module DnsServer was not found! Please install module before running script!" }
Import-Module -Name DnsServer
$VerbosePreference = "Continue"

# Get Credential to connect to servers
Write-Verbose -Message "Getting Credentials"
$creds = Get-Credential -Message "Enter a credential that has access to the Domain Controllers\DNS servers:"


# Get DNS scavenger settings on all DCs

foreach ($dcComputer in $dcComputers) {
    
    $dnsSettings = $null
    $DCContactable = Test-Connection -ComputerName $dcComputer -Quiet -Count 2

    if ($DCContactable) { 

        $dnsSettings = Invoke-Command -ComputerName $dcComputer -Credential $creds -ScriptBlock {
    
            Get-DnsServerScavenging -Computername $using:dcComputer

        }

    }  

    $report += [PSCustomObject]@{
        
        Computername      = $dcComputer
        DCContactable     = $DCContactable
        ScavengingState   = $dnsSettings.ScavengingState
        NoRefreshInterval = $dnsSettings.NoRefreshInterval
        RefreshInterval   = $dnsSettings.RefreshInterval
        LastScavengeTime  = $dnsSettings.LastScavengeTime

    }


}

$report | Format-Table -AutoSize



