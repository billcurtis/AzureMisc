

# Input Variable

$ResourceGroupName = "Test1"
$ResourceGroupLocation = "EastUS"
$rgCheck = $null

# Set preferences

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Get all subscriptions

Write-Verbose -Message 'Getting Subscriptions'
$subscriptions = Get-AzSubscription

# Cycle through all Azure subscriptions and perform logic.

try {

foreach ($subscription in $subscriptions) {

    # Set Context to subscription

    Write-Verbose -Message "=============================================================="
    Write-Verbose -Message "Setting Context to $($subscription.Name)-($($subscription.id))"
    Set-AzContext -SubscriptionObject $subscription | Out-Null

    # Check for ResourceGroupName in Subscription

    $rgCheck = Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName }

    # Create Resource Group if that Resource Group is not present in subscription

    if (!$rgCheck) {

        Write-Verbose -Message `
            "Could not find RG: $ResourceGroupName. Adding ResourceGroup to subscription $($subscription.Name)-($($subscription.id))."

        New-AzResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation  | Out-Null

        $rgCheck = Get-AzResourceGroup | Where-Object { $_.Name -eq $ResourceGroupName }
        if (!$rgCheck) { Write-Verbose "Successfully created RG: $ResourceGroupName" }

    }
    else {
    
        Write-Verbose  "RG: $ResourceGroupName was found. Skipping this subscription"

    }


}
}
catch {

    Write-Error -Message $_.Exception
    throw $_.Exception

}


# end

