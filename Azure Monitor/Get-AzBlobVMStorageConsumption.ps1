$outputpath = "C:\temp"


Connect-AzAccount

$subscriptions = Get-AzSubscription

$totalVMDiskSizeGB = 0
$diskReport = @()
$StorageBlobReport = @()
$TotalStorageBlobsGB = 0
# Import modules 

$VerbosePreference = 'SilentlyContinue'
Import-Module Az.Compute

# Set Preferences
$VerbosePreference = 'Continue'
$ErrorActionPreference = 'Continue'

foreach ($subscription in $subscriptions) {

    Write-Verbose -Message "Parsing subscription: $($subscription.Name)"
    Set-AzContext -Subscription $subscription.Id | Out-Null

    # Get Disk Information
    $disks = Get-AzDisk

    foreach ($disk in $disks) {

        $totalVMDiskSizeGB = $totalVMDiskSizeGB + $disk.DiskSizeGB
  
        $diskReport += [pscustomobject]@{

            Name              = $disk.Name
            ManagedBy         = $disk.ManagedBy
            Subscription      = $subscription.Name
            SubscriptionID    = $subscription.Id
            ResourceGroupName = $disk.ResourceGroupName
            DiskSizeGB        = $disk.DiskSizeGB
            SKUTier           = $disk.Sku.Tier
            SKUName           = $disk.Sku.Name


        }



    }

    # Get Storage Account information

    $StorageAccounts = Get-AzStorageAccount

    foreach ($StorageAccount in $StorageAccounts) {

        $context = $StorageAccount.Context
        $storageContainers = Get-AzStorageContainer -Context $context

        foreach ($storageContainer in $storageContainers) {
            $context.BlobEndPoint

            if ($context.BlobEndPoint) {

                $blobs = Get-AzStorageBlob -Context $context -Container $storageContainer.Name 
                $lengthGB = 0
                foreach ($blob in $blobs) {


                    $lengthGB = $lengthGB + ($blob.Length / 1gb)

                }

                $StorageBlobReport += [pscustomobject]@{

                    StorageAccountName = $StorageAccount.StorageAccountName
                    SKUName            = $StorageAccount.Sku.Name
                    SKUTier            = $StorageAccount.Sku.Tier
                    Kind               = $StorageAccount.Kind
                    ResourceGroupName  = $StorageAccount.ResourceGroupName
                    Subscription       = $subscription.Name
                    SubscriptionID     = $subscription.Id
                    ContainerName      = $storagecontainer.Name
                    TotalBlobSizeGB    = [math]::Round($lengthGB, 2)

                }

                $TotalStorageBlobsGB = $TotalStorageBlobsGB + [math]::Round($lengthGB, 2)

            }


        }

    }

}


$date = Get-Date -Format mmddyyyyhhmm

$StorageBlobReport | Export-Csv -Path "$outputpath\storageblobreport-$date.csv" -NoClobber -NoTypeInformation
$diskReport | Export-Csv -Path "$outputpath\vmdiskreport-$date.csv" -NoClobber -NoTypeInformation

Write-Output "Total VM Disk Sizes is: $totalVMDiskSizeGB GB"

Write-Output "Total Storage Blob Storage consumed is:  $TotalStorageBlobsGB GB"