# Pre-req extension registrations

az extension add --version 0.2.29 --name arcappliance
az extension add --upgrade --name connectedk8s
az extension add --upgrade --name k8s-configuration
az extension add --upgrade --name k8s-extension
az extension add --upgrade --name customlocation
az extension add --upgrade --name azurestackhci

# Pre-req provider Registrations

az provider register --namespace Microsoft.Kubernetes --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.ExtendedLocation --wait
az provider register --namespace Microsoft.ResourceConnector --wait
az provider register --namespace Microsoft.AzureStackHCI --wait
az provider register --namespace Microsoft.HybridConnectivity --wait

# Get the resource name
$resource_name= ((Get-AzureStackHci).AzureResourceName) + "-arcbridge"

# Create directory in cluster storage

New-Item -ItemType Directory -Path 'C:\ClusterStorage\Volume01\ResourceBridge'

# Login with Service Principal
$subscriptionID = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$tenantID = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$clientID = 'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$clientSecret =  'xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxx'
$resourcegroupName = 'azstack-rg'
$region = 'eastus'

$arcSpnCredential = new-object -typename System.Management.Automation.PSCredential `
        -argumentlist (($clientID),(ConvertTo-SecureString $clientSecret -AsPlainText -Force))

az login --service-principal -u $clientID -p $clientSecret --tenant $tenantID

