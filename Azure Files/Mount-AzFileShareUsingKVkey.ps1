<#
.DESCRIPTION 
This demo script mounts an Azure File Share using the Storage Account Key stored in Azure Key Vault. The script uses the Managed Identity of the Azure VM
 to authenticate to Azure Key Vault and retrieve the Storage Account Key. The script then mounts the Azure File Share using the retrieved Storage Account Key.

#>


# Variables
$KeyVaultName = "XXXXXXXXXXXXXXXXXXXXXX" # Replace with your Azure Key Vault name
$SecretName = "XXXXXXXXXXXXXXXXXXXXXX"    # Replace with the name of the secret you want to retrieve. This secret is the storage access key.
$AzStorageAccountName = "XXXXXXXXXXXXXXXXXXX"  # replace with the Storage Account Name you wish to connect to.
$AzFileShareName = "XXXXXXXXXXXXXXXX" #Replace with name of File Share
$DriveLetterforShare = "Z"  # replace with drive letter for share

# Get the Azure Instance Metadata Service (IMDS) token for this Azure VM's Managed Identity
$ImdsResponse = Invoke-RestMethod -Method Get -Headers @{Metadata = "true" } -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net"

# Extract the access token
$AccessToken = $ImdsResponse.access_token

# Use the access token to call the Azure Key Vault REST API
$KeyVaultUri = "https://$KeyVaultName.vault.azure.net/secrets/$($SecretName)?api-version=7.3"
$Headers = @{Authorization = "Bearer $AccessToken" }
$KeyVaultResponse = Invoke-RestMethod -Method Get -Headers $Headers -Uri $KeyVaultUri

# Extract the secret value
$storageAcctKey = $KeyVaultResponse.value

# Mount the file Share
$fileSharePath = "\\$AzStorageAccountName.file.core.windows.net\$AzFileShareName"
$userName = "localhost\$AzStorageAccountName"

$params = @{

    Name       = $DriveLetterforShare
    PSProvider = "FileSystem"
    Root       = $fileSharePath
    Credential = (New-Object System.Management.Automation.PSCredential($userName, (ConvertTo-SecureString $storageAcctKey -AsPlainText -Force)))
    Persist    = $true

}

New-PSDrive @params