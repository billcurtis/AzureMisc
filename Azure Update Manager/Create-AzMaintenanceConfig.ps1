$subscriptionId = "<subscriptionid>"
$RGName = "azstack-rg"

$configName = "maintenanceconfig02"
$scope = "InGuestPatch"
$location = "eastus"
$timeZone = "Pacific Standard Time" 
$duration = "04:00"
$startDateTime = "2022-11-01 00:00"
$recurEvery = "Week Saturday, Sunday"
$WindowsParameterClassificationToInclude = "FeaturePack","ServicePack";
$WindowParameterKbNumberToInclude = "KB123456","KB123466";
$WindowParameterKbNumberToExclude = "KB123456","KB123466";
$RebootOption = "IfRequired";
$LinuxParameterClassificationToInclude = "Other";
$LinuxParameterPackageNameMaskToInclude = "apt","httpd";
$LinuxParameterPackageNameMaskToExclude = "ppt","userpk";


Set-AzContext -SubscriptionId $subscriptionId


New-AzMaintenanceConfiguration `
   -ResourceGroup $RGName `
   -Name $configName `
   -MaintenanceScope $scope `
   -Location $location `
   -StartDateTime $startDateTime `
   -TimeZone $timeZone `
   -Duration $duration `
   -RecurEvery $recurEvery `
   -WindowParameterClassificationToInclude $WindowsParameterClassificationToInclude `
   -WindowParameterKbNumberToInclude $WindowParameterKbNumberToInclude `
   -WindowParameterKbNumberToExclude $WindowParameterKbNumberToExclude `
   -InstallPatchRebootSetting $RebootOption `
   -LinuxParameterPackageNameMaskToInclude $LinuxParameterPackageNameMaskToInclude `
   -LinuxParameterClassificationToInclude $LinuxParameterClassificationToInclude `
   -LinuxParameterPackageNameMaskToExclude $LinuxParameterPackageNameMaskToExclude `
   -ExtensionProperty @{"InGuestPatchMode"="User"}