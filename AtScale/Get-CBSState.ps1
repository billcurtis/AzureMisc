#Requires -RunAsAdministrator

# Hardcoded configuration
$UploadOnlyUnhealthy = $false
$StorageAccountName = "xxxxxxx"
$StorageAccountKey = "xxxxxxxxxx"
$TableName = "WindowsImageHealth"

# Function to create Azure Storage authentication header for Table API
function New-TableAuthHeader {
    param($StorageAccountName, $StorageAccountKey, $Method, $Resource, $Date, $ContentLength = "")
    
    $stringToSign = ""
    $stringToSign += $Method
    $stringToSign += "`n"
    $stringToSign += ""
    $stringToSign += "`n"
    $stringToSign += "application/json"
    $stringToSign += "`n"
    $stringToSign += $Date
    $stringToSign += "`n"
    $stringToSign += "/$StorageAccountName$Resource"
    
    Write-Verbose "String to sign: '$stringToSign'"
    
    $key = [Convert]::FromBase64String($StorageAccountKey)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $key
    $signature = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign)))
    
    Write-Verbose "Signature: $signature"
    
    return "SharedKey $StorageAccountName`:$signature"
}

Write-Host "Running Windows Image Health Check..." -ForegroundColor Cyan

if ($UploadOnlyUnhealthy) {
    Write-Host "Upload Policy: Only upload non-healthy results" -ForegroundColor Gray
} else {
    Write-Host "Upload Policy: Upload all results" -ForegroundColor Gray
}

# Run health check
$result = Repair-WindowsImage -Online -ScanHealth
Write-Host "Health check completed: $($result.ImageHealthState)" -ForegroundColor Yellow

# Determine if we should upload based on health state and policy
$shouldUpload = $false
$uploadReason = ""

if ($UploadOnlyUnhealthy) {
    if ($result.ImageHealthState -ne "Healthy") {
        $shouldUpload = $true
        $uploadReason = "Image state is '$($result.ImageHealthState)' (not healthy)"
    } else {
        $uploadReason = "Image is healthy - skipping upload per policy"
    }
} else {
    $shouldUpload = $true
    $uploadReason = "Upload all results policy enabled"
}

if ($shouldUpload) {
    Write-Host "Upload Decision: $uploadReason" -ForegroundColor Yellow
} else {
    Write-Host "Upload Decision: $uploadReason" -ForegroundColor Gray
}

if ($shouldUpload) {
    # Insert entity into existing table
    $date = [DateTime]::UtcNow.ToString("R")
    $entity = @{
        PartitionKey = "WindowsHealth"
        RowKey = "$env:COMPUTERNAME-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
        ComputerName = $env:COMPUTERNAME
        ImageHealthState = $result.ImageHealthState.ToString()
        RestartNeeded = $result.RestartNeeded.ToString()
        CheckDateTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        UploadReason = $uploadReason
    } | ConvertTo-Json

    $contentLength = [System.Text.Encoding]::UTF8.GetByteCount($entity)

    $headers = @{
        "x-ms-date" = $date
        "x-ms-version" = "2019-02-02"
        "Accept" = "application/json;odata=nometadata"
        "Content-Type" = "application/json"
        "Authorization" = New-TableAuthHeader $StorageAccountName $StorageAccountKey "POST" "/$TableName" $date
    }

    Write-Host "Uploading to table: $TableName" -ForegroundColor Yellow
    Write-Host "Date: $date" -ForegroundColor Gray

    $VerbosePreference = "Continue"

    try {
        $response = Invoke-RestMethod -Uri "https://$StorageAccountName.table.core.windows.net/$TableName" -Method POST -Headers $headers -Body $entity -ContentType "application/json" -Verbose
        Write-Host "UPLOAD SUCCESS: Health: $($result.ImageHealthState), Restart: $($result.RestartNeeded)" -ForegroundColor Green
    }
    catch {
        Write-Host "UPLOAD FAILED" -ForegroundColor Red
        Write-Host "Error Details:" -ForegroundColor Red
        
        if ($_.Exception.Response) {
            Write-Host "Status Code: $($_.Exception.Response.StatusCode)" -ForegroundColor Red
            Write-Host "Status Description: $($_.Exception.Response.StatusDescription)" -ForegroundColor Red
        }
        
        Write-Host "Full Error: $($_.Exception.Message)" -ForegroundColor Red
        
        if ($_.Exception.Response) {
            try {
                $streamReader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $streamReader.ReadToEnd()
                Write-Host "Response Body: $responseBody" -ForegroundColor Red
                $streamReader.Close()
            }
            catch {
                Write-Host "Could not read response body" -ForegroundColor Red
            }
        }
    }
} else {
    Write-Host "SKIPPED UPLOAD: Health: $($result.ImageHealthState), Restart: $($result.RestartNeeded)" -ForegroundColor Cyan
    Write-Host "Reason: $uploadReason" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor White
Write-Host "  Computer: $env:COMPUTERNAME" -ForegroundColor Gray
Write-Host "  Health State: $($result.ImageHealthState)" -ForegroundColor Gray
Write-Host "  Restart Needed: $($result.RestartNeeded)" -ForegroundColor Gray

if ($UploadOnlyUnhealthy) {
    Write-Host "  Upload Policy: Unhealthy Only" -ForegroundColor Gray
} else {
    Write-Host "  Upload Policy: All Results" -ForegroundColor Gray
}

if ($shouldUpload) {
    Write-Host "  Action Taken: Uploaded to Azure" -ForegroundColor Green
} else {
    Write-Host "  Action Taken: Local check only" -ForegroundColor Cyan
}