<#
    .DESCRIPTION
       Deploys extensions on virtual machine

    .INPUTS
         
        virtualMachineName -  The name of the virtual machine name.

        resourceGroupName - The resource group which contains the target VM.

        VMLocation - The location of the target VM 

        domainAutomationCreName - The name of the Azure Automation credential which contains the credential in UPN (user@contoso.com) format.

        domainAutomationVariable - The unencrypted variable in Azure Automation which contains the target FQDN of the domain that you will be joining the session host to. 

        AutomationAccountName -  The name of the automation account that is used to run this runbook.

        AutomationAccountResourceGroupName - The Azure Automation account resource group name.

        WorkspaceIDvariable -   The unencrypted variable in Azure Automation which contains the target log analytics workspace ID.

        WorkspaceKeyvariable -  The unencrypted variable in Azure Automation which contains the target log analytics workspace key.

    .NOTES
    
#>

param (

    [string]$virtualMachineName,
    [string]$resourceGroupName,
    [string]$VMLocation,
    [string]$domainAutomationCreName,
    [string]$domainAutomationVariable,
    [string]$AutomationAccountName,
    [string]$AutomationAccountResourceGroupName,
    [string]$WorkspaceIDvariable,
    [string]$WorkspaceKeyvariable
    
)    


# Set Preferences

$ErrorActionPreference = 'Stop'
$VerbosePreference = "SilentlyContinue"

# Import Required Modules
Import-Module Az.Accounts
Import-Module Az.Compute
Import-Module Az.Automation

# Set Preferences 
$VerbosePreference = "Continue"

# Log Inputs

Write-Verbose -Message "To Do: Put all the inputs here for debugging"
 

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

# Get the Domain 

Write-Verbose -Message "Getting the domain FQDN"

$params = @{

    AutomationAccountName = $AutomationAccountName
    ResourceGroupName     = $AutomationAccountResourceGroupName
    Name                  = $domainAutomationVariable

}

$domainName = Get-AzAutomationVariable @params

# Get-Domain Automation Credential.

Write-Verbose -Message "Getting the domain credential. Be aware that the user name needs to be in xxxxx@xxxxxx.xxx format"

$params = @{

    Name = $domainAutomationCreName

}

$domainJoinCred = Get-AutomationPSCredential @params

# Join the VM to the Domain
Write-Verbose -Message "Joining the VM to the domain."

$params = @{

    
    ResourceGroupName = $resourceGroupName
    VMName            = $virtualMachineName
    DomainName        = $domainName.Value
    Credential        = $domainJoinCred
    JoinOption        = 0x00000003
    Restart           = $true
    Name              = "ADJoin"



}

Set-AzVMADDomainExtension  @params | Out-Null

# Join the VM to the log analytics workspace

# Get LA Workspace ID
$params = @{

    AutomationAccountName = $AutomationAccountName
    ResourceGroupName     = $AutomationAccountResourceGroupName
    Name                  = $WorkspaceIDvariable

}

$WorkspaceId = (Get-AzAutomationVariable @params).Value
Write-Verbose -Message "Workspace ID is: $WorkspaceId"

# Get LA Workspace Key

$params = @{

    AutomationAccountName = $AutomationAccountName
    ResourceGroupName     = $AutomationAccountResourceGroupName
    Name                  = $WorkspaceKeyvariable

}

$WorkspaceKey = (Get-AzAutomationVariable @params).Value

Write-Verbose -Message "Workspace key is: $WorkspaceKey"

<#

Use only when not deploying with Policy.  You should deploy with Azure Policy

Write-Verbose -Message "Installing Azure Monitor"

$PublicSettings = @{"workspaceId" = $WorkspaceId; "stopOnMultipleConnections" = "true" }
$ProtectedSettings = @{"workspaceKey" = $WorkspaceKey }

$params = @{

    ExtensionName      = 'Microsoft.EnterpriseCloud.Monitoring'
    ExtensionType      = 'MicrosoftMonitoringAgent'
    Publisher          = 'Microsoft.EnterpriseCloud.Monitoring' 
    ResourceGroupName  = $resourceGroupName
    VMName             = $virtualMachineName
    Location           = $VMLocation
    TypeHandlerVersion = '1.0'
    Settings           = $PublicSettings
    ProtectedSettings  = $ProtectedSettings


}

Set-AzVMExtension @params | Out-Null



# Deploy the Dependency Agent
Write-Verbose -Message "Deploying the dependency agent"

$params = @{

    Name               = 'DependencyAgentWindows'
    ExtensionType      = 'DependencyAgentWindows'
    Publisher          = 'Microsoft.Azure.Monitoring.DependencyAgent' 
    ResourceGroupName  = $resourceGroupName
    VMName             = $virtualMachineName
    Location           = $VMLocation
    TypeHandlerVersion = '9.5'

}

Set-AzVMExtension @params | Out-Null
#>


Write-Verbose -Message "End runbook Deploy-SessionHostExtensions"



