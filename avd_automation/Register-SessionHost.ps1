



# Deploy Custom Script Extension to download the AVD Agent

$params = @{


    Name = "DownloadAVDAgent"
    FileUri = "https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH"
    ResourceGroupName  = $resourceGroupName
    VMName             = $virtualMachineName
    Location           = $VMLocation
    Run     =  "notepad.exe"

}

Set-AzVMCustomScriptExtension @params