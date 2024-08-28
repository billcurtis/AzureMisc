
<# 

.DESCRIPTION

This script will download the Azure IP Ranges and Service Tags JSON file and extract the IP Addresses for Azure Front Door Backend. 
It will then remove existing Network Rules from the Azure Cognitive Services Account and add the extracted IP Addresses to the Network Rules.

.NOTES
Script uses hardcoded values for ResourceGroupName, AccountName, ServiceTagWebPage and subscriptionId. 
Please update these values as per your environment.

#>

# Static Variables
$ResourceGroupName = "xxxxxxx"
$AccountName = "xxxxxxxxx"  #OpenAI Cognitive Services Account Name
$ServiceTagWebPage = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519"
$subscriptionId = "xxxxxxxxxxxxxxxxxxxxxxxxxx"

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
$ipAddresses = (($jsonContent.values | Where-Object { $_.name -eq "AzureFrontDoor.Backend" }).Properties.addressPrefixes | Where-Object {$_ -notlike "*:*"})

# Remove existing Network Rules
$params = @{

    ResourceGroupName = $ResourceGroupName
    Name              = $AccountName
    IpRule            = @()
    VirtualNetworkRule = @()
}
Update-AzCognitiveServicesAccountNetworkRuleSet @params 


# Add IP Addresses to Azure Cognitive Services Account Network Rules from JSON

foreach ($ipAddress in $ipAddresses) {

    Write-Host "Adding IP Address: $ipAddress"

      # Have to do this to get around bug.  If /31 or /32, then remove the /31 or /32
        if ($ipAddress -match "/31" -or $ipAddress -match "/32") {
            $ipAddress = $ipAddress.Split("/")[0]
        }

        $ipRule = New-Object Microsoft.Azure.Commands.Management.CognitiveServices.Models.PSIpRule;
        $ipRule.IpAddress = $ipAddress

        $params = @{
            ResourceGroupName = $ResourceGroupName
            Name              = $AccountName
            IPRule            = $ipRule
        }

        Add-AzCognitiveServicesAccountNetworkRule  @params

    }


 
 