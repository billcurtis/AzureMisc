# Description - Quick script to demo how to replace the Workspace on a Azure VM.

# Set String Data

$VMName = 'Blah3'
$ResourceGroupName = 'BLAHBLAH_GROUP'
$workspaceID = '<workspace id here!>'
$workspaceKey = '<workspace key here!>'
 

# Set Preferences 

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

# Get VM Data

$VM = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroupName
Write-Verbose $VM

# Get all extensions for that VM

$workSpaces = ((Get-AzVMExtension -VMName $VMName -ResourceGroupName $VM.ResourceGroupName).PublicSettings | ConvertFrom-JSON).WorkspaceID

Write-Verbose 'Attached Workspaces'
Write-Verbose '==================='
foreach ($workSpace in $workSpaces) {Write-Verbose "$workSpace"}

# Set the required workspace information

$PublicSettings = @{"workspaceId" = $workspaceID }
$ProtectedSettings = @{"workspaceKey" = $workspaceKey }

$params = @{

    VMName = $VMName
    ExtensionName      = "MicrosoftMonitoringAgent"
    ResourceGroupName  = $VM.ResourceGroupName
    Publisher          = "Microsoft.EnterpriseCloud.Monitoring"
    ExtensionType      = "MicrosoftMonitoringAgent"
    TypeHandlerVersion = '1.0'
    Settings           = $PublicSettings 
    ProtectedSettings  = $ProtectedSettings 
    Location           = $VM.Location

}

Set-AzVMExtension @params

