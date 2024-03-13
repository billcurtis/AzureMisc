
$mgId = "ncdevopsdev"

$a = $PolicyDefinitions = Get-AzPolicyDefinition -ManagementGroupName $mgId| Where-Object {$_.Properties.policyType -eq "Custom"} 
foreach ($PolicyDefinition in $PolicyDefinitions) {
    Remove-AzPolicyDefinition -Name $PolicyDefinition.Name -Confirm:$false -Force
}
