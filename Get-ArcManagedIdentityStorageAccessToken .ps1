
<#

    .DESCRIPTION
       Gets SAS token using a Azure Arc Server's managed identity. 

    .INPUTS
        containerName      - Blob name
        storageAccountName - Name of the storage account.
        resourceGroupName  - Name of the resource group in which the storage account resides.
        tokenLifeHours     - Number of hours the token will be valid past the time the script is run.
        subscriptionID     - Azure subscription ID.



    .EXAMPLE
        \Get-ArcManagedIdentityStorageAccessToken.ps1 -containerName 'democontainer' -storageAccountName genpurp -resourceGroupName demo-storageAccess `
          -tokenLifeHours 4 -subscriptionID 'd8df2fd9-57bb-48bc-96fb-e1de5fe49fc0'

    .NOTES
    
        - This script needs to be run on the Azure Arc enabled server.
        - If you are using Private Endpoints on the Azure Storage, the Arc Server's managed identity MUST have the OWNER role of the
            RESOURCE GROUP which contains the storage account.


#>


param (

[string]$containerName,
[string]$storageAccountName,
[string]$resourceGroupName,
[int]$tokenLifeHours,
[string]$subscriptionID

)

$apiVersion = "2020-06-01"
$resource = "https://management.azure.com/"
$endpoint = "{0}?resource={1}&api-version={2}" -f $env:IDENTITY_ENDPOINT, $resource, $apiVersion
$VerbosePreference = "Continue"


$secretFile = ""
try {

    $params = @{
    
        Method          = 'GET'
        Uri             = $endpoint
        UseBasicParsing = $true
    
    }
    
    Invoke-WebRequest @params -Headers @{Metadata = 'True' } 

}
catch {
    $wwwAuthHeader = $_.Exception.Response.Headers["WWW-Authenticate"]
    if ($wwwAuthHeader -match "Basic realm=.+") {
        $secretFile = ($wwwAuthHeader -split "Basic realm=")[1]
    }
}
Write-Verbose "Secret file path:$secretFile"
$secret = Get-Content -Raw $secretFile


$params = @{
    
    Method          = 'GET'
    Uri             = $endpoint
    UseBasicParsing = $true
    
}
    


$response = Invoke-WebRequest @params -Headers @{Metadata = 'True'; Authorization = "Basic $secret" }
if ($response) {
    $token = (ConvertFrom-Json -InputObject $response.Content).access_token
    Write-Verbose "Access token: $($token)"
} 


# Generate token expiration date
$expDate = (Get-Date).AddHours($tokenLifeHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffK")

# Generate a Request for token

$request = 
@"
{
    "canonicalizedResource":"/blob/$storageAccountName/$containerName",
    "signedResource":"c",              // The kind of resource accessible with the SAS, in this case a container (c).
    "signedPermission":"rcwl",          // Permissions for this SAS, in this case (r)ead, (c)reate, and (w)rite. Order is important.
    "signedProtocol":"https",          // Require the SAS be used on https protocol.
    "signedExpiry":"$expDate"          // UTC expiration time for SAS in ISO 8601 format, for example 2017-09-22T00:06:00Z.
}
"@

$uri = "https://management.azure.com/subscriptions/$subscriptionID/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName/listServiceSas/?api-version=2017-06-01" 

# Request the token

$params = @{
    
    Body            = $request
    Method          = 'POST'
    Uri             = $uri
    UseBasicParsing = $true
    
}
   
$sasCred = ((Invoke-WebRequest @params -Headers @{Authorization = "Bearer $token" }).Content | ConvertFrom-Json).serviceSasToken


return $sasCred

