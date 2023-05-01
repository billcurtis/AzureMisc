
# Quick and dirty example script to show how to get the Used Capacity for all SAs in 
# a subscription.

$storageAccts = Get-AzStorageAccount

$report = @()

foreach ($storageAcct in $storageAccts) {


    $usedCapacity = (Get-AzMetric -ResourceId $storageAcct.Id -MetricName "UsedCapacity").Data
    $usedCapacityInMB = $usedCapacity.Average / 1024 / 1024


    $report += [pscustomobject]@{

        StorageAccountName = $storageAcct.StorageAccountName
        ResourceGroupName  = $storageAcct.ResourceGroupName
        UsedCapacityInMB   = $usedCapacityInMB

    }


}

$report | Out-GridView -Title "Storage Report"

# You could export to CSV here if you want to. 
