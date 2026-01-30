<#
.SYNOPSIS
    Gets Azure consumption costs for NAT Gateways and associated Public IP addresses.

.DESCRIPTION
    This script retrieves Azure consumption (pricing) data for NAT Gateways and their 
    associated Public IP addresses for a specified number of days. It also retrieves
    the data processed (in GB) through each NAT Gateway using Azure Monitor metrics.
    
    The script can query a single subscription, multiple specific subscriptions, or 
    all accessible subscriptions.

.PARAMETER Days
    The number of days to look back for consumption data. Default is 30.

.PARAMETER SubscriptionId
    Optional. The Azure subscription ID to query. If not specified, uses the current context.
    Cannot be used with -SubscriptionIds or -AllSubscriptions.

.PARAMETER SubscriptionIds
    Optional. An array of Azure subscription IDs to query.
    Cannot be used with -SubscriptionId or -AllSubscriptions.

.PARAMETER AllSubscriptions
    Optional. If specified, queries all accessible subscriptions.
    Cannot be used with -SubscriptionId or -SubscriptionIds.

.PARAMETER ResourceGroupName
    Optional. Filter results to a specific resource group.

.EXAMPLE
    .\Get-NATGatewayCosts.ps1
    Gets NAT Gateway costs for the last 30 days in the current subscription.

.EXAMPLE
    .\Get-NATGatewayCosts.ps1 -Days 7
    Gets NAT Gateway costs for the last 7 days in the current subscription.

.EXAMPLE
    .\Get-NATGatewayCosts.ps1 -AllSubscriptions
    Gets NAT Gateway costs for the last 30 days across ALL accessible subscriptions.

.EXAMPLE
    .\Get-NATGatewayCosts.ps1 -SubscriptionIds @("sub-id-1", "sub-id-2") -Days 14
    Gets NAT Gateway costs for the last 14 days in the specified subscriptions.

.EXAMPLE
    .\Get-NATGatewayCosts.ps1 -Days 14 -ResourceGroupName "MyResourceGroup"
    Gets NAT Gateway costs for the last 14 days in the specified resource group.

.EXAMPLE
    # Get DAILY cost breakdown for NAT Gateways using Cost Management Query API
    # This queries Azure directly with daily granularity
    
    $subscriptionId = (Get-AzContext).Subscription.Id
    $scope = "/subscriptions/$subscriptionId"
    $startDate = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")
    $endDate = (Get-Date).ToString("yyyy-MM-dd")
    
    $dailyCosts = Invoke-AzCostManagementQuery -Scope $scope -Type "ActualCost" `
        -Timeframe "Custom" `
        -TimePeriodFrom $startDate `
        -TimePeriodTo $endDate `
        -DatasetGranularity "Daily" `
        -DatasetAggregation @{
            "TotalCost" = @{ "name" = "Cost"; "function" = "Sum" }
        } `
        -DatasetGrouping @(
            @{ "type" = "Dimension"; "name" = "ResourceId" },
            @{ "type" = "Dimension"; "name" = "ResourceType" }
        ) `
        -DatasetFilter @{
            "Dimensions" = @{
                "Name" = "ResourceType"
                "Operator" = "In"
                "Values" = @("microsoft.network/natgateways", "microsoft.network/publicipaddresses")
            }
        }
    
    # Parse and display the daily results
    $dailyCosts.Row | ForEach-Object {
        [PSCustomObject]@{
            Date = $_[1]
            Cost = [math]::Round($_[0], 4)
            ResourceId = $_[2]
            ResourceType = $_[3]
        }
    } | Sort-Object Date | Format-Table -AutoSize

.EXAMPLE
    # Get daily NAT Gateway costs for the last 30 days and export to CSV
    
    $subscriptionId = (Get-AzContext).Subscription.Id
    $scope = "/subscriptions/$subscriptionId"
    
    $dailyCosts = Invoke-AzCostManagementQuery -Scope $scope -Type "ActualCost" `
        -Timeframe "MonthToDate" `
        -DatasetGranularity "Daily" `
        -DatasetAggregation @{
            "TotalCost" = @{ "name" = "Cost"; "function" = "Sum" }
        } `
        -DatasetGrouping @(
            @{ "type" = "Dimension"; "name" = "ResourceId" }
        ) `
        -DatasetFilter @{
            "Dimensions" = @{
                "Name" = "ResourceType"
                "Operator" = "In"
                "Values" = @("microsoft.network/natgateways")
            }
        }
    
    $results = $dailyCosts.Row | ForEach-Object {
        [PSCustomObject]@{
            Date = $_[1]
            DailyCostUSD = [math]::Round($_[0], 4)
            NATGatewayName = ($_[2] -split '/')[-1]
            ResourceId = $_[2]
        }
    }
    
    $results | Export-Csv -Path "NATGateway_DailyCosts.csv" -NoTypeInformation
    $results | Format-Table -AutoSize

.EXAMPLE
    # Get yesterday's NAT Gateway costs only (useful for daily monitoring/alerts)
    
    $yesterday = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $subscriptionId = (Get-AzContext).Subscription.Id
    
    $yesterdayCosts = Invoke-AzCostManagementQuery `
        -Scope "/subscriptions/$subscriptionId" `
        -Type "ActualCost" `
        -Timeframe "Custom" `
        -TimePeriodFrom $yesterday `
        -TimePeriodTo $today `
        -DatasetGranularity "Daily" `
        -DatasetAggregation @{
            "TotalCost" = @{ "name" = "Cost"; "function" = "Sum" }
        } `
        -DatasetGrouping @(
            @{ "type" = "Dimension"; "name" = "ResourceId" }
        ) `
        -DatasetFilter @{
            "Dimensions" = @{
                "Name" = "ResourceType"
                "Operator" = "In"
                "Values" = @("microsoft.network/natgateways")
            }
        }
    
    $yesterdayCosts.Row | ForEach-Object {
        Write-Host "NAT Gateway: $(($_[2] -split '/')[-1]) - Cost: `$$([math]::Round($_[0], 2))"
    }

.EXAMPLE
    # Compare NAT Gateway costs between two date ranges (e.g., this week vs last week)
    
    $subscriptionId = (Get-AzContext).Subscription.Id
    $scope = "/subscriptions/$subscriptionId"
    
    # This week
    $thisWeekStart = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")
    $thisWeekEnd = (Get-Date).ToString("yyyy-MM-dd")
    
    # Last week
    $lastWeekStart = (Get-Date).AddDays(-14).ToString("yyyy-MM-dd")
    $lastWeekEnd = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")
    
    $queryParams = @{
        Type = "ActualCost"
        DatasetGranularity = "None"
        DatasetAggregation = @{ "TotalCost" = @{ "name" = "Cost"; "function" = "Sum" } }
        DatasetFilter = @{
            "Dimensions" = @{
                "Name" = "ResourceType"
                "Operator" = "In"
                "Values" = @("microsoft.network/natgateways")
            }
        }
    }
    
    $thisWeekCost = (Invoke-AzCostManagementQuery -Scope $scope @queryParams `
        -Timeframe "Custom" -TimePeriodFrom $thisWeekStart -TimePeriodTo $thisWeekEnd).Row[0][0]
    
    $lastWeekCost = (Invoke-AzCostManagementQuery -Scope $scope @queryParams `
        -Timeframe "Custom" -TimePeriodFrom $lastWeekStart -TimePeriodTo $lastWeekEnd).Row[0][0]
    
    $percentChange = if ($lastWeekCost -gt 0) { 
        [math]::Round((($thisWeekCost - $lastWeekCost) / $lastWeekCost) * 100, 2) 
    } else { 0 }
    
    Write-Host "This Week: `$$([math]::Round($thisWeekCost, 2))"
    Write-Host "Last Week: `$$([math]::Round($lastWeekCost, 2))"
    Write-Host "Change: $percentChange%"

.EXAMPLE
    # Get NAT Gateway data processed (bytes) metrics daily using Azure Monitor
    
    $natGateway = Get-AzNatGateway -ResourceGroupName "myRG" -Name "myNatGateway"
    $startTime = (Get-Date).AddDays(-7)
    $endTime = Get-Date
    
    # Get daily ByteCount metrics
    $metrics = Get-AzMetric -ResourceId $natGateway.Id `
        -MetricName "ByteCount" `
        -StartTime $startTime `
        -EndTime $endTime `
        -TimeGrain 1.00:00:00 `
        -AggregationType Total
    
    $metrics.Data | ForEach-Object {
        [PSCustomObject]@{
            Date = $_.TimeStamp.ToString("yyyy-MM-dd")
            DataProcessedGB = [math]::Round($_.Total / 1GB, 2)
        }
    } | Format-Table -AutoSize

.EXAMPLE
    # Get all NAT Gateway consumption details with daily granularity
    
    $startDate = (Get-Date).AddDays(-7)
    $endDate = Get-Date
    
    $usage = Get-AzConsumptionUsageDetail -StartDate $startDate -EndDate $endDate |
        Where-Object { $_.InstanceId -match "natGateways" } |
        Select-Object @{N='Date';E={$_.UsageStart.ToString("yyyy-MM-dd")}},
                      @{N='NATGateway';E={($_.InstanceId -split '/')[-1]}},
                      @{N='MeterName';E={$_.MeterName}},
                      @{N='Quantity';E={$_.UsageQuantity}},
                      @{N='Cost';E={[math]::Round($_.PretaxCost, 4)}},
                      Currency
    
    $usage | Sort-Object Date | Format-Table -AutoSize
    
    # Daily totals
    $usage | Group-Object Date | ForEach-Object {
        [PSCustomObject]@{
            Date = $_.Name
            TotalCost = [math]::Round(($_.Group | Measure-Object -Property Cost -Sum).Sum, 2)
        }
    } | Format-Table -AutoSize
#>

[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter()]
    [int]$Days = 30,

    [Parameter(ParameterSetName = 'Single')]
    [string]$SubscriptionId,

    [Parameter(ParameterSetName = 'Multiple')]
    [string[]]$SubscriptionIds,

    [Parameter(ParameterSetName = 'All')]
    [switch]$AllSubscriptions,

    [Parameter()]
    [string]$ResourceGroupName
)

#region Functions

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "White" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-NATGatewayDataProcessed {
    <#
    .SYNOPSIS
        Gets the data processed through a NAT Gateway using Azure Monitor metrics.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId,
        
        [Parameter(Mandatory)]
        [datetime]$StartTime,
        
        [Parameter(Mandatory)]
        [datetime]$EndTime
    )

    try {
        # Get the ByteCount metric for the NAT Gateway
        # ByteCount represents total bytes processed
        $metrics = Get-AzMetric -ResourceId $ResourceId `
            -MetricName "ByteCount" `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -TimeGrain 1.00:00:00 `
            -AggregationType Total `
            -WarningAction SilentlyContinue `
            -ErrorAction SilentlyContinue

        if ($metrics -and $metrics.Data) {
            $totalBytes = ($metrics.Data | Measure-Object -Property Total -Sum).Sum
            if ($null -eq $totalBytes) { $totalBytes = 0 }
            return [math]::Round($totalBytes / 1GB, 2)
        }
        
        # Try alternative metric names
        $metrics = Get-AzMetric -ResourceId $ResourceId `
            -MetricName "DatapathAvailability" `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -TimeGrain 1.00:00:00 `
            -AggregationType Average `
            -WarningAction SilentlyContinue `
            -ErrorAction SilentlyContinue

        return 0
    }
    catch {
        Write-Log "Could not retrieve metrics for $ResourceId : $_" -Level "WARNING"
        return 0
    }
}

function Get-NATGatewayBytesMetrics {
    <#
    .SYNOPSIS
        Gets detailed byte metrics (Inbound, Outbound, SNAT) for a NAT Gateway.
    .DESCRIPTION
        Uses the ByteCount metric with Direction dimension to get inbound/outbound traffic separately.
        Uses REST API with dimension filter since Get-AzMetric doesn't support dimension filtering properly.
        Reference: https://learn.microsoft.com/en-us/azure/nat-gateway/nat-metrics
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId,
        
        [Parameter(Mandatory)]
        [datetime]$StartTime,
        
        [Parameter(Mandatory)]
        [datetime]$EndTime
    )

    $result = @{
        TotalBytesGB = 0
        InboundBytesGB = 0
        OutboundBytesGB = 0
        SNATConnectionCount = 0
        DroppedPackets = 0
    }

    # Get ByteCount with Direction dimension to split Inbound/Outbound
    # Must use REST API with $filter=Direction eq '*' to get the dimension split
    try {
        $startTimeStr = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $endTimeStr = $EndTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $filter = [System.Uri]::EscapeDataString("Direction eq '*'")
        
        $path = "$ResourceId/providers/microsoft.insights/metrics?api-version=2023-10-01&metricnames=ByteCount&timespan=$startTimeStr/$endTimeStr&interval=P1D&aggregation=Total&`$filter=$filter"
        
        $response = Invoke-AzRestMethod -Path $path -Method GET -ErrorAction SilentlyContinue
        
        if ($response -and $response.StatusCode -eq 200) {
            $content = $response.Content | ConvertFrom-Json
            
            if ($content.value -and $content.value[0].timeseries) {
                foreach ($timeseries in $content.value[0].timeseries) {
                    # Get direction from metadata
                    $direction = $null
                    if ($timeseries.metadatavalues) {
                        $directionMeta = $timeseries.metadatavalues | Where-Object { $_.name.value -eq "Direction" }
                        if ($directionMeta) {
                            $direction = $directionMeta.value
                        }
                    }
                    
                    # Sum all data points in this timeseries
                    $totalBytes = ($timeseries.data | ForEach-Object { $_.total } | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum
                    
                    if ($null -ne $totalBytes -and $totalBytes -gt 0) {
                        $gbValue = [math]::Round($totalBytes / 1GB, 2)
                        
                        switch ($direction) {
                            "In"  { $result.InboundBytesGB = $gbValue }
                            "Out" { $result.OutboundBytesGB = $gbValue }
                            default { $result.TotalBytesGB = $gbValue }
                        }
                    }
                }
            }
        }
        
        # Calculate total from inbound + outbound if we got dimension data
        if ($result.InboundBytesGB -gt 0 -or $result.OutboundBytesGB -gt 0) {
            $result.TotalBytesGB = [math]::Round($result.InboundBytesGB + $result.OutboundBytesGB, 2)
        }
        
        # Fallback: If no dimension data, try to get total without filter
        if ($result.TotalBytesGB -eq 0) {
            $pathNoFilter = "$ResourceId/providers/microsoft.insights/metrics?api-version=2023-10-01&metricnames=ByteCount&timespan=$startTimeStr/$endTimeStr&interval=P1D&aggregation=Total"
            $responseNoFilter = Invoke-AzRestMethod -Path $pathNoFilter -Method GET -ErrorAction SilentlyContinue
            
            if ($responseNoFilter -and $responseNoFilter.StatusCode -eq 200) {
                $contentNoFilter = $responseNoFilter.Content | ConvertFrom-Json
                if ($contentNoFilter.value -and $contentNoFilter.value[0].timeseries) {
                    $totalBytes = ($contentNoFilter.value[0].timeseries[0].data | ForEach-Object { $_.total } | Where-Object { $null -ne $_ } | Measure-Object -Sum).Sum
                    if ($null -ne $totalBytes -and $totalBytes -gt 0) {
                        $result.TotalBytesGB = [math]::Round($totalBytes / 1GB, 2)
                    }
                }
            }
        }
    }
    catch {
        Write-Log "Could not retrieve ByteCount metrics: $_" -Level "WARNING"
    }

    # Get other metrics (SNAT connections, dropped packets) using standard Get-AzMetric
    $otherMetrics = @(
        @{ Name = "SNATConnectionCount"; Property = "SNATConnectionCount"; Aggregation = "Total" },
        @{ Name = "DroppedPackets"; Property = "DroppedPackets"; Aggregation = "Total" }
    )

    foreach ($metricDef in $otherMetrics) {
        try {
            $metric = Get-AzMetric -ResourceId $ResourceId `
                -MetricName $metricDef.Name `
                -StartTime $StartTime `
                -EndTime $EndTime `
                -TimeGrain 1.00:00:00 `
                -AggregationType $metricDef.Aggregation `
                -WarningAction SilentlyContinue `
                -ErrorAction SilentlyContinue

            if ($metric -and $metric.Data) {
                $values = $metric.Data | ForEach-Object { $_.Total } | Where-Object { $null -ne $_ }
                $total = ($values | Measure-Object -Sum).Sum
                
                if ($null -ne $total -and $total -gt 0) {
                    switch ($metricDef.Property) {
                        "SNATConnectionCount" { $result.SNATConnectionCount = [math]::Round($total, 0) }
                        "DroppedPackets" { $result.DroppedPackets = [math]::Round($total, 0) }
                    }
                }
            }
        }
        catch {
            # Silently continue if a specific metric fails
        }
    }

    return $result
}

#endregion Functions

#region Main Script

Write-Log "Starting NAT Gateway Cost Analysis Script" -Level "INFO"
Write-Log "Analysis period: Last $Days days" -Level "INFO"

# Check if Azure PowerShell module is installed
Write-Log "Checking for Azure PowerShell installation..." -Level "INFO"

$azModule = Get-Module -ListAvailable -Name Az.Accounts -ErrorAction SilentlyContinue
if (-not $azModule) {
    Write-Host ""
    Write-Host "=" * 80 -ForegroundColor Yellow
    Write-Host "  Azure PowerShell Module Not Found" -ForegroundColor Yellow
    Write-Host "=" * 80 -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  The Azure PowerShell module (Az) is required but not installed." -ForegroundColor White
    Write-Host ""
    
    $installChoice = Read-Host "  Would you like to install Azure PowerShell now? (Y/N)"
    
    if ($installChoice -eq 'Y' -or $installChoice -eq 'y') {
        Write-Log "Installing Azure PowerShell module..." -Level "INFO"
        Write-Host ""
        Write-Host "  This may take several minutes..." -ForegroundColor Gray
        Write-Host ""
        
        try {
            # Check if running as admin for AllUsers scope, otherwise use CurrentUser
            $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            $scope = if ($isAdmin) { "AllUsers" } else { "CurrentUser" }
            
            Install-Module -Name Az -Scope $scope -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
            Write-Log "Azure PowerShell installed successfully!" -Level "SUCCESS"
            Write-Host ""
            Write-Host "  Please restart your PowerShell session and run this script again." -ForegroundColor Cyan
            Write-Host ""
            exit 0
        }
        catch {
            Write-Log "Failed to install Azure PowerShell: $_" -Level "ERROR"
            Write-Host ""
            Write-Host "  You can manually install it by running:" -ForegroundColor White
            Write-Host "    Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force" -ForegroundColor Green
            Write-Host ""
            exit 1
        }
    }
    else {
        Write-Host ""
        Write-Host "  To install Azure PowerShell manually, run:" -ForegroundColor White
        Write-Host "    Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force" -ForegroundColor Green
        Write-Host ""
        Write-Host "  For more information, visit:" -ForegroundColor White
        Write-Host "    https://docs.microsoft.com/en-us/powershell/azure/install-az-ps" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }
}

Write-Log "Azure PowerShell is installed." -Level "SUCCESS"

# Import required modules (install individual modules if missing)
$requiredModules = @('Az.Accounts', 'Az.Network', 'Az.CostManagement', 'Az.Monitor')

Write-Log "Checking and importing required Azure modules..." -Level "INFO"

foreach ($module in $requiredModules) {
    try {
        # Check if module is available
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Log "Module '$module' not found. Installing..." -Level "WARNING"
            Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Log "Installed module: $module" -Level "SUCCESS"
        }
        
        # Import the module if not already loaded
        if (-not (Get-Module -Name $module)) {
            Import-Module -Name $module -Force -ErrorAction Stop
            Write-Log "Imported module: $module" -Level "SUCCESS"
        }
        else {
            Write-Log "Module already loaded: $module" -Level "INFO"
        }
    }
    catch {
        Write-Log "Failed to install/import module '$module'. Error: $_" -Level "ERROR"
        Write-Log "Try running: Install-Module -Name $module -Scope CurrentUser -Force" -Level "INFO"
        exit 1
    }
}

# Check Azure connection and connect if needed
$context = Get-AzContext
if (-not $context) {
    Write-Log "Not connected to Azure. Initiating login..." -Level "INFO"
    Write-Host ""
    Write-Host "  A browser window will open for Azure authentication." -ForegroundColor Cyan
    Write-Host "  Please sign in with your Azure account." -ForegroundColor Cyan
    Write-Host ""
    
    try {
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $context = Get-AzContext
        
        if (-not $context) {
            Write-Log "Failed to connect to Azure. Please try again." -Level "ERROR"
            exit 1
        }
        
        Write-Log "Successfully connected to Azure as: $($context.Account.Id)" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to connect to Azure: $_" -Level "ERROR"
        Write-Host ""
        Write-Host "  If you're having trouble, try running:" -ForegroundColor White
        Write-Host "    Connect-AzAccount" -ForegroundColor Green
        Write-Host ""
        exit 1
    }
}
else {
    Write-Log "Already connected to Azure as: $($context.Account.Id)" -Level "SUCCESS"
}

# Determine which subscriptions to process
$subscriptionsToProcess = @()
$originalSubscriptionId = $context.Subscription.Id

if ($AllSubscriptions) {
    Write-Log "Retrieving all accessible subscriptions..." -Level "INFO"
    $allSubs = Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' }
    $subscriptionsToProcess = $allSubs | ForEach-Object { 
        @{ Id = $_.Id; Name = $_.Name }
    }
    Write-Log "Found $($subscriptionsToProcess.Count) accessible subscription(s)" -Level "SUCCESS"
}
elseif ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    Write-Log "Processing $($SubscriptionIds.Count) specified subscription(s)..." -Level "INFO"
    foreach ($subId in $SubscriptionIds) {
        try {
            $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
            $subscriptionsToProcess += @{ Id = $sub.Id; Name = $sub.Name }
        }
        catch {
            Write-Log "Could not access subscription '$subId': $_" -Level "WARNING"
        }
    }
}
elseif ($SubscriptionId) {
    Write-Log "Setting subscription to: $SubscriptionId" -Level "INFO"
    try {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        $context = Get-AzContext
        $subscriptionsToProcess += @{ Id = $context.Subscription.Id; Name = $context.Subscription.Name }
    }
    catch {
        Write-Log "Could not set subscription '$SubscriptionId': $_" -Level "ERROR"
        exit 1
    }
}
else {
    # Use current context
    $subscriptionsToProcess += @{ Id = $context.Subscription.Id; Name = $context.Subscription.Name }
}

if ($subscriptionsToProcess.Count -eq 0) {
    Write-Log "No accessible subscriptions found." -Level "ERROR"
    exit 1
}

Write-Log "Will process $($subscriptionsToProcess.Count) subscription(s)" -Level "INFO"

# Check RBAC permissions for Cost Management access
Write-Log "Verifying Cost Management permissions..." -Level "INFO"

$hasCostAccess = $false
$testSubscription = $subscriptionsToProcess[0]

try {
    Set-AzContext -SubscriptionId $testSubscription.Id -ErrorAction Stop | Out-Null
    
    # Try a simple cost query to test permissions
    $testScope = "/subscriptions/$($testSubscription.Id)"
    $testDate = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
    
    $testQuery = Invoke-AzCostManagementQuery -Scope $testScope -Type "ActualCost" `
        -Timeframe "Custom" `
        -TimePeriodFrom $testDate `
        -TimePeriodTo $testDate `
        -DatasetGranularity "None" `
        -DatasetAggregation @{
            "TotalCost" = @{
                "name" = "Cost"
                "function" = "Sum"
            }
        } -ErrorAction Stop
    
    $hasCostAccess = $true
    Write-Log "Cost Management permissions verified." -Level "SUCCESS"
}
catch {
    $errorMessage = $_.Exception.Message
    
    if ($errorMessage -match "403|Forbidden|AuthorizationFailed|does not have authorization") {
        Write-Log "Insufficient permissions to access Cost Management data." -Level "ERROR"
        Write-Host ""
        Write-Host "=" * 80 -ForegroundColor Red
        Write-Host "  ACCESS DENIED - Cost Management Permissions Required" -ForegroundColor Red
        Write-Host "=" * 80 -ForegroundColor Red
        Write-Host ""
        Write-Host "  You do not have the required permissions to view cost data." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Required RBAC Roles (one of the following):" -ForegroundColor White
        Write-Host "    - Cost Management Reader" -ForegroundColor Cyan
        Write-Host "    - Cost Management Contributor" -ForegroundColor Cyan
        Write-Host "    - Billing Reader" -ForegroundColor Cyan
        Write-Host "    - Reader (at subscription scope)" -ForegroundColor Cyan
        Write-Host "    - Contributor" -ForegroundColor Cyan
        Write-Host "    - Owner" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  To assign the Cost Management Reader role, an admin can run:" -ForegroundColor White
        Write-Host ""
        Write-Host "    New-AzRoleAssignment ``" -ForegroundColor Green
        Write-Host "      -SignInName `"your-email@domain.com`" ``" -ForegroundColor Green
        Write-Host "      -RoleDefinitionName `"Cost Management Reader`" ``" -ForegroundColor Green
        Write-Host "      -Scope `"/subscriptions/$($testSubscription.Id)`"" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Or assign via Azure Portal:" -ForegroundColor White
        Write-Host "    1. Go to the Subscription -> Access control (IAM)" -ForegroundColor Gray
        Write-Host "    2. Click 'Add role assignment'" -ForegroundColor Gray
        Write-Host "    3. Select 'Cost Management Reader' role" -ForegroundColor Gray
        Write-Host "    4. Assign to your user/group" -ForegroundColor Gray
        Write-Host ""
        Write-Host "=" * 80 -ForegroundColor Red
        
        # Restore original context
        Set-AzContext -SubscriptionId $originalSubscriptionId -ErrorAction SilentlyContinue | Out-Null
        exit 1
    }
    else {
        # Other error - might still work, continue with warning
        Write-Log "Could not verify cost permissions (non-auth error): $errorMessage" -Level "WARNING"
        Write-Log "Continuing - cost data retrieval will be attempted..." -Level "INFO"
        $hasCostAccess = $true  # Assume true, let it fail later if needed
    }
}

# Calculate date range
$endDate = Get-Date
$startDate = $endDate.AddDays(-$Days)
$startDateStr = $startDate.ToString("yyyy-MM-dd")
$endDateStr = $endDate.ToString("yyyy-MM-dd")

Write-Log "Date range: $startDateStr to $endDateStr" -Level "INFO"

# Collect NAT Gateway and Public IP resource IDs across all subscriptions
$natGatewayResourceIds = @()
$publicIpResourceIds = @()
$natGatewayDetails = @()
$consumptionData = @()

foreach ($subscription in $subscriptionsToProcess) {
    Write-Log "Processing subscription: $($subscription.Name) ($($subscription.Id))" -Level "INFO"
    
    # Switch to this subscription
    try {
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Could not switch to subscription '$($subscription.Name)': $_" -Level "WARNING"
        continue
    }
    
    # Get NAT Gateways in this subscription
    $natGatewayParams = @{}
    if ($ResourceGroupName) {
        $natGatewayParams.ResourceGroupName = $ResourceGroupName
    }

    $natGateways = Get-AzNatGateway @natGatewayParams -ErrorAction SilentlyContinue

    if (-not $natGateways -or $natGateways.Count -eq 0) {
        Write-Log "  No NAT Gateways found in this subscription." -Level "INFO"
        continue
    }

    Write-Log "  Found $($natGateways.Count) NAT Gateway(s)" -Level "SUCCESS"

    foreach ($natGw in $natGateways) {
        Write-Log "  Processing NAT Gateway: $($natGw.Name)" -Level "INFO"
        
        $natGatewayResourceIds += $natGw.Id
        
        $natGwInfo = @{
            Name = $natGw.Name
            ResourceGroup = $natGw.ResourceGroupName
            Location = $natGw.Location
            ResourceId = $natGw.Id
            SubscriptionId = $subscription.Id
            SubscriptionName = $subscription.Name
            PublicIpAddresses = @()
            PublicIpPrefixes = @()
            SkuName = $natGw.Sku.Name
            IdleTimeoutInMinutes = $natGw.IdleTimeoutInMinutes
        }

        # Get associated Public IP addresses
        if ($natGw.PublicIpAddresses) {
            foreach ($pip in $natGw.PublicIpAddresses) {
                $publicIpResourceIds += $pip.Id
                
                # Get Public IP details
                try {
                    $pipResource = Get-AzResource -ResourceId $pip.Id -ErrorAction SilentlyContinue
                    if ($pipResource) {
                        $pipDetails = Get-AzPublicIpAddress -Name $pipResource.Name -ResourceGroupName $pipResource.ResourceGroupName -ErrorAction SilentlyContinue
                        $natGwInfo.PublicIpAddresses += @{
                            Name = $pipResource.Name
                            ResourceId = $pip.Id
                            IpAddress = $pipDetails.IpAddress
                            Sku = $pipDetails.Sku.Name
                        }
                    }
                }
                catch {
                    $natGwInfo.PublicIpAddresses += @{
                        Name = ($pip.Id -split '/')[-1]
                        ResourceId = $pip.Id
                        IpAddress = "Unknown"
                        Sku = "Unknown"
                    }
                }
            }
        }

        # Get associated Public IP Prefixes
        if ($natGw.PublicIpPrefixes) {
            foreach ($prefix in $natGw.PublicIpPrefixes) {
                $publicIpResourceIds += $prefix.Id
                $natGwInfo.PublicIpPrefixes += @{
                    Name = ($prefix.Id -split '/')[-1]
                    ResourceId = $prefix.Id
                }
            }
        }

        $natGatewayDetails += $natGwInfo
    }
}

# Check if we found any NAT Gateways
if ($natGatewayDetails.Count -eq 0) {
    Write-Log "No NAT Gateways found across all processed subscriptions." -Level "WARNING"
    Set-AzContext -SubscriptionId $originalSubscriptionId -ErrorAction SilentlyContinue | Out-Null
    exit 0
}

Write-Log "Found $($natGatewayDetails.Count) NAT Gateway(s) across all subscriptions" -Level "SUCCESS"

# Debug output - show what NAT Gateway resource IDs we're looking for
Write-Log "NAT Gateways being tracked:" -Level "INFO"
foreach ($natGwId in $natGatewayResourceIds) {
    Write-Log "  - $natGwId" -Level "INFO"
}
if ($publicIpResourceIds.Count -gt 0) {
    Write-Log "Public IPs/Prefixes being tracked:" -Level "INFO"
    foreach ($pipId in $publicIpResourceIds) {
        Write-Log "  - $pipId" -Level "INFO"
    }
}

# Now collect cost data for all subscriptions (after we have all resource IDs)
Write-Log "Retrieving cost data from all subscriptions..." -Level "INFO"

foreach ($subscription in $subscriptionsToProcess) {
    Write-Log "  Getting costs for subscription: $($subscription.Name)" -Level "INFO"
    
    # Switch to this subscription
    try {
        Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "  Could not switch to subscription: $_" -Level "WARNING"
        continue
    }
    
    $subscriptionCostFound = $false
    
    # Method 1: Try Consumption Usage Details API
    try {
        # Use string format for dates as some versions of the API prefer this
        $usageDetails = Get-AzConsumptionUsageDetail -StartDate $startDate.ToString("yyyy-MM-dd") -EndDate $endDate.ToString("yyyy-MM-dd") -ErrorAction Stop
        
        if ($usageDetails) {
            Write-Log "  Retrieved $($usageDetails.Count) consumption records" -Level "INFO"
            $subscriptionCostFound = $true
            
            # Filter for NAT Gateway resources by InstanceId (Resource ID)
            foreach ($usage in $usageDetails) {
                $instanceId = $usage.InstanceId
                if (-not $instanceId) { continue }
                
                $instanceIdLower = $instanceId.ToLower()
                
                # Check if this is a NAT Gateway (by ID match or by resource type pattern)
                $isNatGw = $natGatewayResourceIds | Where-Object { $instanceIdLower -eq $_.ToLower() }
                if (-not $isNatGw) {
                    # Check by resource type pattern - include all NAT Gateways found in this subscription
                    if ($instanceId -match "/Microsoft\.Network/natGateways/") {
                        $isNatGw = $true
                    }
                }
                
                # Check if this is a Public IP or Public IP Prefix attached to a NAT Gateway  
                $isPip = $publicIpResourceIds | Where-Object { $instanceIdLower -eq $_.ToLower() }
                
                $isPrefix = $instanceId -match "/Microsoft\.Network/publicIPPrefixes/"
                
                if ($isNatGw -or $isPip) {
                    $resourceType = if ($isNatGw) { 
                        "NatGateway" 
                    } elseif ($isPrefix) { 
                        "PublicIPPrefix" 
                    } else { 
                        "PublicIP" 
                    }
                    
                    $consumptionData += [PSCustomObject]@{
                        ResourceId = $instanceId
                        ResourceName = ($instanceId -split '/')[-1]
                        ResourceGroup = ($instanceId -split '/')[4]
                        SubscriptionId = $subscription.Id
                        SubscriptionName = $subscription.Name
                        MeterCategory = $usage.MeterCategory
                        MeterSubCategory = $usage.MeterSubCategory
                        MeterName = $usage.MeterName
                        Cost = $usage.PretaxCost
                        Currency = $usage.Currency
                        IsNatGateway = [bool]$isNatGw
                        IsPublicIP = [bool]$isPip
                        IsPublicIPPrefix = [bool]$isPrefix
                        ResourceType = $resourceType
                        UsageQuantity = $usage.UsageQuantity
                        UnitOfMeasure = $usage.UnitOfMeasure
                    }
                }
            }
        }
    }
    catch {
        # Consumption API not available - will try Cost Management API instead
        Write-Log "  Consumption API not available, trying alternative..." -Level "INFO"
    }
    
    # Method 2: If Consumption API failed, try Cost Management Query API
    if (-not $subscriptionCostFound) {
        Write-Log "  Using Cost Management Query API..." -Level "INFO"
        
        $scope = "/subscriptions/$($subscription.Id)"
        
        try {
            $networkCosts = Invoke-AzCostManagementQuery -Scope $scope -Type "ActualCost" `
                -Timeframe "Custom" `
                -TimePeriodFrom $startDateStr `
                -TimePeriodTo $endDateStr `
                -DatasetGranularity "None" `
                -DatasetAggregation @{
                    "TotalCost" = @{
                        "name" = "Cost"
                        "function" = "Sum"
                    }
                } `
                -DatasetGrouping @(
                    @{
                        "type" = "Dimension"
                        "name" = "ResourceId"
                    },
                    @{
                        "type" = "Dimension"
                        "name" = "ResourceType"
                    },
                    @{
                        "type" = "Dimension"
                        "name" = "MeterCategory"
                    }
                ) -ErrorAction Stop
            
            if ($networkCosts -and $networkCosts.Row) {
                Write-Log "  Cost Management returned $($networkCosts.Row.Count) records" -Level "INFO"
                
                foreach ($row in $networkCosts.Row) {
                    $cost = $row[0]
                    $resourceId = $row[1]
                    $resourceType = $row[2]
                    $meterCategory = $row[3]
                    
                    # Filter for NAT Gateways, Public IPs, and Public IP Prefixes
                    if ($resourceType -match "natGateways" -or $resourceType -match "publicIPAddresses" -or $resourceType -match "publicIPPrefixes") {
                        $resourceIdLower = $resourceId.ToLower()
                        
                        $isNatGw = $natGatewayResourceIds | Where-Object { $resourceIdLower -eq $_.ToLower() }
                        if (-not $isNatGw) {
                            $isNatGw = $resourceId -match "/Microsoft\.Network/natGateways/"
                        }
                        
                        $isPip = $publicIpResourceIds | Where-Object { $resourceIdLower -eq $_.ToLower() }
                        $isPrefix = $resourceId -match "/Microsoft\.Network/publicIPPrefixes/"
                        
                        if ($isNatGw -or $isPip) {
                            $displayType = if ($isNatGw) { 
                                "NatGateway" 
                            } elseif ($isPrefix) { 
                                "PublicIPPrefix" 
                            } else { 
                                "PublicIP" 
                            }
                            
                            $consumptionData += [PSCustomObject]@{
                                ResourceId = $resourceId
                                ResourceName = ($resourceId -split '/')[-1]
                                ResourceGroup = ($resourceId -split '/')[4]
                                SubscriptionId = $subscription.Id
                                SubscriptionName = $subscription.Name
                                MeterCategory = $meterCategory
                                MeterSubCategory = ""
                                MeterName = ""
                                Cost = $cost
                                Currency = "USD"
                                IsNatGateway = [bool]$isNatGw
                                IsPublicIP = [bool]$isPip
                                IsPublicIPPrefix = [bool]$isPrefix
                                ResourceType = $displayType
                                UsageQuantity = 0
                                UnitOfMeasure = ""
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "  Cost Management Query error: $_" -Level "WARNING"
        }
    }
}

Write-Log "Found $($consumptionData.Count) cost records" -Level "INFO"

# Get NAT Gateway metrics (data processed) - need to switch context for each
Write-Log "Retrieving NAT Gateway metrics (data processed)..." -Level "INFO"

$natGatewayMetrics = @()

foreach ($natGwDetail in $natGatewayDetails) {
    # Switch to the correct subscription for this NAT Gateway
    if ($natGwDetail.SubscriptionId) {
        Set-AzContext -SubscriptionId $natGwDetail.SubscriptionId -ErrorAction SilentlyContinue | Out-Null
    }
    
    Write-Log "Getting metrics for NAT Gateway: $($natGwDetail.Name)" -Level "INFO"
    
    $metrics = Get-NATGatewayBytesMetrics -ResourceId $natGwDetail.ResourceId `
        -StartTime $startDate `
        -EndTime $endDate
    
    $natGatewayMetrics += @{
        Name = $natGwDetail.Name
        ResourceGroup = $natGwDetail.ResourceGroup
        SubscriptionName = $natGwDetail.SubscriptionName
        TotalDataProcessedGB = $metrics.TotalBytesGB
        InboundDataGB = $metrics.InboundBytesGB
        OutboundDataGB = $metrics.OutboundBytesGB
        SNATConnectionCount = $metrics.SNATConnectionCount
        DroppedPackets = $metrics.DroppedPackets
    }
}

# Restore original subscription context
Set-AzContext -SubscriptionId $originalSubscriptionId -ErrorAction SilentlyContinue | Out-Null

# Process and display results
Write-Host "`n" -NoNewline
Write-Host "=" * 100 -ForegroundColor Cyan
Write-Host "                    NAT GATEWAY COST AND USAGE REPORT" -ForegroundColor Cyan
Write-Host "                    Period: $startDateStr to $endDateStr" -ForegroundColor Cyan
Write-Host "=" * 100 -ForegroundColor Cyan
Write-Host "`n"

# Display NAT Gateway Details
Write-Host "NAT GATEWAY INVENTORY" -ForegroundColor Yellow
Write-Host "-" * 50 -ForegroundColor Yellow

foreach ($natGwDetail in $natGatewayDetails) {
    Write-Host "`n  NAT Gateway: " -NoNewline -ForegroundColor White
    Write-Host $natGwDetail.Name -ForegroundColor Green
    Write-Host "    Subscription: $($natGwDetail.SubscriptionName)"
    Write-Host "    Resource Group: $($natGwDetail.ResourceGroup)"
    Write-Host "    Location: $($natGwDetail.Location)"
    Write-Host "    SKU: $($natGwDetail.SkuName)"
    Write-Host "    Idle Timeout: $($natGwDetail.IdleTimeoutInMinutes) minutes"
    
    if ($natGwDetail.PublicIpAddresses.Count -gt 0) {
        Write-Host "    Associated Public IPs:" -ForegroundColor Cyan
        foreach ($pip in $natGwDetail.PublicIpAddresses) {
            Write-Host "      - $($pip.Name) ($($pip.IpAddress)) [SKU: $($pip.Sku)]"
        }
    }
    
    if ($natGwDetail.PublicIpPrefixes.Count -gt 0) {
        Write-Host "    Associated Public IP Prefixes:" -ForegroundColor Cyan
        foreach ($prefix in $natGwDetail.PublicIpPrefixes) {
            Write-Host "      - $($prefix.Name)"
        }
    }
}

# Display Metrics
Write-Host "`n" -NoNewline
Write-Host "NAT GATEWAY DATA TRANSFER METRICS" -ForegroundColor Yellow
Write-Host "-" * 50 -ForegroundColor Yellow

$metricsTable = $natGatewayMetrics | ForEach-Object {
    [PSCustomObject]@{
        "NAT Gateway"         = $_.Name
        "Subscription"        = $_.SubscriptionName
        "Resource Group"      = $_.ResourceGroup
        "Inbound (GB)"        = $_.InboundDataGB
        "Outbound (GB)"       = $_.OutboundDataGB
        "Total (GB)"          = $_.TotalDataProcessedGB
        "SNAT Connections"    = $_.SNATConnectionCount
        "Dropped Packets"     = $_.DroppedPackets
    }
}

$metricsTable | Format-Table -AutoSize

# Display Cost Summary
Write-Host "`n" -NoNewline
Write-Host "COST SUMMARY" -ForegroundColor Yellow
Write-Host "-" * 50 -ForegroundColor Yellow

$costResults = @()

# Process the consumption data we collected earlier
if ($consumptionData -and $consumptionData.Count -gt 0) {
    Write-Log "Processing $($consumptionData.Count) cost records..." -Level "INFO"
    
    foreach ($item in $consumptionData) {
        # Determine display resource type
        $displayType = if ($item.IsNatGateway) { 
            "NAT Gateway" 
        } elseif ($item.IsPublicIPPrefix) { 
            "Public IP Prefix (NAT GW)" 
        } else { 
            "Public IP (NAT GW)" 
        }
        
        $costResults += [PSCustomObject]@{
            ResourceType = $displayType
            ResourceName = $item.ResourceName
            SubscriptionName = $item.SubscriptionName
            ResourceGroup = $item.ResourceGroup
            MeterCategory = $item.MeterCategory
            MeterSubCategory = $item.MeterSubCategory
            MeterName = $item.MeterName
            Cost = [math]::Round($item.Cost, 4)
            Currency = $item.Currency
            UsageQuantity = $item.UsageQuantity
            UnitOfMeasure = $item.UnitOfMeasure
        }
    }
}

# Aggregate costs by resource (in case there are multiple line items per resource)
if ($costResults.Count -gt 0) {
    $aggregatedCosts = $costResults | Group-Object -Property ResourceName, ResourceType, SubscriptionName | ForEach-Object {
        $first = $_.Group[0]
        [PSCustomObject]@{
            ResourceType = $first.ResourceType
            ResourceName = $first.ResourceName
            SubscriptionName = $first.SubscriptionName
            ResourceGroup = $first.ResourceGroup
            MeterCategory = ($_.Group.MeterCategory | Select-Object -Unique) -join ", "
            MeterSubCategory = ($_.Group.MeterSubCategory | Where-Object { $_ } | Select-Object -Unique) -join ", "
            Cost = [math]::Round(($_.Group | Measure-Object -Property Cost -Sum).Sum, 2)
            Currency = $first.Currency
        }
    }
    
    $costResults = @($aggregatedCosts)
}

if ($costResults -and $costResults.Count -gt 0) {
    $costResults | Format-Table -AutoSize
    
    # Calculate totals
    $totalNatGwCost = ($costResults | Where-Object { $_.ResourceType -eq "NAT Gateway" } | Measure-Object -Property Cost -Sum).Sum
    $totalPipCost = ($costResults | Where-Object { $_.ResourceType -eq "Public IP (NAT GW)" } | Measure-Object -Property Cost -Sum).Sum
    $totalPrefixCost = ($costResults | Where-Object { $_.ResourceType -eq "Public IP Prefix (NAT GW)" } | Measure-Object -Property Cost -Sum).Sum
    $grandTotal = ($costResults | Measure-Object -Property Cost -Sum).Sum
    
    if ($null -eq $totalNatGwCost) { $totalNatGwCost = 0 }
    if ($null -eq $totalPipCost) { $totalPipCost = 0 }
    if ($null -eq $totalPrefixCost) { $totalPrefixCost = 0 }
    if ($null -eq $grandTotal) { $grandTotal = 0 }
    
    Write-Host "`n" -NoNewline
    Write-Host "COST TOTALS" -ForegroundColor Yellow
    Write-Host "-" * 50 -ForegroundColor Yellow
    Write-Host "  NAT Gateway Costs:         `$$([math]::Round($totalNatGwCost, 2))" -ForegroundColor White
    Write-Host "  Public IP Costs:           `$$([math]::Round($totalPipCost, 2))" -ForegroundColor White
    Write-Host "  Public IP Prefix Costs:    `$$([math]::Round($totalPrefixCost, 2))" -ForegroundColor White
    Write-Host "  --------------------------"
    Write-Host "  GRAND TOTAL:               `$$([math]::Round($grandTotal, 2))" -ForegroundColor Green
}
else {
    Write-Log "No cost data found for the specified NAT Gateways and Public IPs." -Level "WARNING"
    Write-Log "This could mean:" -Level "INFO"
    Write-Log "  - No costs were incurred during this period" -Level "INFO"
    Write-Log "  - Cost data is not yet available (can take 24-72 hours)" -Level "INFO"
    Write-Log "  - You may not have Cost Management Reader permissions" -Level "INFO"
    Write-Log "  - The NAT Gateway resource IDs don't match the billing records" -Level "INFO"
}

# Export results to CSV if there's data
$exportPath = Join-Path -Path $PSScriptRoot -ChildPath "NATGateway_CostReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

$exportData = @()

foreach ($natGwDetail in $natGatewayDetails) {
    $metrics = $natGatewayMetrics | Where-Object { $_.Name -eq $natGwDetail.Name }
    $costs = $costResults | Where-Object { $_.ResourceName -eq $natGwDetail.Name }
    
    $natGwCost = if ($costs) { ($costs | Measure-Object -Property Cost -Sum).Sum } else { 0 }
    
    # Get associated Public IP costs
    $pipCostTotal = 0
    foreach ($pip in $natGwDetail.PublicIpAddresses) {
        $pipCost = $costResults | Where-Object { $_.ResourceName -eq $pip.Name -and $_.ResourceType -eq "Public IP (NAT GW)" }
        if ($pipCost) {
            $pipCostTotal += ($pipCost | Measure-Object -Property Cost -Sum).Sum
        }
    }
    
    # Get associated Public IP Prefix costs
    $prefixCostTotal = 0
    foreach ($prefix in $natGwDetail.PublicIpPrefixes) {
        $prefixCost = $costResults | Where-Object { $_.ResourceName -eq $prefix.Name -and $_.ResourceType -eq "Public IP Prefix (NAT GW)" }
        if ($prefixCost) {
            $prefixCostTotal += ($prefixCost | Measure-Object -Property Cost -Sum).Sum
        }
    }
    
    $exportData += [PSCustomObject]@{
        NATGatewayName = $natGwDetail.Name
        SubscriptionName = $natGwDetail.SubscriptionName
        SubscriptionId = $natGwDetail.SubscriptionId
        ResourceGroup = $natGwDetail.ResourceGroup
        Location = $natGwDetail.Location
        SKU = $natGwDetail.SkuName
        AssociatedPublicIPs = ($natGwDetail.PublicIpAddresses | ForEach-Object { $_.Name }) -join "; "
        AssociatedPublicIPPrefixes = ($natGwDetail.PublicIpPrefixes | ForEach-Object { $_.Name }) -join "; "
        InboundDataGB = $metrics.InboundDataGB
        OutboundDataGB = $metrics.OutboundDataGB
        TotalDataProcessedGB = $metrics.TotalDataProcessedGB
        SNATConnections = $metrics.SNATConnectionCount
        DroppedPackets = $metrics.DroppedPackets
        NATGatewayCostUSD = [math]::Round($natGwCost, 2)
        PublicIPCostUSD = [math]::Round($pipCostTotal, 2)
        PublicIPPrefixCostUSD = [math]::Round($prefixCostTotal, 2)
        TotalCostUSD = [math]::Round($natGwCost + $pipCostTotal + $prefixCostTotal, 2)
        ReportStartDate = $startDateStr
        ReportEndDate = $endDateStr
    }
}

if ($exportData.Count -gt 0) {
    $exportData | Export-Csv -Path $exportPath -NoTypeInformation
    Write-Host "`n"
    Write-Log "Report exported to: $exportPath" -Level "SUCCESS"
}

Write-Host "`n" -NoNewline
Write-Host "=" * 100 -ForegroundColor Cyan
Write-Host "                              END OF REPORT" -ForegroundColor Cyan
Write-Host "=" * 100 -ForegroundColor Cyan

#endregion Main Script
