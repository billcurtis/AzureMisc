
<#
    .DESCRIPTION
       This example script gets all the ports (inbound and outbound) from a Log Analytics workspace
        connected machine (that has the dependency agent installed) and then exports the data to a CSV file.

    .INPUTS
        VMname = Virtual Machine name of Azure VM or Azure Arc VM that we will be querying. 
        WorkSpaceID = Workspace ID of the log analytics workspace where the map data resides.
        csvPath = Path to save the CSV file.

    .EXAMPLE
       

    .NOTES
    
        - Requires the Az.OperationalInsights PS module
        - You must already be logged into Azure through Connect-AzAccount and have the 
            appropriate permissionsbefore running this script. 

#>



# Input Strings
$VMName = 'dnsproxy'
$WorkspaceId = '2ad97d61-b73e-4e32-9bb1-e2f0b25b044f'
$csvPath = "M:\temp\"
 
# This is where you would log on using a Service Principal if automating this.

# Import modules
$VerbosePreference = 'SilentlyContinue'
Import-Module Az.OperationalInsights
$VerbosePreference = 'Continue'

# To fix formatting issues in query string
$left = '$left'
$right = '$right'


# Le Query
$laQuery = @"
let compName = '$VMName';
let machineID = ServiceMapComputer_CL |
where Computer == compName |
project ResourceName_s | limit 1;
let machines = machineID;
let ips=materialize(ServiceMapComputer_CL
| summarize ips=makeset(todynamic(Ipv4Addresses_s)) by MonitoredMachine=ResourceName_s
| mvexpand ips to typeof(string));
let out=materialize(VMConnection
| where Machine in (machines)
| summarize arg_max(TimeGenerated, *) by ConnectionId);
let local=out
| where RemoteIp startswith '127.'
| project ConnectionId, Direction, Computer, Process, ProcessName, SourceIp, DestinationIp, DestinationPort, Protocol, RemoteIp, RemoteMachine=Machine;
let remote=materialize(out
| where RemoteIp !startswith '127.'
| join kind=leftouter (ips) on $left.RemoteIp == $right.ips
| summarize by ConnectionId, Direction, Machine, Process, ProcessName, SourceIp, DestinationIp, DestinationPort, Protocol, RemoteIp, RemoteMachine=MonitoredMachine);
let remoteMachines = remote | summarize by RemoteMachine;
(local)
| union (remote)
| where Direction == 'outbound' or (Direction == 'inbound' and RemoteMachine !in (machines))
| summarize by compName, Direction, Machine, Process, ProcessName, SourceIp, DestinationIp, DestinationPort, Protocol, RemoteIp, RemoteMachine
| extend RemotePort=iff(Direction == 'outbound', DestinationPort, 0)
| extend JoinKey=strcat_delim(':', RemoteMachine, RemoteIp, RemotePort, Protocol)
| join kind=leftouter (VMBoundPort 
| where Machine in (remoteMachines) 
| summarize arg_max(TimeGenerated, *) by PortId 
| extend JoinKey=strcat_delim(':', Machine, Ip, Port, Protocol)) on JoinKey
| summarize by compName, Direction, ProcessName, SourceIp, DestinationIp, DestinationPort, Protocol
"@

# Perform the query 
Write-Verbose -Message 'Performing Query'
$Results = Invoke-AzOperationalInsightsQuery -Query $laQuery -WorkspaceId $WorkspaceId

# Export results
Write-Verbose -Message "Exporting results to $csvPath$VMName-portusage.csv"
$Results.Results | Sort-Object -Property Direction | `
    Export-Csv -Path "$csvPath$VMName-portusage.csv" -NoTypeInformation -NoClobber -Force 
