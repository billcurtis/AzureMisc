<#
    .DESCRIPTION
      Scans through selected subscriptions and returns usage data on an hourly or daily basis
        in a CSV Report.

    .INPUTS
        FromTime   = Date on which to start.
        EndTime    = Date on which to end.
        Interval   = Hour or Daily
        ReportPath = Path to take for report

    .EXAMPLE
        .\Get-AzBilling.ps1 -FromTime 3/7/2023 -ToTime 3/8/2023 -Reportpath C:\temp\report05.csv

    .NOTES
    
        - User needs Azure permissions to read the billing information on each subscription selected.
#>




[CmdletBinding()]
param(

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [datetime]$FromTime,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [datetime]$ToTime,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('Hourly', 'Daily')]
    [string]$Interval = 'Daily',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Reportpath
)



# Set Preferences
$VerbosePreference = 'Continue'
$ErrorActionPreference = 'Stop'


function Get-AzureUsage {

# using function from https://adamtheautomator.com/azure-detailed-usage-report/


    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [datetime]$FromTime,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [datetime]$ToTime,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('Hourly', 'Daily')]
        [string]$Interval = 'Daily'
    )

    Write-Verbose -Message "Querying usage data [$($FromTime) - $($ToTime)]..."
    $usageData = $null
    do {    
        $params = @{
            ReportedStartTime      = $FromTime
            ReportedEndTime        = $ToTime
            AggregationGranularity = $Interval
            ShowDetails            = $true
        }
        if ((Get-Variable -Name usageData -ErrorAction Ignore) -and $usageData) {
            Write-Verbose -Message "Querying usage data with continuation token $($usageData.ContinuationToken)..."
            $params.ContinuationToken = $usageData.ContinuationToken
        }
        $usageData = Get-UsageAggregates @params
        $usageData.UsageAggregations | Select-Object -ExpandProperty Properties
    } while ('ContinuationToken' -in $usageData.psobject.properties.name -and $usageData.ContinuationToken)
}


# Connect to Azure Account
Connect-AzAccount

#declare variables
$report = @()

# Select Subscriptions to Scan
$azSubscriptions = Get-AzSubscription
$azSubscriptionsToScan = $azSubscriptions | Out-GridView -Title "Please select the subscriptions to obtain usage data from." -OutputMode Multiple 

if (!$azSubscriptionsToScan) { Write-Error "No subscriptions selected." }

foreach ($azSubscription in $azSubscriptionsToScan) {

Set-AzContext -SubscriptionId $azSubscription.Id

# Get Usage Data
$usagedata = Get-AzureUsage -FromTime $FromTime -ToTime $ToTime -Interval Hourly -Verbose


foreach ($usageResource in $usagedata) {



    $report += [PSCustomObject]@{

        UsageStartTime    = $usageResource.UsageStartTime
        UsageEndTime      = $usageResource.UsageEndTime
        SubscriptionID    = (($usageResource.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri).split("/")[2]
        SubscriptionName  = (Get-AzContext).Name.Split('(')[0]
        ResourceGroupName = (($usageResource.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri).split("/")[4]
        ResourceName      = (($usageResource.InstanceData | ConvertFrom-Json).'Microsoft.Resources'.resourceUri).split("/")[8]
        MeterRegion       = $usageResource.MeterRegion
        MeterCategory     = $usageResource.MeterCategory
        MeterSubCategory  = $usageResource.MeterSubCategory
        Quantity          = $usageResource.Quantity
        Unit              = $usageResource.Unit

    }

}


}

$report | Export-Csv -Path $Reportpath -NoClobber -NoTypeInformation -Force 
Write-Output "Report Path = $Reportpath"


