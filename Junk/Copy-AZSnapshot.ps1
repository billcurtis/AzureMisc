# Set Location
$ResourceGroupName = 'myPackerGroup'

# Set Target Storage Account Information
$storageAcctName = 'snapshotspacker'
$storageAcctBlob = 'snapshots'
$storageAcctKey = (Get-AzStorageAccountKey -Name $storageAcctName -ResourceGroupName $ResourceGroupName).Value[0]
$storageContext = New-AzStorageContext -StorageAccountName $storageAcctName -StorageAccountKey $storageAcctKey

# Set Snapshot information
$SnapshotName = 'blahtest'


# Grant access to Azure VM
$params = @{

    SnapshotName = $SnapshotName
    Access = 'Read'
    ResourceGroupName = $ResourceGroupName
    DurationInSecond = 500000

}

$AccessSAS = (Grant-AzSnapshotAccess @params).AccessSAS

# Copy snapshot to storage account
Start-AzStorageBlobCopy -AbsoluteUri $AccessSAS -DestContainer $storageAcctBlob -DestContext $storageContext -DestBlob 'HunkeyDorry.vhd' -Force
