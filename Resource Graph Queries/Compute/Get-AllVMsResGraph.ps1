# Ensure the Az module is available
# Install-Module -Name Az -Scope CurrentUser -Force

# Log in to Azure
#Connect-AzAccount

# Get all accessible subscriptions
$subscriptions = Get-AzSubscription -TenantId $tenantid
# Loop through each subscription
foreach ($sub in $subscriptions) {
    Write-Host "Querying subscription: $($sub.Name)"

    # Set context for current subscription (optional but useful if debugging)
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Build per-subscription query (optional: add filters)
    $query = @"
Resources
| where type == "microsoft.compute/virtualmachines"
| extend vmName = name,
         creationTime = todatetime(properties.timeCreated),
         location = location,
         subscriptionId = subscriptionId
| project vmName, creationTime, location, subscriptionId
"@

    # Query ARG for this subscription only
    $results = Search-AzGraph -Query $query -Subscription $sub.Id -First 1000

    # Map subscription name into results
    $vmOutput = $results | Select-Object `
        @{Name = "VMName"; Expression = { $_.vmName }},
        @{Name = "CreationTime"; Expression = { $_.creationTime }},
        @{Name = "Location"; Expression = { $_.location }},
        @{Name = "SubscriptionId"; Expression = { $_.subscriptionId }},
        @{Name = "SubscriptionName"; Expression = { $sub.Name }}

    # Add to master list
    $allVmResults += $vmOutput
}

# Export the results to a CSV file
$csvPath = "C:\Users\wcurtis\OneDrive - Microsoft\Customers\Exxon\XOMData\AVDSessionHosts\XOMSessionHosts.csv"
$vmOutput | Export-Csv -Path $csvPath -NoTypeInformation -Force

Write-Host "✅ VM report exported to: $csvPath"
