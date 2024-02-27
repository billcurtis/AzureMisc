<#

The following query returns a list of update installations for Windows Server with their 
 status for your machines from the last seven days. Results include the time when the update 
 deployment was run, the resource ID of the installation, machine details, and other related 
 deployment details.

#>




$rsQuery = @'
patchinstallationresources
| where type has "softwarepatches" and properties !has "version"
| extend machineName = tostring(split(id, "/", 8)), resourceType = tostring(split(type, "/", 0)), tostring(rgName = split(id, "/", 4)), tostring(RunID = split(id, "/", 10))
| extend prop = parse_json(properties)
| extend lTime = todatetime(prop.lastModifiedDateTime), patchName = tostring(prop.patchName), kbId = tostring(prop.kbId), installationState = tostring(prop.installationState), classifications = tostring(prop.classifications)
| where lTime > ago(7d)
| project lTime, RunID, machineName, rgName, resourceType, patchName, kbId, classifications, installationState
| sort by RunID
'@

Search-AzGraph -Query $rsQuery
