# This script is meant to be called from the Register-SessionHost Azure Automation Runbook.

# This script downloads and then installs the Azure Virtual Desktop Agent and the Azure Bootloader agent INSIDE of the Session Host virtual machine.

param ($RegistrationToken)

$AVDAgentURI = 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv'
$AVDBootLoaderAgentURI = 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH'


# Create Location
New-Item -Path C:\Users -Name TempDirectory -ItemType Directory -Force | Out-Null
Set-Location C:\Users\TempDirectory

# Download Azure Virtual Desktop Agent
Invoke-WebRequest -Uri $AVDAgentURI -OutFile C:\Users\TempDirectory\AVDAgent.msi

# Download Azure Bootloader Agent
Invoke-WebRequest -Uri $AVDBootLoaderAgentURI -OutFile C:\Users\TempDirectory\AVDBootLoader.msi


# Install AVD Agent
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i C:\Users\TempDirectory\AVDAgent.msi", "/quiet", "/qn", "/norestart", "/passive", "REGISTRATIONTOKEN=$RegistrationToken", "/l* C:\Users\TempDirectory\AgentInstall.txt" -Wait | Out-Null

# Install AVD Bootloader
Start-Process -FilePath "msiexec.exe" -ArgumentList "/i C:\Users\TempDirectory\AVDBootLoader.msi", "/quiet", "/qn", "/norestart", "/passive", "/l* C:\Users\TempDirectory\AgentBootLoaderInstall.txt" -Wait -Passthru | Out-Null


# (Optional) Remove the C:\Users\TempDirectory

#Remove-Item -Path "C:\Users\TempDirectory"  -Force -Recurse -Confirm $false