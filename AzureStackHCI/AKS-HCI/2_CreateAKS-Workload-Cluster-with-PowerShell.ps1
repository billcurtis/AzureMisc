# Note:  This is purely a sample of creating a AKSHCI workload cluster using a Service Principal

# Note: These commands are meant to be run on an Azure Stack HCI node.

# First let's get VM Sizes

Get-AksHciVmSize

<#
This will return with an output like this:

          VmSize CPU MemoryGB
          ------ --- --------
         Default 4   4
  Standard_A2_v2 2   4
  Standard_A4_v2 4   8
 Standard_D2s_v3 2   8
 Standard_D4s_v3 4   16
 Standard_D8s_v3 8   32
Standard_D16s_v3 16  64
Standard_D32s_v3 32  128
 Standard_DS2_v2 2   7
 Standard_DS3_v2 2   14
 Standard_DS4_v2 8   28
 Standard_DS5_v2 16  56
Standard_DS13_v2 8   56
 Standard_K8S_v1 4   2
Standard_K8S2_v1 2   2
Standard_K8S3_v1 4   6

#>

<# Now let's create the cluster.
   See https://learn.microsoft.com/en-us/azure/aks/hybrid/reference/ps/new-akshcicluster
   for all the options 
#>

$clusterName = 'sql-mi-cluster'
$nodePoolName = 'sql-mi-nodepool'
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


# Set the kubeconfigprofile

Get-AksHciCredential -Name $clusterName 

# After the install, we now want to onboard the cluster into Azure Arc with an SPN

$subscriptionID = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$tenantID = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$clientID = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$clientSecret =  'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$resourcegroupName = 'azstack-rg'
$region = 'eastus'
Enable-AksHciArcConnection `
-name $clusterName `
-TenantId $tenantID `
-subscriptionId $subscriptionID `
-Credential $arcSpnCredential `
-resourceGroup $resourcegroupName `
-location $region

# create credential for service principal
$arcSpnCredential = new-object -typename System.Management.Automation.PSCredential `
        -argumentlist (($clientID),(ConvertTo-SecureString $clientSecret -AsPlainText -Force))


# enable/register Custom Location Features

az extension add --name connectedk8s
az extension add --name k8s-extension
az extension add --name customlocation

# Log into Azure with sp

az login --service-principal --username $clientID --password $clientSecret --tenant $tenantID
az account set --subscription $subscriptionID

az provider register --namespace Microsoft.ExtendedLocation


# use the following command check registration status before moving on.
<#
  "id": "/subscriptions/3b324982-741d-41c8-bc71-8fed923fdb0e/providers/Microsoft.ExtendedLocation",
  "namespace": "Microsoft.ExtendedLocation",
  "providerAuthorizationConsentState": null,
  "registrationPolicy": "RegistrationRequired",
  "registrationState": "Registered",
#>

az provider show -n Microsoft.ExtendedLocation

<# Run the following command with an Azure AD Logged in Azure CLI and copy the GUID
   more information is listed here: 
   https://github.com/MicrosoftDocs/azure-docs/blob/main/articles/azure-arc/kubernetes/custom-locations.md#enable-custom-locations-on-your-cluster
#>

az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv

# after getting the OID GUID.  Go back to your SPN login.

$oid  = "af89a3ae-8ffe-4ce7-89fb-a615f4083dc3" #(note that this is just an example)

az connectedk8s enable-features -n $clusterName -g $resourcegroupName --custom-locations-oid $oid --features cluster-connect custom-locations

# Note:  You will still get "Unable to fetch the Object ID of the Azure AD application used by Azure Arc service." 
#  but the output will show that it was successful.
# You should see: "Successsfully enabled features: ['cluster-connect', 'custom-locations'] for the Connected Cluster

# Next, we will create the Connected Cluster Extension

$adsExtensionName = 'ads-extension'
az k8s-extension create -c $clusterName -g $resourceGroupName --name $adsExtensionName --cluster-type connectedClusters --extension-type microsoft.arcdataservices --auto-upgrade false --scope cluster --release-namespace arc --config Microsoft.CustomLocation.ServiceAccount=sa-bootstrapper


# Next, we will now create the Custom Location

$ENV:clName="Charlotte"
$ENV:clNamespace="arc"
$ENV:hostClusterId = az connectedk8s show -g $resourcegroupName -n $clusterName --query id -o tsv
$ENV:extensionId = az k8s-extension show -g $resourcegroupName -c $clusterName --cluster-type connectedClusters --name $adsExtensionName --query id -o tsv

az customlocation create -g $resourcegroupName -n $clusterName --namespace "$ENV:clNamespace" --host-resource-id "$ENV:hostClusterId" --cluster-extension-ids "$ENV:extensionId"

# Configure container monitoring
az k8s-extension create --name azuremonitor-containers --cluster-name $clusterName --resource-group $resourcegroupName --cluster-type connectedClusters --extension-type Microsoft.AzureMonitor.Containers  

# Now you can go and create the Azure Arc Data Contoller