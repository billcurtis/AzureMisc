# static variables
$fileUri = "https://wcurtisdemo.blob.core.windows.net/dscflats/npp.8.6.4.Installer.x64.exe?sp=r&st=2024-03-13T18:15:00Z&se=2024-06-11T18:15:00Z&sv=2022-11-02&sr=b&sig=ZmMfHCPwmQ7wMY%2F%2BgiMjwMuM8clB2XelFkaCNWriQo0%3D"
$filePath = "C:\Temp\NotepadInstall"

# set preferences
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"

# make directory for notepad++ installation
New-Item -Path $filePath -ItemType Directory -Force -Confirm:$false

# download notepad++
$params = @{

Uri = $fileUri
Outfile = "$filepath\npp.8.6.4.Installer.x64.exe"

}

Invoke-WebRequest @params

# install notepad++
$expression = "$filepath\npp.8.6.4.Installer.x64.exe /S"
Invoke-Expression -Command $expression

# remove folder
Remove-Item -LiteralPath $filePath -Recurse -Force -Confirm:$false