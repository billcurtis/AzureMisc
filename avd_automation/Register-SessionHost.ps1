<#
    .DESCRIPTION

       Registers the created VM as a session host.

    .INPUTS
       
       AVDHostPoolName = The AVD host pool name where the VM will be associated.

       AVDResourceGroupName = The AVD Resource Group name in which the AVD host pool is contained.

       virtualMachineName -  The name of the virtual machine name.

       resourceGroupName - The resource group which contains the target VM.

       VMLocation - The location of the target VM.


    .NOTES

    #>

param (

    [string]$AVDHostPoolName,
    [string]$AVDResourceGroupName,
    [string]$resourceGroupName,
    [string]$virtualMachineName,
    [string]$VMLocation

)

# Set Preferences

$ErrorActionPreference = 'Stop'
$VerbosePreference = "SilentlyContinue"

# Import Required Modules
Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.DesktopVirtualization

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



# Get Registration Token that will be passed to the Virtual Machine

Write-Verbose -Message "Getting Registration Token for AVD"

$params = @{


    HostPoolName      = $AVDHostPoolName
    ResourceGroupName = $AVDResourceGroupName
    ExpirationTime    = $((get-date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')) 

}

$RegistrationToken = (New-AzWvdRegistrationInfo @params).Token



# Deploy Custom Script Extension to download the AVD Agent

Write-Verbose -Message "Deploying the Custom Script Extension - Installing script Install-AVDAgents.ps1"

$params = @{


    Name              = "CustomScriptExtension"
    FileUri           = "https://raw.githubusercontent.com/billcurtis/AzureMisc/master/avd_automation/Install-AVDAgents.ps1"
    ResourceGroupName = $resourceGroupName
    VMName            = $virtualMachineName
    Location          = $VMLocation
    Run               = "Install-AVDAgents.ps1 -RegistrationToken $RegistrationToken"

}

Set-AzVMCustomScriptExtension @params | Out-Null

Write-Verbose -Message "End runbook Register-SessionHost.ps1"