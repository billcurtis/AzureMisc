<#
    .DESCRIPTION
       Gathers all instances of Linux VMs and generates report

    .INPUTS
        osType = OS type that will be placed in the AZ Graph Query.
        targetTag = Tag name that will be placed in the AZ Graph Query.
        targetValue = Target Tag value that will be placed in the AZ Graph Query
        smbPath = path to the SMB Share that the generated report will be placed.
        smbFilename = File name that the generated report will be saved under.

    .NOTES
    
        - Requires Az.ResourceGraph module
#>

param (

    $targetTag,
    $targetValue,
    $smbPath,
    $smbFilename,
    $smbStorageAccountKey

)


# Set Preferences
$VerbosePreference = "SilentlyContinue"
$ErrorActionPreference = "Stop" 


$azGraphQuery = @"
Resources
| where type == "microsoft.compute/virtualmachines"
| where tags['$targetTag']=~'$targetValue'
| extend os = properties.storageProfile.imageReference.offer
| extend osType=properties.storageProfile.osDisk.osType
| where osType=='$osType'
| extend sku = properties.storageProfile.imageReference.sku
| extend hostName = properties.osProfile.computerName
| mvexpand nic = properties.networkProfile.networkInterfaces
| extend nicId = tostring(nic.id)
| project subscriptionId, vmName = name, resourceGroup, location, nicId, hostName, os, sku
| join kind=leftouter (
	Resources
	| where type == "microsoft.network/networkinterfaces"
	| mvexpand ipconfig=properties.ipConfigurations
	| extend privateIp = ipconfig.properties.privateIPAddress
    | project nicId = id, privateIp
) on nicId
| project-away nicId1
| project hostName, privateIp , vmName
"@

# Import modules
Import-Module Az.ResourceGraph
$VerbosePreference = "Continue"

# Connect through AzureRunAsConnection

$connectionName = "AzureRunAsConnection"
try {

    # Get the connection "AzureRunAsConnection"
    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName         

    $params = @{

        TenantId              = $servicePrincipalConnection.TenantId
        ApplicationId         = $servicePrincipalConnection.ApplicationId
        CertificateThumbprint = $servicePrincipalConnection.CertificateThumbprint

    }    

    Add-AzAccount  @params -ServicePrincipal | Out-Null
}
catch {
    if (!$servicePrincipalConnection) {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    }
    else {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

# Get Resoure Manager Data

try {

    Write-Verbose "Gathering Resource Data"
    $azGraphData = (Search-AzGraph -Query $azGraphQuery).Data
    $azGraphData | Write-Output

    # Publish data to CSV file and place on blob
    Write-Verbose "Publishing Data to CSV"

}
catch { throw $_ }

# Place on Azure FileShare 

New-AzStorageContext -StorageAccountName resprop -StorageAccountKey "OnW0Lz830bHcOdBX4w9FtrFomae8vQLbcR7ZqTMqN4d9IFBQ1EdDdsMgcpF9QBrXEXauBFeW5YXScLkuU6WeXw=="