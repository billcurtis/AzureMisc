# Note:  This is purely a sample of creating a AKSHCI Management cluster using a Service Principal

# Log into your subscription or have your Azure administrator register the 
# resource provider for you.

# Install Azure CLI

Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
Remove-Item .\AzureCLI.msi -Force
$env:Path += 'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin'

# Run the following on all HCI nodes in the cluster

Install-PackageProvider -Name NuGet -Force
Install-Module -Name PowershellGet -Force -Confirm:$false -SkipPublisherCheck
Install-Module -Name AksHci -Repository PSGallery -AcceptLicense -Force
Install-Module -Name ArcHci -Repository PSGallery -AcceptLicense -Force

curl.exe -LO "https://dl.k8s.io/release/v1.26.0/bin/windows/amd64/kubectl.exe"
$config = Get-MocConfig
Copy-Item .\kubectl.exe $config.installationPackageDir

az extension add --name k8s-extension --upgrade
az extension add --name customlocation --upgrade
az extension add --name arcappliance --upgrade
az extension add --name hybridaks --upgrade
az extension add --name connectedk8s

# Reload PowerShell and then run the following  on ALL HCI nodes in the cluster:
$env:Path += ';C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin'
$env:Path += ";$env:userprofile"

# Install AksHci module
Initialize-AksHciNode
 
# Install Azure Powershell
Install-Module az
Install-Module Az.ConnectedKubernetes



# Now that we've done this, let's go ahead and work off of only one Azure Stack HCI node
#  for the remainder of this tutorial

# Pick either DCHP (Windows DHCP) or Static (Static is recommended, but I use DHCP)

$aksnetname = "k8vnet"                # This can be anything.
$vswitchname =  "vswitch"             # This is your Hyper-V virtual switch on all nodes
$vipPoolStart = "192.168.10.220"      # VIPs are for the AKS clusters you will be creating.
$vipPoolEnd  = "192.168.10.240"
$vlanID = 10                          # This will be your VLAN ID of you HCI management network. 
                                      #  Note that this VLAN will need to be a cluster network on
                                      #  your failover cluster.

$k8sNodeIpPoolStart = "192.168.10.210"
$k8sNodeIpPoolEnd = "192.168.10.219"
$ipAddressPrefix  = "192.168.10.0/24"
$gateway = "192.168.10.1"
$dnsServers = ("1.1.1.1","8.8.8.8")


# If you are using DHCP:
# ======================
$vnet = New-AksHciNetworkSetting `
    -name $aksnetname `
    -vswitchName $vswitchname `
    -vipPoolStart $vipPoolStart `
    -vipPoolEnd $vipPoolEnd `
    -vlanID $vlanID


# Alternatively if we were setting the AksHCI networking statically, it would look like this:

# If you are using Static IP:
# ============================
$vnet = New-AksHciNetworkSetting `
    -name $aksnetname `
    -vSwitchName $vswitchname `
    -k8sNodeIpPoolStart $k8sNodeIpPoolStart `
    -k8sNodeIpPoolEnd $k8sNodeIpPoolEnd `
    -vipPoolStart $vipPoolStart `
    -vipPoolEnd $vipPoolEnd `
    -ipAddressPrefix $ipAddressPrefix `
    -gateway $gateway `
    -dnsServers $dnsServers `
    -vlanId $vlanID

# Next, we are going to validate and set the configuration that we are going to deploy.
# This process will also install the MOC and other software.

$imageDir = 'c:\clusterstorage\volume01\Images'
$workingDir = 'c:\ClusterStorage\Volume01\ImageStore'
$cloudConfigLocation = "c:\clusterstorage\volume01\Config"
$cloudservicecidr = "192.168.10.250/24"  # This value must be OUTSIDE of your Pools.

Set-AksHciConfig `
-imageDir $imageDir `
-workingDir $workingDir `
-cloudConfigLocation $cloudConfigLocation `
-vnet $vnet `
-cloudservicecidr $cloudservicecidr

# Now we need to set the registration. Since we are lowley users that do not have admin privs,
# we will be using a Service Principal with the "Microsoft.Kubernetes connected cluster role"
# permission set up.

$subscriptionID = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$tenantID = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$clientID = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$clientSecret =  'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$resourcegroupName = 'azstack-rg'

# create credential for service principal
$arcSpnCredential = new-object -typename System.Management.Automation.PSCredential `
        -argumentlist (($clientID),(ConvertTo-SecureString $clientSecret -AsPlainText -Force))

# Specify Az.Accounts version.This is to get around bug https://github.com/Azurdire/aks-hybrid/issues/282un
# You may need to remove the other account versions - 
# Get-Module -Name "Az.Accounts" -ListAvailable | select -First 2 | Uninstall-Module -Force 

Import-Module -Name "Az.Accounts" -RequiredVersion 2.6.0  

Connect-AzAccount `
-ServicePrincipal `
-Credential $arcSpnCredential `
-Tenant $tenantID `
-Subscription $subscriptionID


# Sets the AKS Registration. Make sure that the "Validate KVA" is successful before continuing. 
Set-AksHciRegistration `
-subscriptionId $subscriptionID `
-resourceGroupName $resourcegroupName `
-Credential $arcSpnCredential `
-TenantId $tenantID 

# Install AKS

Install-AksHci

# Fin