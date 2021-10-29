
<#
    .DESCRIPTION
       Adds an additional Tag (Name\Value) to any Azure Resource with a specified pre-existing tag.

    .INPUTS
        targetTagName = Existing tag name.
        additionalTagName = Tag name to Add
        additionalTagValue = Additional Tag Value to Add

    .EXAMPLE
        Add-AzAddionalTag.ps1 -targetTagName ExistingValue -additionalTagName NewName -additionalTagValue NewTagValue

    .NOTES
    
        - Requires Az.Resources module
#>

param (

    $targetTagName,
    $additionalTagName, 
    $additionalTagValue
    
)
     
$VerbosePreference = "SilentlyContinue"
    
# Set Preferences
Import-Module Az.Resources
    
$VerbosePreference = "Continue"
$ErrorActionPreference = "Stop" 
    
try {
    
    $azSubs = Get-AzSubscription
    foreach ($azSub in $azSubs) {
    
        Write-Verbose "Scanning sub $($azSub.Name)"
        Set-AzContext -Subscription $azSub | Out-Null
    
        $targetResources = Get-AzResource | Where-Object { $_.Tags.Keys -match $targetTagName -and $_.Tags.Keys -notmatch $additionalTagName } 
    
        foreach ($targetResource in $targetResources) {
    
            Write-Verbose "Updating Tag\Value to Resource: $($targetResource.Name) in Resource Group: $($targetResource.Name) under Subscription: $($azSub.Name)"
    
            Update-AzTag -ResourceId $targetResource.Id -Tag @{$additionalTagName = $additionalTagValue } -Operation Merge -Confirm:$false | Out-Null

            Write-Verbose "Updated Resource: $($targetResource.Name) in Resource Group: $($targetResource.Name) with new tag."
    
        }
    
    }
    
    
}
catch {
    
    Write-Error -Message $_.Exception
    throw $_.Exception
    
}