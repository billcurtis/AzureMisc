
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