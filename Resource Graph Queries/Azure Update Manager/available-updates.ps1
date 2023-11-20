

<#
The following query returns a list of pending updates for your machine with the time 
    when the assessment was performed, the resource ID for the assessment, OS type on 
    the machine, and the OS updates available based on update classification.
#>

$rsQuery = @'
patchassessmentresources
| where type !has "softwarepatches"
| extend prop = parse_json(properties)
| extend lastTime = properties.lastModifiedDateTime
| extend updateRollupCount = prop.availablePatchCountByClassification.updateRollup, featurePackCount = prop.availablePatchCountByClassification.featurePack, servicePackCount = prop.availablePatchCountByClassification.servicePack, definitionCount = prop.availablePatchCountByClassification.definition, securityCount = prop.availablePatchCountByClassification.security, criticalCount = prop.availablePatchCountByClassification.critical, updatesCount = prop.availablePatchCountByClassification.updates, toolsCount = prop.availablePatchCountByClassification.tools, otherCount = prop.availablePatchCountByClassification.other, OS = prop.osType
| project lastTime, id, OS, updateRollupCount, featurePackCount, servicePackCount, definitionCount, securityCount, criticalCount, updatesCount, toolsCount, otherCount
'@

Search-AzGraph -Query $rsQuery
