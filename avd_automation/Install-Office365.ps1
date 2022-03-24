<#
    .DESCRIPTION

       Deploys Office 365 to the Host.

    .INPUTS
       
       virtualMachineName -  The name of the virtual machine name.

       resourceGroupName - The resource group which contains the target VM.

       VMLocation - The location of the target VM.


    .NOTES

    #>

    param (


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
 
        
    # Deploy Custom Script Extension to download and install Office 365
    
    Write-Verbose -Message "Deploying the Custom Script Extension - Installing script Install-Office365.ps1"
    
    $params = @{
    
    
        Name              = "CustomScriptExtension"
        FileUri           = "https://raw.githubusercontent.com/mallockey/Install-Office365Suite/master/Install-Office365Suite.ps1"
        ResourceGroupName = $resourceGroupName
        VMName            = $virtualMachineName
        Location          = $VMLocation
        Run               = "Install-Office365Suite.ps1"
    
    }
    
    Set-AzVMCustomScriptExtension @params | Out-Null
    
    Write-Verbose -Message "End runbook Install-Office365.ps1"