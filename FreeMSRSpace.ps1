
<#
    .DESCRIPTION
       Deletes all of the font files in a GPT MSR partition per:
       https://support.microsoft.com/en-us/topic/-we-couldn-t-update-system-reserved-partition-error-installing-windows-10-46865f3f-37bb-4c51-c69f-07271b6672ac

    .INPUTS
        No inputs or outputs

    .EXAMPLE
        FreeMSRSpace.ps1

    .NOTES
    
        - Script needs to be run with Admin privileges
#>


# Set Preferences

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

$tempDriveLetter = 'X'

# Get System Reserved Partition
$partition = Get-Partition | Where-Object { $_.Type -eq "System" }

# Check to see if we have more than one system partition
if ($partition.count -gt 1) { Write-Error "More than one System Partition was found. Aborting" }

# Check to make sure we have a GPT disk
if (!$partition.GptType) { Write-Warning "Disk is not of type GPT. Script may not work!"}

# Assign Drive letter to partition
try {

    $partition | Set-Partition -NewDriveLetter $tempDriveLetter

}
catch {

    Write-Error "Failure! Ensure that this PowerShell script is running with administrative privileges"

}

# Generate and test Path

$msrPath = "$($tempDriveLetter):\EFI\Microsoft\Boot\Fonts"
$msrPathTest = Test-Path -Path $msrPath

# Delete the font files
if ($msrPathTest) {


    Get-ChildItem  -Path $msrPath -Filter *.ttf | Remove-Item -Verbose


}
else {

    Write-Error "$msrPath does NOT exist!"

}


# Remove Drive Letter from partition

$partition | Remove-PartitionAccessPath -AccessPath  "$tempDriveLetter`:\"
