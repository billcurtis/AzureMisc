<#
    .DESCRIPTION

       Simple script that gets DNS Zone Transfer information from a Windows DNS server and exports to a CSV file.

    .INPUTS

        None. However, the path where you want the CSV file to be output to needs to have been created.

    .EXAMPLE

        None

    .NOTES

#>


# set preferences

$ErrorActionPreference = "Stop"
$VerbosePreference = "SilentlyContinue"

# initialize variables

$reportPath = 'C:\temp\'
$report = @()


# import required modules

$modCheck = Get-Module | Where-Object { $_.Name -eq "DnsServer" }
if (!$modCheck) { Write-Error "Module DnsServer was not found! Please install module before running script!" }
Import-Module -Name DnsServer
$VerbosePreference = "Continue"

# get all the zones (except for the  default ones)

$zones = Get-DnsServerZone | Where-Object { $_.ZoneType -eq "Primary" -or $_.ZoneType -eq "Secondary" -and $_.ZoneName -notmatch "arpa" -and $_.ZoneName -notmatch "TrustAnchors" -and $_.ZoneName -notmatch "_msdcs" }

# cycle through zones

foreach ($zone in $zones) {

    $allowZoneTransfers = $null
    $zoneTransferType = $null
    $listedServers = $null

    if ($zone.ZoneType -eq 'Primary') {

        switch ($zone.SecureSecondaries) {

            "NoTransfer" { $allowZoneTransfers = $false }
            "TransferAnyServer" { $allowZoneTransfers = $true; $zoneTransferType = "To any server" }
            "TransferToZoneNameServer" { $allowZoneTransfers = $true; $zoneTransferType = "Only to Name Servers" }
            "TransferToSecureServers" {

                $allowZoneTransfers = $true 
                $zoneTransferType = "Only to listed servers" 
                $listedServers = $zone.SecondaryServers.IPAddressToString -join ', '

            }


        }

        $report += [pscustomobject]@{

            ZoneName            = $zone.ZoneName
            Type                = 'Primary'
            AllowZoneTransfers  = $allowZoneTransfers
            ZoneTransferType    = $zoneTransferType
            ZoneTransferServers = $listedServers
            DNSServerName       = $env:COMPUTERNAME

        }


    }

    if ($zone.ZoneType -eq 'Secondary') {

        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\DNS Server\Zones\$($zone.ZoneName)\"
        $testRegPath = Test-Path $regPath
        if (!$testRegPath) { Write-Error "Cannot find registry path: $regPath" }
        $regValues = Get-ItemProperty -Path $regPath

        switch ($regValues.SecureSecondaries) {

            3 { $allowZoneTransfers = $false }
            0 { $allowZoneTransfers = $true; $zoneTransferType = "To any server" }
            1 { $allowZoneTransfers = $true; $zoneTransferType = "Only to Name Servers" }
            2 {

                $allowZoneTransfers = $true 
                $zoneTransferType = "Only to listed servers" 
                $listedServers = $regValues.SecondaryServers -join ', '

            }


        }

        $report += [pscustomobject]@{

            ZoneName            = $zone.ZoneName
            Type                = 'Secondary'
            AllowZoneTransfers  = $allowZoneTransfers
            ZoneTransferType    = $zoneTransferType
            ZoneTransferServers = $listedServers
            DNSServerName       = $env:COMPUTERNAME

        }


    }


}

# display the report

$report | Format-Table -AutoSize


# export to csv

$testReportPath = Test-Path $reportPath
if (!$testReportPath) { Write-Error "Cannot find path: $reportPath" }
$date = Get-Date -Format "MMddyyHHmmss"
$reportName = $reportPath + "DNSZoneReport-" + $date + ".csv"
$report | Export-Csv -Path $reportName -NoClobber -NoTypeInformation