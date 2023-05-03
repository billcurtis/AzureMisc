# static variables

$subscriptionID = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$tenantID = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$clientID = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$clientSecret =  'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
$resourcegroupName = 'azstack-rg'
$arcserverresourceGroupName = 'azstack-rg'

# preferences

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'SilentlyContinue'


# import modules

Import-Module Az.StackHCI
$VerbosePreference = 'Continue'


# create credential for service principal
$arcSpnCredential = new-object -typename System.Management.Automation.PSCredential `
        -argumentlist (($clientID),(ConvertTo-SecureString $clientSecret -AsPlainText -Force))



# Ensure that the SP is OWNER of the RG
# Perms for SP = "Azure Stack HCI registration role"

Connect-AzAccount -ServicePrincipal -Credential $arcSpnCredential -Tenant $tenantID

# Unregister
$accessToken = Get-AzAccessToken 
UnRegister-AzStackHCI `
 -SubscriptionId $subscriptionID `
 -ArmAccessToken $accessToken.Token `
 -AccountId $accessToken.UserId `
 -Confirm:$false
