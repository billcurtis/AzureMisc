$context = Get-AzContext
$tenantId = $context.Tenant.Id
$accessToken = (Get-AzAccessToken).Token

# Get all subscriptions and build mapping of ID -> Name
$subscriptions = Get-AzSubscription -TenantId $tenantid
$subIdList = $subscriptions.Id
$subMap = @{}
$subscriptions | ForEach-Object {
    $subMap[$_.Id] = $_.Name
}

# Build request URL
$resourceGraphUrl = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-04-01"

# Define KQL query for virtual machines
$kqlQuery = @"
Resources
| where type == "microsoft.compute/virtualmachines"
| extend vmName = name,
         creationTime = todatetime(properties.timeCreated),
         location = location,
         subscriptionId = subscriptionId
| project vmName, creationTime, location, subscriptionId
"@

# Prepare the body for the first request
$requestBody = @{
    subscriptions = $subIdList
    query         = $kqlQuery
    options       = @{
        top = 1000
        resultFormat = "objectArray"
    }
} | ConvertTo-Json -Depth 10

# Initialize result array
$allResults = @()
$skipToken = $null

do {
    # If there's a skip token, include it
    if ($skipToken) {
        $requestBody = @{
            subscriptions = $subIdList
            query         = $kqlQuery
            options       = @{
                $top = 1000
                $skipToken = $skipToken
                resultFormat = "objectArray"
            }
        } | ConvertTo-Json -Depth 10
    }

    # Make the API request
    $response = Invoke-RestMethod -Method Post -Uri $resourceGraphUrl -Headers @{
        Authorization = "Bearer $accessToken"
    } -Body $requestBody

    # Append results
    foreach ($record in $response.data) {
        $allResults += [PSCustomObject]@{
            VMName            = $record.vmName
            CreationTime      = $record.creationTime
            Location          = $record.location
            SubscriptionId    = $record.subscriptionId
            SubscriptionName  = $subMap[$record.subscriptionId]
        }
    }

    # Handle pagination
    $skipToken = $response.skipToken

} while ($skipToken)


# Export the results to a CSV file
$csvPath = "C:\Users\wcurtis\OneDrive - Microsoft\Customers\Exxon\XOMData\AVDSessionHosts\XOMSessionHosts.csv"
$allResults | Export-Csv -Path $csvPath -NoTypeInformation -Force

Write-Host "✅ VM report exported to: $csvPath"
