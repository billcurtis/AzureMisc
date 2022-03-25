
# This is an example script to show how to call multiple runbooks to create session hosts.

# Input Variables

$virtualMachineName = "Test006"
$virtualMachineSize = "Standard_DS3_v2"
$resourceGroupName = "wvdcentral-rg"
$VirtualNetworkName = "wvdcentral-vnet"
$VirtualNetworkSubnetName = "wvdSuB"
$VMLocation = "eastus2"
$ImageGalleryName = "MyIBSIG"
$ImageGalleryResourceGroupName = "ImageCreation-rg"
$ImageDefinitionName = "win10SessionHost"
$domainAutomationCreName = "Domain Join Credential"
$domainAutomationVariable = "DomainFQDN"
$AutomationAccountName = "private-automation"
$AutomationAccountResourceGroupName = "peautomation-rg"
$localadminAutomationCreName = "LocalAdmin"
$VMLocation = "eastUS2"
$AVDHostPoolName = 'wvdpool01'
$AVDResourceGroupName = 'wvdcentral-rg'
#$WorkspaceIDvariable = "LAworkspaceID"
#$WorkspaceKeyvariable = "LAworkspacekey"

# Get the connection Name

$connectionName = "AzureRunAsConnection"
try {
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName         

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

# Deploy the VM

.\Deploy-SessionHostVM.ps1 `
		-AutomationAccountName $AutomationAccountName `
		-ResourceGroupName $resourceGroupName `
		-virtualMachineName $virtualMachineName `
		-VMLocation $VMLocation `
		-virtualMachineSize $virtualMachineSize `
		-AutomationAccountResourceGroupName $AutomationAccountResourceGroupName `
		-VirtualNetworkName $VirtualNetworkName `
		-imageDefinitionName $ImageDefinitionName `
		-VirtualNetworkSubnetName $VirtualNetworkSubnetName `
		-ImageGalleryName $ImageGalleryName `
		-ImageGalleryResourceGroupName $ImageGalleryResourceGroupName `
		-localadminAutomationCreName $localadminAutomationCreName


#  Add the VM Extensions

.\Deploy-SessionHostExtensions.ps1 `
		-AutomationAccountName $AutomationAccountName `
		-ResourceGroupName $resourceGroupName `
		-virtualMachineName $virtualMachineName `
		-VMLocation $VMLocation `
		-AutomationAccountResourceGroupName $AutomationAccountResourceGroupName `
		-domainAutomationCreName $domainAutomationCreName `
		-domainAutomationVariable $domainAutomationVariable `
		-WorkspaceIDvariable $WorkspaceIDvariable `
		-WorkspaceKeyvariable $WorkspaceKeyvariable


# Download token, agents, and session hosts.

.\Register-SessionHost.ps1 `
		-ResourceGroupName $resourceGroupName `
		-virtualMachineName $virtualMachineName `
		-VMLocation $VMLocation `
		-avdHostPoolName $AVDHostPoolName `
		-AVDResourceGroupName $AVDResourceGroupName


# Install Office 365

.\Install-Office365.ps1 `
		-ResourceGroupName $resourceGroupName `
		-virtualMachineName $virtualMachineName `
		-VMLocation $VMLocation
