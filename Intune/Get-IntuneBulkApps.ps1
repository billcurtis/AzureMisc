<#

.SYNOPSIS
    Retrieves Intune application installation status reports in bulk with performance tuning options.

.DESCRIPTION
    This script connects to the Microsoft Graph API using client credentials to retrieve a list of Intune applications and their installation status across devices.

.PARAMETER ThrottleLimit
    The maximum number of concurrent requests to send to the Graph API. Default is 3.   

.PARAMETER DelayMilliseconds
    The delay in milliseconds between requests to avoid rate limiting. Default is 2000 ms.

.PARAMETER BatchSize
    The number of applications to process in each batch. Default is 5.

.PARAMETER OutputPath
    The file path to save the output CSV. If not provided, a timestamped file will be created in the current directory.

.EXAMPLE
    .\Get-IntuneBulkApps.ps1 -ThrottleLimit 5 -DelayMilliseconds 1000 -BatchSize 10 -OutputPath "C:\Reports\AppInstallStatus.csv"
    Retrieves Intune application installation status reports with specified performance tuning parameters and saves the output to the specified path.   


#>

# Add parameters for performance tuning and output path
param(
    [int]$ThrottleLimit = 3,
    [int]$DelayMilliseconds = 2000,
    [int]$BatchSize = 5,
    [string]$OutputPath = ""
)

$appId = "<application-id>"
$appSecret = "<app-secret>"
$tenantId = "<tenant-id>"

# Obtain an access token using client credentials  
$body = @{  
    grant_type    = "client_credentials"  
    scope         = "https://graph.microsoft.com/.default"  
    client_id     = $appId  
    client_secret = $appSecret  
}  
 
$response = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"  
$token = $response.access_token  
 
# Retrieve applications  
$appUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps"  
$applications = Invoke-RestMethod -Uri $appUri -Method Get -Headers @{Authorization = "Bearer $token" }  
 
Write-Host "Found $($applications.value.Count) applications to process..." -ForegroundColor Green

# Use ArrayList for better performance than array concatenation
$output = [System.Collections.ArrayList]::new()
$processedCount = 0

# Function to process a single app (for parallel execution)
$processAppScriptBlock = {
    param($app, $token, $delayMs)
    
    $ApplicationId = $app.id  
    $ApplicationName = $app.displayName  
    $appResults = [System.Collections.ArrayList]::new()
 
    try {
        # Request URI and parameters for the report  
        $uri = "https://graph.microsoft.com/beta/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport"  
        
        $params = @{  
            select  = @("DeviceName", "UserPrincipalName", "DeviceId", "Platform", "AppVersion", "ApplicationId", "InstallState", "AppInstallState", "InstallStateDetail", "UserName")  
            skip    = 0  
            top     = 5000  ### Max number of users/computers allocation to the app
            filter  = "(ApplicationId eq '$ApplicationId')"
            orderBy = @()  
        }  
 
        # Make the POST request with retry logic
        $maxRetries = 5
        $retryCount = 0
        do {
            try {
                $response = Invoke-RestMethod -Uri $uri -Method Post -Headers @{Authorization = "Bearer $token" } -Body ($params | ConvertTo-Json) -ContentType "application/json"
                break
            }
            catch {
                $retryCount++
                if ($_.Exception.Response.StatusCode -eq 429 -or $_.Exception.Message -like "*429*") {
                    $waitTime = [math]::Min(($delayMs * [math]::Pow(2, $retryCount)), 30000) # Cap at 30 seconds
                    Write-Warning "Rate limited for $ApplicationName. Waiting $($waitTime/1000) seconds before retry $retryCount/$maxRetries"
                    Start-Sleep -Milliseconds $waitTime
                    if ($retryCount -ge $maxRetries) {
                        Write-Error "Max retries exceeded for $ApplicationName after rate limiting"
                        return $appResults
                    }
                }
                else {
                    Write-Error "Failed to process $ApplicationName : $($_.Exception.Message)"
                    return $appResults
                }
            }
        } while ($retryCount -lt $maxRetries)
          
        # Check if Values contain data  
        if ($response.Values) {  
            foreach ($value in $response.Values) {  
                # Split the concatenated string to extract the relevant fields  
                $fields = $value -split ' '  
     
                # Assuming the format is consistent, map the fields based on select order
                $outputObject = [PSCustomObject]@{  
                    ApplicationName    = $ApplicationName  
                    ComputerName       = if ($fields.Count -gt 1) { $fields[1] } else { "Unknown" }    # DeviceName
                    UserUPN            = if ($fields.Count -gt 2) { $fields[2] } else { "Unknown" }    # UserPrincipalName  
                    DeviceId           = if ($fields.Count -gt 3) { $fields[3] } else { "Unknown" }    # DeviceId
                    Platform           = if ($fields.Count -gt 4) { $fields[4] } else { "Unknown" }    # Platform
                    AppVersion         = if ($fields.Count -gt 5) { $fields[5] } else { "Unknown" }    # AppVersion
                    ApplicationId      = if ($fields.Count -gt 6) { $fields[6] } else { "Unknown" }    # ApplicationId
                    InstallState       = if ($fields.Count -gt 7) { $fields[7] } else { "Unknown" }    # InstallState
                    AppInstallState    = if ($fields.Count -gt 8) { $fields[8] } else { "Unknown" }    # AppInstallState
                    InstallStateDetail = if ($fields.Count -gt 9) { $fields[9] } else { "Unknown" }    # InstallStateDetail
                    Username           = if ($fields.Count -gt 10) { $fields[10] } else { "Unknown" }  # Username
                    UserID             = if ($fields.Count -gt 11) { $fields[11] } else { "Unknown" }  # UserID
                }  
                [void]$appResults.Add($outputObject)
            }
            Write-Host "Processed $ApplicationName - Found $($appResults.Count) installations" -ForegroundColor Green
        }
        else {  
            Write-Host "No installation data found for $ApplicationName" -ForegroundColor Yellow  
        }
        
        # Throttle to avoid rate limiting
        Start-Sleep -Milliseconds $delayMs
        
        return $appResults
    }
    catch {
        Write-Warning "Failed to process $ApplicationName : $($_.Exception.Message)"
        return $appResults
    }
}

# Process applications in parallel batches
$appBatches = @()
for ($i = 0; $i -lt $applications.value.Count; $i += $BatchSize) {
    $appBatches += , @($applications.value[$i..([math]::Min($i + $BatchSize - 1, $applications.value.Count - 1))])
}

Write-Host "Processing $($applications.value.Count) apps in $($appBatches.Count) batches of up to $BatchSize apps each..." -ForegroundColor Cyan

foreach ($batch in $appBatches) {
    Write-Host "Processing batch with $($batch.Count) apps..." -ForegroundColor Cyan
    
    # Process current batch in parallel
    $jobs = foreach ($app in $batch) {
        Start-Job -ScriptBlock $processAppScriptBlock -ArgumentList $app, $token, $DelayMilliseconds
    }
    
    # Wait for all jobs in this batch to complete and collect results
    $jobs | ForEach-Object {
        $result = Receive-Job -Job $_ -Wait
        if ($result) {
            # Handle both single objects and arrays from job results
            if ($result -is [System.Collections.IEnumerable] -and $result -isnot [string]) {
                foreach ($item in $result) {
                    [void]$output.Add($item)
                }
            }
            else {
                [void]$output.Add($result)
            }
        }
        Remove-Job -Job $_
        $processedCount++
        Write-Progress -Activity "Processing Applications" -Status "$processedCount of $($applications.value.Count) completed" -PercentComplete (($processedCount / $applications.value.Count) * 100)
    }
    
    # Small delay between batches to be extra careful with rate limiting
    if ($batch -ne $appBatches[-1]) {
        Start-Sleep -Milliseconds 2000  # Increased delay between batches
    }
}  
 
# Output results
Write-Host "`nProcessing complete!" -ForegroundColor Green
Write-Host "Total applications processed: $($applications.value.Count)" -ForegroundColor Cyan
Write-Host "Total installations found: $($output.Count)" -ForegroundColor Cyan

# Generate timestamped filename
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ([string]::IsNullOrEmpty($OutputPath)) {
    $csvPath = "ApplicationInstallStatusReport_$timestamp.csv"
}
else {
    # If user provided a path, ensure it has the timestamp and .csv extension
    $directory = Split-Path $OutputPath -Parent
    $filename = Split-Path $OutputPath -LeafBase
    $extension = Split-Path $OutputPath -Extension
    
    # Create directory if it doesn't exist
    if (![string]::IsNullOrEmpty($directory) -and !(Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    
    # Build the final path with timestamp
    if ([string]::IsNullOrEmpty($extension) -or $extension -ne ".csv") {
        $csvPath = if ([string]::IsNullOrEmpty($directory)) { "${filename}_$timestamp.csv" } else { "$directory\${filename}_$timestamp.csv" }
    }
    else {
        $csvPath = if ([string]::IsNullOrEmpty($directory)) { "${filename}_$timestamp.csv" } else { "$directory\${filename}_$timestamp.csv" }
    }
}

# Output to screen  
$output | Format-Table -AutoSize  
$output.Count

# Export to CSV  
$output | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "Data exported to: $csvPath" -ForegroundColor Green  
