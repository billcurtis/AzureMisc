$subscriptionId = "<subscriptionid>"
$MaintRGName =  "azstack-rg"
$ResourceRGName = "demo01-rg"
$location = "eastus"
$resourceName = "WinAZVM01"
$configName = "maintenanceconfig01"

Set-AzContext -SubscriptionId $subscriptionId | Out-Null

$maintenanceConfigId = (Get-AzMaintenanceConfiguration -ResourceGroupName $MaintRGName -Name $configName).Id

New-AzConfigurationAssignment `
   -ResourceGroupName $ResourceRGName `
   -Location $location `
   -ResourceName $resourceName `
   -ResourceType "VirtualMachines" `
   -ProviderName "Microsoft.Compute" `
   -ConfigurationAssignmentName "test" `
   -MaintenanceConfigurationId $maintenanceConfigId


```
 