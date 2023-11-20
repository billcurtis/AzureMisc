$subscriptionId = "<subscriptionid>"
$resourcegroupname = "demo01-rg"
$machinename = "WinAZVM01"

# Connect-AzAccount

Set-AzContext -SubscriptionId $subscriptionId


Invoke-AzVMPatchAssessment -ResourceGroupName $resourcegroupname -VMName $machinename