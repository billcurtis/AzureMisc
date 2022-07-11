
<#
    .DESCRIPTION
       Deletes all of the font files in a MBR partition per:
       https://support.microsoft.com/en-us/topic/-we-couldn-t-update-system-reserved-partition-error-installing-windows-10-46865f3f-37bb-4c51-c69f-07271b6672ac

    .INPUTS
        No inputs or outputs

    .EXAMPLE
        FreeMSRSpace-MBR.ps1

    .NOTES
    
        - Script needs to be run with Admin privileges
#>


# Set Preferences

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

$tempDriveLetter = 'x'

# Get System Reserved Partition
$partition = Get-Volume | Where-Object { $_.FileSystemLabel -match "System Reserved" } | Get-Partition

# Check to see if we have more than one system partition
if ($partition.count -gt 1) { Write-Error "More than one System Partition was found. Aborting" }

# Assign Drive letter to partition
try {

    $partition | Set-Partition -NewDriveLetter $tempDriveLetter

}
catch {

    Write-Error "Failure! Ensure that this PowerShell script is running with administrative privileges"

}


# Set permissions on 


# Generate and test Path

$msrPath = "$($tempDriveLetter):\Boot\Fonts"
$msrPathTest = Test-Path -Path $msrPath

# Delete the font files
if ($msrPathTest) {

    Set-Location $msrPath

    # Take ownership
    $expression = "takeown /d y /r /f ."
    Write-Verbose -Message "Invoking $expression"
    Invoke-Expression -Command $expression

    # Set permissions
    $ErrorActionPreference = "SilentlyContinue"
    $expression = "icacls $($tempDriveLetter):\Boot\Fonts\* /save c:\NTFSp.txt /c /t"
    Write-Verbose -Message "Invoking $expression"
    Invoke-Expression -Command $expression
    $ErrorActionPreference = "Stop"

    # Get current username
    $Username = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name).Split('\')[1]

    # Grant current user permissions
    $expression = "icacls . /grant $($username):F /t"
    Write-Verbose -Message "Invoking $expression"
    Invoke-Expression -Command $expression

    Get-ChildItem  -Path $msrPath -Filter *.ttf | Remove-Item -Verbose

}
else {

    Write-Error "$msrPath does NOT exist!"

}


# Remove Drive Letter from partition

$partition | Remove-PartitionAccessPath -AccessPath  "$tempDriveLetter`:\"
