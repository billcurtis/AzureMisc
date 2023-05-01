
# Code above this will load in Azure Automation variables

$report = @()

# Main Code

$subscriptions = Get-AzSubscription

foreach ($subscription in $subscriptions) {

    Set-AzContext -SubscriptionId $subscription.Id

    $VMs = $null
    $VMs = Get-AzVM 
    
    foreach ($VM in $VMs) {

    $report += Get-AzVM -Name $VM.Name -Status

    }

}

$report | ConvertTo-JSON -Depth 100 -Compress
