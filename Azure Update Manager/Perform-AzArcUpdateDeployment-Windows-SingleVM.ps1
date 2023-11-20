$subscriptionId = "<subscriptionid>"
$resourcegroupname = "azstack-rg"
$machinename = "winarc-03"

# Connect-AzAccount

Set-AzContext -SubscriptionId $subscriptionId

$payload =
@"
{
    "maximumDuration": "PT120M",
    "rebootSetting": "IfRequired",
    "windowsParameters": {
      "classificationsToInclude": [
        "Security",
        "UpdateRollup",
        "FeaturePack",
        "ServicePack"
      ],
      "kbNumbersToInclude": [
      ],
      "kbNumbersToExclude": [
      ]
    }
  }
"@

Invoke-AzRestMethod `
-Path "/subscriptions/$subscriptionId/resourceGroups/$resourcegroupname/providers/Microsoft.HybridCompute/machines/$machinename/installPatches?api-version=2020-08-15-preview" `
-Payload $payload -Method POST
