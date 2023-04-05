# Install Azure CLI Extensions

az extension add --upgrade --yes --name connectedk8s
az extension add --upgrade --yes --name k8s-extension
az extension add --upgrade --yes --name customlocation
az provider register --namespace Microsoft.ExtendedLocation --wait
az provider register --namespace Microsoft.Web --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az extension remove --name appservice-kube
az extension add --upgrade --yes --name appservice-kube


$clusterName = 'appsvc-cluster'
$nodePoolName = 'appsvc-nodepool'
$nodecount = 2
$nodeVmSize = 'Standard_D4s_v3'
$osType = 'Linux'
$controlPlaneNodeCount = 1

New-AksHciCluster `
    -name $clusterName `
    -nodePoolName $nodePoolName `
    -nodeCount $nodecount `
    -nodeVmSize $nodeVmSize `
    -osType $osType `
    -controlPlaneNodeCount $controlPlaneNodeCount

# After the install, we now want to onboard the cluster into Azure Arc with an SPN

$subscriptionID = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$tenantID = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$clientID = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$clientSecret = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$resourcegroupName = 'azstack-rg'
$region = 'eastus'


# create credential for service principal
$arcSpnCredential = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($clientID), (ConvertTo-SecureString $clientSecret -AsPlainText -Force))


Enable-AksHciArcConnection `
    -name $clusterName `
    -TenantId $tenantID `
    -subscriptionId $subscriptionID `
    -Credential $arcSpnCredential `
    -resourceGroup $resourcegroupName `
    -location $region

# Here we are going to use an existing log analytics workspace (optional)
$workspaceName = 'azstack-loganalytics'

$logAnalyticsWorkspaceId = $(az monitor log-analytics workspace show `
        --resource-group $resourceGroupName `
        --workspace-name $workspaceName `
        --query customerId `
        --output tsv)

$logAnalyticsWorkspaceIdEnc = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($logAnalyticsWorkspaceId))

$logAnalyticsKey = $(az monitor log-analytics workspace get-shared-keys `
        --resource-group $resourcegroupName `
        --workspace-name $workspaceName `
        --query primarySharedKey `
        --output tsv) 

$logAnalyticsKeyEnc = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($logAnalyticsKey))

# install app service extension

$extensionName = "appservice-ext" # Name of the App Service extension
$namespace = "appservice-ns" # Namespace in your cluster to install the extension and provision resources
$kubeEnvironmentName = 'appservice-env' # Name of the App Service Kubernetes environment resource


az k8s-extension create `
    --resource-group $resourcegroupName `
    --name $extensionName `
    --cluster-type connectedClusters `
    --cluster-name $clusterName `
    --extension-type 'Microsoft.Web.Appservice' `
    --release-train stable `
    --auto-upgrade-minor-version true `
    --scope cluster `
    --release-namespace $namespace `
    --configuration-settings "Microsoft.CustomLocation.ServiceAccount=default" `
    --configuration-settings "appsNamespace=$namespace" `
    --configuration-settings "clusterName=$kubeEnvironmentName" `
    --configuration-settings "keda.enabled=true" `
    --configuration-settings "buildService.storageClassName=default" `
    --configuration-settings "buildService.storageAccessMode=ReadWriteOnce" `
    --configuration-settings "customConfigMap=$namespace /kube-environment-config" `
    --configuration-settings "envoy.annotations.service.beta.kubernetes.io/azure-load-balancer-resource-group=$aksClusterGroupName" `
    --configuration-settings "logProcessor.appLogs.destination=log-analytics" `
    --config-protected-settings "logProcessor.appLogs.logAnalyticsConfig.customerId=$logAnalyticsWorkspaceIdEnc" `
    --config-protected-settings "logProcessor.appLogs.logAnalyticsConfig.sharedKey=$logAnalyticsKeyEnc"

# Get the id of the App Service Extension (for use later)

$extensionId = $(az k8s-extension show `
        --cluster-type connectedClusters `
        --cluster-name $clusterName `
        --resource-group $resourcegroupName `
        --name $extensionName `
        --query id `
        --output tsv)


##########################################################################################
<# Run the following command with an Azure AD User Logged in Azure CLI and copy the GUID
   more information is listed here: 
   https://github.com/MicrosoftDocs/azure-docs/blob/main/articles/azure-arc/kubernetes/custom-locations.md#enable-custom-locations-on-your-cluster
#>

az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv
# Insert the resulting GUID into this variable:
$oid  = "af89a3ae-8ffe-4ce7-89fb-a615f4083dc3" #(note that this is just an example)
#######################################################################################

az connectedk8s enable-features -n $clusterName -g $resourcegroupName --custom-locations-oid $oid --features cluster-connect custom-locations

# Note:  You will still get "Unable to fetch the Object ID of the Azure AD application used by Azure Arc service." 
#  but the output will show that it was successful.
# You should see: "Successsfully enabled features: ['cluster-connect', 'custom-locations'] for the Connected Cluster

# Next, we will create the Connected Cluster Extension
$adsExtensionName = 'ads-extension'
Get-AksHciCredential -Name $clusterName  # adding again to ensure that you have done this.
az k8s-extension create -c $clusterName -g $resourceGroupName --name $adsExtensionName --cluster-type connectedClusters --extension-type microsoft.arcdataservices --auto-upgrade false --scope cluster --release-namespace arc --config Microsoft.CustomLocation.ServiceAccount=sa-bootstrapper


 # Create a custom location

 $customLocationName="appservice-clt" # Name of the custom location

$connectedClusterId=$(az connectedk8s show --resource-group $resourcegroupName --name $clusterName --query id --output tsv)

az customlocation create `
    --resource-group $resourcegroupName `
    --name $customLocationName `
    --host-resource-id $connectedClusterId `
    --namespace $namespace `
    --cluster-extension-ids $extensionId

# Get Custom Location ID

    $customLocationId=$(az customlocation show `
    --resource-group $resourcegroupName `
    --name $customLocationName `
    --query id `
    --output tsv)

#Create the App Service Kubernetes environment
az appservice kube create `
    --resource-group $resourcegroupName `
    --name $kubeEnvironmentName `
    --custom-location $customLocationId