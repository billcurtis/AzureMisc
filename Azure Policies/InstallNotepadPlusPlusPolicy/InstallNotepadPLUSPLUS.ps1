<#
.DESCRIPTION

   This policy downloads and installs Notepad++ on the virtual machine.
   This script is intended to be used by a Policy Assignment.

.INPUTS

Here are the static variables that are to be hardcoded into the script:

   fileUri = The URI of the file to download.

   filePath = The path to the folder where the file will be downloaded.

   filename = The name of the file to download.

   fileargs = The arguments to pass to the file

#>


# static variables
$fileUri = "<BLOB FILE URI HERE>"
$filePath = "D:\Temp\NotepadInstall"
$filename = "npp.8.6.4.Installer.x64.exe"
$fileargs = "/S"

# set preferences
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop"

# make directory for notepad++ installation
New-Item -Path $filePath -ItemType Directory -Force -Confirm:$false

# download notepad++
$params = @{

    Uri     = $fileUri
    Outfile = "$filepath\$filename"

}

Invoke-WebRequest @params

# install notepad++
$expression = "$filepath\$filename $fileargs"
Invoke-Expression -Command $expression

# remove installation file and folder
Start-Sleep -Seconds 5 #wait for handle to be released from the installer file
Remove-Item -LiteralPath $filePath -Recurse -Force -Confirm:$false