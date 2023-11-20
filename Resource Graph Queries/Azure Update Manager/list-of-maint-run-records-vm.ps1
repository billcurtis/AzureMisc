<#

The following query returns a list of all the maintenance run records for a VM

#>



$rsQuery = @'
maintenanceresources 
| where ['id'] contains "/subscriptions/3b324982-741d-41c8-bc71-8fed923fdb0e/resourceGroups/azstack-rg/providers/Microsoft.HybridCompute/machines/vmm" //VM Id here
| where ['type'] == "microsoft.maintenance/applyupdates" 
| where properties.maintenanceScope == "InGuestPatch"
'@

Search-AzGraph -Query $rsQuery
