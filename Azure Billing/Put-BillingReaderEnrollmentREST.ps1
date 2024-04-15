<#
.SYNOPSIS
This script assigns a billing role to a user or service principal in Azure Billing.

.DESCRIPTION
The script connects to Azure using the provided subscription ID and tenant ID. It then acquires a bearer token to authenticate the API request. The script assigns the specified billing role to the principal ID for the given billing account. The billing account, enrollment account, billing role assignment, billing role definition, and principal ID are all required parameters.

.PARAMETER billingAccountName
The name of the billing account in Azure. This is numerical and can be found in the Azure portal under the billing account settings.

.PARAMETER enrollmentAccountName
The name of the enrollment account in Azure. This is numerical and can be found in the Azure portal under the billing account settings.

.PARAMETER billingRoleAssignmentName
The name of the billing role assignment. This can be any unique GUID that you choose. Use New-Guid to generate a new GUID.

.PARAMETER billingRoleDefinition
The name of the billing role definition. These are predefined and can be found at the following URL: https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/assign-roles-azure-service-principals

EnrollmentReader = 24f8edb6-1668-4659-b5e2-40bb5f3a7d7e
EA Purchaser = da6647fb-7651-49ee-be91-c43c4877f0c4
DepartmentReader = db609904-a47f-4794-9be8-9bd86fbffd8a
Subscription Creator = a0bcee42-bf30-4d1b-926a-48d21664ef71

.PARAMETER principalID
The Object ID of the user or service principal to assign the billing role to. Please note that this is the Object ID, not the Application ID!!!

.PARAMETER subscriptionid
The ID of the Azure subscription.

.PARAMETER tenantID
The ID of the Azure AD tenant.

.NOTES
- This script requires the Az module to be installed. You can install it by running 'Install-Module -Name Az' if it's not already installed.
- Make sure you have the necessary permissions to assign billing roles in Azure Billing.

.EXAMPLE
.\Put-BillingReaderEnrollmentREST.ps1 -billingAccountName "MyBillingAccount" -enrollmentAccountName "MyEnrollmentAccount" -billingRoleAssignmentName "MyBillingRoleAssignment" -billingRoleDefinition "Reader" -principalID "12345678-1234-1234-1234-1234567890AB" -subscriptionid "12345678-1234-1234-1234-1234567890AB" -tenantID "12345678-1234-1234-1234-1234567890AB"
Assigns the "Reader" billing role to the principal with the specified ID in the given billing account.

#>
 
param (
    [Parameter(Mandatory = $true)]
    [string]$billingAccountName,

    [Parameter(Mandatory = $true)]
    [string]$enrollmentAccountName,

    [Parameter(Mandatory = $true)]
    [string]$billingRoleAssignmentName,

    [Parameter(Mandatory = $true)]
    [string]$billingRoleDefinition,

    [Parameter(Mandatory = $true)]
    [string]$principalID,

    [Parameter(Mandatory = $true)]
    [string]$subscriptionid,

    [Parameter(Mandatory = $true)]
    [string]$tenantID
)


# set preferences
$ErrorActionPreference = "Stop"

# Import Az Module
Import-Module Az.Accounts

# Connect to Azure
Connect-AzAccount -SubscriptionId $subscriptionid -TenantId $tenantID


# Get Bearer Token
Set-AzContext -SubscriptionId $subscriptionid 
$azContext = Get-AzContext
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
$token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
$authHeader = @{
    'Content-Type'  = 'application/json'
    'Authorization' = 'Bearer ' + $token.AccessToken
}


$uri = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$billingAccountName/billingRoleAssignments/$($billingRoleAssignmentName)?api-version=2019-10-01-preview"


$body = 
@"
 {
  "properties": {
    "principalId": "$principalID",
    "principalTenantId": "$($azContext.Tenant.Id)",
    "roleDefinitionId": "/providers/Microsoft.Billing/billingAccounts/$billingAccountName/billingRoleDefinitions/$billingRoleDefinition"
  }
}
"@

Invoke-RestMethod -Method Put -Uri $uri -Headers $authHeader -Body $body
