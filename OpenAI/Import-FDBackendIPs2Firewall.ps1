
<# 

.DESCRIPTION

This script will download the Azure IP Ranges and Service Tags JSON file and extract the IP4 Addresses for Azure Front Door Backend. 
It will then remove existing Network Rules from the Azure Cognitive Services Account and add the extracted IP Addresses to the Network Rules.

.PARAMETER ResourceGroupName
The name of the resource group where the Azure Cognitive Services Account is located.\

.PARAMETER OAIAccountName
The name of the Azure Cognitive Services Account.

.PARAMETER ServiceTagWebPage
The URL of the Azure IP Ranges and Service Tags JSON file. This is optional and defaults to the Microsoft download page for the Service Tags.

.PARAMETER subscriptionId
The ID of the Azure subscription.

.EXAMPLE
.\Import-FDBackendIPs2Firewall.ps1 -ResourceGroupName "MyResourceGroup" -OAIAccountName "MyCognitiveServicesAccount" -subscriptionId "12345678-1234-1234-1234-1234567890AB"

.NOTES
Script uses hardcoded values for ResourceGroupName, AccountName, ServiceTagWebPage and subscriptionId. 
Please update these values as per your environment.

#>

param (
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$OAIAccountName,

    [Parameter(Mandatory = $false)]
    [string]$ServiceTagWebPage = "https://www.microsoft.com/en-us/download/details.aspx?id=56519",

    [Parameter(Mandatory = $true)]
    [string]$subscriptionId
)

 
# Set Context to subscription
Connect-AzAccount -Subscription $subscriptionId

# import azure modules
$VerbosePreference = "SilentlyContinue"
Import-Module Az.CognitiveServices

# Set preferences

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Download Azure IP Ranges and Service Tags – Public Cloud
 
$pageContent = Invoke-WebRequest -Uri $ServiceTagWebPage
if ($pageContent.Content -match 'data-bi-id="downloadretry" href="(?<url>.*\.json?)"') { 
    $jsonUrl = $matches['url'] 
}
$jsonContent = Invoke-RestMethod -Uri $jsonUrl

# Get IP Addresses for Azure Front Door Backend
$ipAddresses = (($jsonContent.values | Where-Object { $_.name -eq "AzureFrontDoor.Backend" }).Properties.addressPrefixes | Where-Object { $_ -notlike "*:*" })

# Remove existing Network Rules
$params = @{

    ResourceGroupName  = $ResourceGroupName
    Name               = $OAIAccountName
    IpRule             = @()
    VirtualNetworkRule = @()
}
Update-AzCognitiveServicesAccountNetworkRuleSet @params 


# Add IP Addresses to Azure Cognitive Services Account Network Rules from JSON

foreach ($ipAddress in $ipAddresses) {

    # Have to do this to get around bug.  If /31 or /32, then remove the /31 or /32
    if ($ipAddress -match "/31" -or $ipAddress -match "/32") {
        $ipAddress = $ipAddress.Split("/")[0]
    }

    $ipRule = New-Object Microsoft.Azure.Commands.Management.CognitiveServices.Models.PSIpRule;
    $ipRule.IpAddress = $ipAddress

    $params = @{
        ResourceGroupName = $ResourceGroupName
        Name              = $OAIAccountName
        IPRule            = $ipRule
    }

    Add-AzCognitiveServicesAccountNetworkRule  @params

}


 
 