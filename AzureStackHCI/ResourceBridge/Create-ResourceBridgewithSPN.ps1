# This is a quick and dirty example of how I create a resource bridge in HCI using a
# Service Principal

Install-PackageProvider -Name NuGet -Force 
Install-Module -Name PowershellGet -Force -Confirm:$false -SkipPublisherCheck  


Install-Module -Name Moc -Repository PSGallery -AcceptLicense -Force
Initialize-MocNode
Install-Module -Name ArcHci -Force -Confirm:$false -SkipPublisherCheck -AcceptLicense

# Reload PowerShell and then run the following  on ALL HCI nodes in the cluster:
$env:Path += ';C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin'
$env:Path += ";$env:userprofile"

# static variables

$subscription = 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
$tenantID = 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
$clientID = 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
$clientSecret =  'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
$resource_group= 'azstack-rg'
$arcserverresourceGroupName = 'azstack-rg'
$location = 'eastus'


$VswitchName="vswitch"
$ControlPlaneIP="192.168.10.201"
$csv_path="C:\ClusterStorage\Volume01"
$VlanID="10"
$VMIP_1="192.168.10.202"
$VMIP_2="192.168.10.203"
$DNSServers="192.168.10.254" 

# Log into Azure and register providers (unless you have already registerd the providers)
az login --service-principal -u $clientID -p $ClientSecret --tenant $tenantID
az account set --subscription $subscription
az provider register --namespace Microsoft.Kubernetes --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.ExtendedLocation --wait
az provider register --namespace Microsoft.ResourceConnector --wait
az provider register --namespace Microsoft.AzureStackHCI --wait
az provider register --namespace Microsoft.HybridConnectivity --wait

# Get resource names all lined up.
$hciClusterId= (Get-AzureStackHci).AzureResourceUri
$resource_name= ((Get-AzureStackHci).AzureResourceName) + "-arcbridge"
$customloc_name= ((Get-AzureStackHci).AzureResourceName) + "-CLT"

New-item $csv_path\ResourceBridge -ItemType Directory

New-ArcHciConfigFiles -subscriptionID $subscription `
-location $location `
-resourceGroup $resource_group `
-resourceName $resource_name `
-workDirectory $csv_path\ResourceBridge `
-controlPlaneIP $controlPlaneIP `
-vipPoolStart $controlPlaneIP `
-vipPoolEnd $controlPlaneIP `
-vswitchName $vswitchName `
-vLanID $vlanID

# Deploy the Resource Bridge Appliance
az arcappliance validate hci --config-file $csv_path\ResourceBridge\hci-appliance.yaml

az arcappliance prepare hci --config-file $csv_path\ResourceBridge\hci-appliance.yaml

az arcappliance deploy hci --config-file  $csv_path\ResourceBridge\hci-appliance.yaml --outfile "$csv_path\ResourceBridge\kubeconfig" 

az arcappliance create hci --config-file $csv_path\ResourceBridge\hci-appliance.yaml --kubeconfig "$csv_path\ResourceBridge\kubeconfig" 

# Run this command and wait until Status says "Connected" instead of "WaitingforHeartbeat" or "Validating":  
az arcappliance show --resource-group $resource_group --name $resource_name --query '[provisioningState, status]'

az k8s-extension create --cluster-type appliances --cluster-name $resource_name --resource-group $resource_group --name hci-vmoperator --extension-type Microsoft.AZStackHCI.Operator --scope cluster --release-namespace helm-operator2 --configuration-settings Microsoft.CustomLocation.ServiceAccount=hci-vmoperator --config-protected-file $csv_path\ResourceBridge\hci-config.json --configuration-settings HCIClusterID=$hciClusterId --auto-upgrade true

# Ensure the output of this command is "Succeeded" before running the next command.
az k8s-extension show --cluster-type appliances --cluster-name $resource_name --resource-group $resource_group --name hci-vmoperator --out table --query '[provisioningState]'

# Create the Custom Location
az customlocation create --resource-group $resource_group --name $customloc_name --cluster-extension-ids "/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.ResourceConnector/appliances/$resource_name/providers/Microsoft.KubernetesConfiguration/extensions/hci-vmoperator" --namespace hci-vmoperator --host-resource-id "/subscriptions/$subscription/resourceGroups/$resource_group/providers/Microsoft.ResourceConnector/appliances/$resource_name" --location $location