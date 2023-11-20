$subscriptionId = "<subscriptionid>"
$MaintRGName =  "azstack-rg"
$ResourceRGName = "azstack-rg"
$location = "eastus"
$resourceName = "winarc-03"
$configName = "maintenanceconfig01"

Set-AzContext -SubscriptionId $subscriptionId | Out-Null

$maintenanceConfigId = (Get-AzMaintenanceConfiguration -ResourceGroupName $MaintRGName -Name $configName).Id

New-AzConfigurationAssignment `
   -ResourceGroupName $ResourceRGName `
   -Location $location `
   -ResourceName $resourceName `
   -ResourceType "Machines" `
   -ProviderName "Microsoft.HybridCompute" `
   -ConfigurationAssignmentName "test" `
   -MaintenanceConfigurationId $maintenanceConfigId


```
 