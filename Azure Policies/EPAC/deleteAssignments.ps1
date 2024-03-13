

$mgId = "ncdevopsdev"
Get-AzPolicyAssignment  -scope "/providers/Microsoft.Management/managementgroups/$mgId"`
 | Remove-AzPolicyAssignment -Confirm:$false -ErrorAction SilentlyContinue
