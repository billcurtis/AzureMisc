<#
    .DESCRIPTION
       Deploys a Virtual Machine that will be used in creating a session host.

    .INPUTS
       
       virtualMachineName -  The name of the virtual machine name.

       virtualMachineSize - String value of the string that deploys the session host.

       resourceGroupName - The resource group which contains the target VM.

       VirtualNetworkName - The name of the Vnet that where the AVD host will be deployed

       VirtualNetworkSubnetName - The name of the subnet under the Virtual Network in which the AVD host will be deployed.

       VMLocation - The location of the target VM.

       ImageGalleryName - The image gallery name where your image is located.

       ImageDefinitionName - The image definition name of the image that will be deployed.

       localadminAutomationCreName -

       AutomationAccountName -  The name of the automation account that is used to run this runbook.

       AutomationAccountResourceGroupName - The Azure Automation account resource group name.






    .NOTES
    
        
#>

param (

    [string]$virtualMachineName,
    [string]$virtualMachineSize,
    [string]$resourceGroupName,
    [string]$VirtualNetworkName,
    [string]$VirtualNetworkSubnetName,
    [string]$VMLocation,
    [string]$ImageGalleryName,
    [string]$ImageGalleryResourceGroupName,
    [string]$ImageDefinitionName,
    [string]$localadminAutomationCreName,
    [string]$AutomationAccountName,
    [string]$AutomationAccountResourceGroupName
    
)     


# Set Preferences

$ErrorActionPreference = 'Stop'
$VerbosePreference = "SilentlyContinue"

# Import Required Modules
Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.Network

# Set Preferences 

$ErrorActionPreference = 'Stop'
$VerbosePreference = "Continue"

# Log Inputs

Write-Verbose -Message "To Do: Put all the inputs here for debugging" 

# Get the connection Name

$connectionName = "AzureRunAsConnection"
try {
    
    Write-Verbose -Message "Getting the Azure Automation Connection"

    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName   
    
    Write-Verbose -Message "Adding the Azure Account"

    Add-AzAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
    | Out-Null
}
catch {
    if (!$servicePrincipalConnection) {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    }
    else {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}


# Create the Network Interface

## Get the SubnetID
Write-Verbose -Message "Getting the Subnet ID"
$subnetID = (Get-AzVirtualNetwork -Name $VirtualNetworkName | Get-AzVirtualNetworkSubnetConfig | Where-Object { $_.Name -match $VirtualNetworkSubnetName }).Id
Write-Verbose -Message "Subnet ID is: $subnetID"

$params = @{

    Name              = "$($virtualMachineName)_nic"
    ResourceGroupName = $resourceGroupName
    Location          = $VMLocation
    SubnetID          = $subnetID
    Force             = $true

}

Write-Verbose -Message "Adding the network interface $($virtualMachineName)_nic"
$nic = New-AzNetworkInterface @params


# Get the ImageDefinition

$params = @{

    Name              = $ImageDefinitionName
    GalleryName       = $ImageGalleryName
    ResourceGroupName = $ImageGalleryResourceGroupName

}

Write-Verbose -Message "Getting Image Definition: $ImageDefinitionName"
$VMImage = Get-AzGalleryImageDefinition @params

# Get the local admin credential

Write-Verbose -Message "Getting the local admin credential from $AutomationAccountName"
$params = @{

    Name = $localadminAutomationCreName
}

$localCred = Get-AutomationPSCredential @params



# VM Configuration

Write-Verbose -Message "Setting the Virtual Machine Configuration "
$vmConfig = New-AzVMConfig `
    -VMName $virtualMachineName `
    -VMSize $virtualMachineSize | `
    Set-AzVMOperatingSystem -Windows -ComputerName $virtualMachineName -Credential $localCred | `
    Set-AzVMSourceImage -Id $VMImage.Id | `
    Add-AzVMNetworkInterface -Id $nic.id

# Deploy the virtual machine

Write-Verbose -Message "Deploying the Virtual Machine $virtualMachineName"
$params = @{

    ResourceGroupName      = $resourceGroupName
    Location               = $VMLocation
    VM                     = $vmConfig
    DisableBginfoExtension = $true

}

New-AzVM @params | Out-Null


