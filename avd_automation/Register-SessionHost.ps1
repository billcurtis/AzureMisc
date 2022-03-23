



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



New-AzWvdRegistrationInfo -HostPoolName  wvdpool01 -ResourceGroupName wvdcentral-rg -ExpirationTime $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')) 


## Silent Install Strings 

https://christiaanbrinkhoff.com/2020/05/01/windows-virtual-desktop-technical-2020-spring-update-arm-based-model-deployment-walkthrough/ 

## Azure Virtual Desktop Agent
https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv

## Azure Bootloader Agent
https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH