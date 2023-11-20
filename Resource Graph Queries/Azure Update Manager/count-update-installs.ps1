<#

The following query returns a list of update installations with their status for your machines
 from the last seven days. Results include the time when the update deployment was run, the 
 resource ID of the installation, machine details, and the count of OS updates installed based 
 on their status and your selection.

#>


$rsQuery = @'
patchinstallationresources
| where type !has "softwarepatches"
| extend machineName = tostring(split(id, "/", 8)), resourceType = tostring(split(type, "/", 0)), tostring(rgName = split(id, "/", 4))
| extend prop = parse_json(properties)
| extend lTime = todatetime(prop.lastModifiedDateTime), OS = tostring(prop.osType), installedPatchCount = tostring(prop.installedPatchCount), failedPatchCount = tostring(prop.failedPatchCount), pendingPatchCount = tostring(prop.pendingPatchCount), excludedPatchCount = tostring(prop.excludedPatchCount), notSelectedPatchCount = tostring(prop.notSelectedPatchCount)
| where lTime > ago(7d)
| project lTime, RunID=name,machineName, rgName, resourceType, OS, installedPatchCount, failedPatchCount, pendingPatchCount, excludedPatchCount, notSelectedPatchCount
'@

Search-AzGraph -Query $rsQuery
