
<#
    .DESCRIPTION
        This script will query all Log Analytics workspaces in all subscriptions and find computers that are using MMA agents. 
        It will also check if the workspace has WindowsEvent, CustomLog, LinuxPerformanceObject, LinuxSyslog, WindowsPerformanceCounter configured.
        The script will output a CSV file with the following columns:
        WorkspaceName, ResourceGroupName, Subscription, SubscriptionId, WindowsEventConfigured, CustomLogConfigured, LinuxPerfConfigured, LinuxSyslogConfigured, WinPerfConfigured, MMACount, MMAComputers

    .INPUTS 
        None      

    .NOTES 
        - Requires the Az.OperationalInsights PS module
        - You must already be logged into Azure through Connect-AzAccount and have the 
            appropriate permissionsbefore running this script.

#>


# configure static variables

$wsReport = @()
$totalMMACount = 0

# get all subscriptions

$subcriptions = Get-AzSubscription

#Cycle through each subscription

foreach ($subscription in $subcriptions) {

    Set-AzContext -Subscription $subscription.Id

    $workspaces = Get-AzOperationalInsightsWorkspace

    # Cycle through all Log Analytics workspaces and find computers that are using MMA agents and also get the Legacy Agents Management settings for that workspace

    foreach ($workspace in $workspaces) {

        if ($workspace) {

            # Check if the workspace has WindowsEvent configured

            if (Get-AzOperationalInsightsDataSource -WorkspaceName $workspace.Name -ResourceGroupName $workspace.ResourceGroupName -Kind WindowsEvent) {

                $WindowsEventConfigured = $true

            }
            else {
                $WindowsEventConfigured = $false
            }

            # Check if the workspace has CustomLog configured
            if (Get-AzOperationalInsightsDataSource -WorkspaceName $workspace.Name -ResourceGroupName $workspace.ResourceGroupName -Kind CustomLog) {

                $CustomLogConfigured = $true

            }
            else {
                $CustomLogConfigured = $false
            }

            # Check if the workspace has LinuxPerformanceObject configured
            if (Get-AzOperationalInsightsDataSource -WorkspaceName $workspace.Name -ResourceGroupName $workspace.ResourceGroupName -Kind LinuxPerformanceObject) {

                $LinuxPerfConfigured = $true

            }
            else {
                $LinuxPerfConfigured = $false
            }

            # Check if the workspace has LinuxSyslog configured
            if (Get-AzOperationalInsightsDataSource -WorkspaceName $workspace.Name -ResourceGroupName $workspace.ResourceGroupName -Kind LinuxSyslog
            ) {

                $LinuxSyslogConfigured = $true

            }
            else {
                $LinuxSyslogConfigured = $false
            }

            # Check if the workspace has WindowsPerformanceCounter configured
            if (Get-AzOperationalInsightsDataSource -WorkspaceName $workspace.Name -ResourceGroupName $workspace.ResourceGroupName -Kind WindowsPerformanceCounter
            ) {

                $WinPerfConfigured = $true

            }
            else {
                $WinPerfConfigured = $false
            }

            # Check if any VMs are using MMA agents in this workspace
            $query = 'Heartbeat | where Category contains "Direct Agent" | distinct Computer'
            $queryResults = (Invoke-AzOperationalInsightsQuery -WorkspaceId $workspace.CustomerId -Query $query).Results
            $MMACount = $queryResults.Comnputer.Count
            $MMAComputers = $queryResults.Computer -join ", "
            
            if ($mmacount -gt 0) {
                write-host "Workspace Name: " $workspace.Name
                $totalMMACount += $MMACount
                $wsReport += [PSCustomObject]@{
                    WorkspaceName          = ($workspace.Name.ToString())
                    ResourceGroupName      = ($workspace.ResourceGroupName.ToString())
                    Subscription           = ($subscription.Name.ToString())
                    SubscriptionId         = ($subscription.Id.ToString())
                    WindowsEventConfigured = $WindowsEventConfigured
                    CustomLogConfigured    = $CustomLogConfigured
                    LinuxPerfConfigured    = $LinuxPerfConfigured
                    LinuxSyslogConfigured  = $LinuxSyslogConfigured
                    WinPerfConfigured      = $WinPerfConfigured
                    MMACount               = $MMACount
                    MMAComputers           = $MMAComputers

                }

            }
        }
    }
}

$wsReport | Export-Csv -Path "C:\temp\MMACount.csv" -NoTypeInformation -force 
$totalMMACount
