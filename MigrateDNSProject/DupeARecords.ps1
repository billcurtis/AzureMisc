
<#
    .DESCRIPTION
       Quick script to take DNS A records with a specified prefix and then replace that prefix with a new prefix and 
       then create a new A record.

    .INPUTS
         Manually edit the String Data below to enter the following information:

         DNSServer = Microsoft DNS Server that you will be attaching to.
         ZoneName  = The zone name which contains the A records that you wish to duplicate
         targetPrefix  = Old Prefix that you want to target.
         dupePrefix = New prefix that will replace the old prefix when creating the new A records.
         RecordDataIPv4Address = The is the IP address that is going to be placed for ALL of the new A records. This is by design.

    .NOTES
    
        - Requires DnsServer module
        - Does not delete the target DNS A Records
        - The same IP will be used for all records.
#>

# Fill in String Data

$DNSServer = 'litewaredc'
$ZoneName = "liteware.com"
$targetPrefix = 'DLP-'
$dupePrefix = 'SMTP-'
$RecordDataIPV4Address = '192.168.131.5'

# Set Preferences

$ErrorActionPreference = 'Stop'
$VerbosePreference = "SilentlyContinue"

# Import Required Modules

$moduleCheck = Get-Module DnsServer
if (!$moduleCheck) {

    throw "The PowerShell module DnsServer must be installed in order for this script to function"

}

Import-Module DnsServer

# Get List of Resource Records that start with the target prefix

$VerbosePreference = "Continue"
Write-Verbose "Getting Resource records for Zone: $ZoneName from DNS Server: $DNSServer"


$params = @{

    ZoneName     = $ZoneName 
    ComputerName = $DNSServer

}

$DNSRecords = Get-DnsServerResourceRecord @params | Where-Object { $_.HostName -match $targetPrefix -and $_.RecordType -eq 'A' }


# Cycle through all returned records

foreach ($DNSRecord in $DNSRecords) {

    # Create new resource name out of old resource name

    $DNSRecordHostName = $DNSRecord.HostName.Replace("$targetPrefix", "$dupePrefix")

    Write-Verbose "Creating New A Record: $DNSRecordHostName "

    # Add the DNS Record

    $params = @{

        A            = $true
        ZoneName     = $ZoneName
        ComputerName = $DNSServer
        Name         = $DNSRecordHostName
        TimeToLive   = $DNSRecord.TimeToLive
        IPv4Address  = $RecordDataIPV4Address


    }

    Add-DnsServerResourceRecord @params

}