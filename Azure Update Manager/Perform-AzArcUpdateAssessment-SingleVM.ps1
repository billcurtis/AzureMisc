$subscriptionId = "<subscriptionid>"
$resourcegroupname = "azstack-rg"
$machinename = "winarc-04"

# Connect-AzAccount

Set-AzContext -SubscriptionId $subscriptionId

Invoke-AzRestMethod -Path `
  "/subscriptions/$subscriptionId/resourceGroups/$resourcegroupname/providers/Microsoft.HybridCompute/machines/$machinename/assessPatches?api-version=2020-08-15-preview" `
  -Payload '{}' -Method POST


  