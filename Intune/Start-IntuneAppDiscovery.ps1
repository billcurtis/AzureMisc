#Requires -Version 7.0

<#
.DESCRIPTION
    This script retrieves all managed iOS and Android devices from Microsoft Intune via Microsoft Graph API,
    then fetches the list of installed applications for each device, handling rate limits with retries and backoffs. 

.PARAMETER IOSOnly
    Retrieve applications only for iOS devices.

.PARAMETER AndroidOnly
    Retrieve applications only for Android devices.

.PARAMETER IOSAndAndroidOnly
    Retrieve applications only for iOS and Android devices.

.PARAMETER MacOSOnly
    Retrieve applications only for macOS devices.

.PARAMETER WindowsOnly
    Retrieve applications only for Windows devices.

.PARAMETER ExportToCSV
    Export the final results to a CSV file. The filename will include a timestamp and the OS filter used
    and will be saved in the current directory.

.PARAMETER ExcludePatterns
    Exclude common system/framework apps from the results based on predefined patterns
    hardcoded in the script.

.PARAMETER ThrottleLimit
    Number of devices to process in parallel during fallback mode (1-10, default: 1).
    Lower values reduce API throttling but increase processing time.

.PARAMETER BatchSize
    Number of devices to process per batch during fallback mode (1-100, default: 25).
    Smaller batches reduce memory usage and allow for better progress tracking.

.PARAMETER InterBatchDelay
    Delay in seconds between processing batches during fallback mode (0-300, default: 30).
    Higher values reduce API throttling but increase total processing time.

.EXAMPLE
    # Get all Windows devices, exclude system apps, and export to CSV
    ./Start-IntuneAppDiscovery.ps1 -WindowsOnly -ExcludePatterns -ExportToCSV 

    # Get only iOS and Android devices and export to CSV
    ./Start-IntuneAppDiscovery.ps1 -IOSAndAndroidOnly -ExportToCSV

    # Get all devices but exclude system apps
    ./Start-IntuneAppDiscovery.ps1 -ExcludePatterns

    # Normal run without filtering
    ./Start-IntuneAppDiscovery.ps1 -ExportToCSV
    
    # Aggressive performance settings (use with caution)
    ./Start-IntuneAppDiscovery.ps1 -WindowsOnly -ThrottleLimit 3 -BatchSize 50 -InterBatchDelay 15 -ExportToCSV
    
    # Conservative settings for rate limit sensitive environments
    ./Start-IntuneAppDiscovery.ps1 -AndroidOnly -ThrottleLimit 1 -BatchSize 10 -InterBatchDelay 60 -ExportToCSV

.NOTES
    clientId, clientSecret, and tenantId are hardcoded for simplicity.
    In a production script, consider using a more secure method to handle credentials, such as Azure Key Vault.

    Exclusion patterns can be modified in the $ExclusionPatterns array at the beginning of the script.

    Requires PowerShell 7.0 or later due to the use of ForEach-Object -Parallel.
#>
 
param(
    [switch]$IOSOnly,
    [switch]$AndroidOnly,
    [switch]$IOSAndAndroidOnly,    
    [switch]$MacOSOnly,
    [switch]$WindowsOnly,
    [switch]$ExportToCSV,
    [switch]$ExcludePatterns,
    
    # Performance tuning parameters
    [Parameter(HelpMessage = "Number of devices to process in parallel (default: 50)")]
    [ValidateRange(1, 100)]
    [int]$ThrottleLimit = 40,
    
    [Parameter(HelpMessage = "Number of devices to process per batch (default: 100)")]
    [ValidateRange(1, 200)]
    [int]$BatchSize = 100,
    
    [Parameter(HelpMessage = "Delay in seconds between batches (default: 30)")]
    [ValidateRange(0, 300)]
    [int]$InterBatchDelay = 30
)


# Hardcoded credentials for Microsoft Graph API authentication

$clientId = "<YOUR_CLIENT_ID_HERE>"
$clientSecret = "<YOUR_CLIENT_SECRET_HERE>"
$tenantId = "<YOUR_TENANT_ID_HERE>"


# Start timing the script execution
$startTime = Get-Date

# Define exclusion patterns for filtering out system/framework apps
$ExclusionPatterns = @(
    "Microsoft.NET.*",
    "Microsoft.VCLibs.*",
    "Microsoft.UI.Xaml.*",
    "*.GameAssist",
    "*.QuickAssist",
    "*ShellExtension*",
    "Microsoft.Windows.DevHome",
    "*CorporationII*"
)


# preferences
$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Global variables for token management
$Global:CurrentToken = $null
$Global:TokenExpiration = $null

function Get-AuthToken {
    $body = @{
        "grant_type"    = "client_credentials"
        "client_id"     = $clientId
        "client_secret" = $clientSecret
        "scope"         = "https://graph.microsoft.com/.default"
    }
    $uri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body
            
        # Store token and calculate expiration time (subtract 5 minutes for safety buffer)
        $Global:CurrentToken = $response.access_token
        $Global:TokenExpiration = (Get-Date).AddSeconds($response.expires_in - 300)
            
        Write-Host "New token acquired, expires at: $($Global:TokenExpiration.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
            
        return $response.access_token
    }
    catch {
        Write-Error "Failed to acquire authentication token: $_"
        throw
    }
}

function Get-ValidToken {
    # Check if we have a token and if it's still valid
    if ($null -eq $Global:CurrentToken -or (Get-Date) -gt $Global:TokenExpiration) {
        Write-Host "Token expired or missing, acquiring new token..." -ForegroundColor Yellow
        return Get-AuthToken
    }
        
    # Token is still valid
    $timeRemaining = $Global:TokenExpiration - (Get-Date)
    Write-Verbose "Using existing token, expires in $([math]::Round($timeRemaining.TotalMinutes, 1)) minutes"
    return $Global:CurrentToken
}

function Invoke-GraphRequestWithRetry {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = "GET",
        [object]$Body = $null,
        [string]$ContentType = "application/json",
        [int]$MaxRetries = 3
    )
    
    $retryCount = 0
    do {
        try {
            # Ensure we have a valid token
            $validToken = Get-ValidToken
            $Headers["Authorization"] = "Bearer $validToken"
                
            $params = @{
                Uri     = $Uri
                Headers = $Headers
                Method  = $Method
            }
            
            if ($Body) {
                $params.Body = $Body
                $params.ContentType = $ContentType
            }
            
            return Invoke-RestMethod @params
        }
        catch {
            $retryCount++
            $statusCode = $null
            $errorMessage = $_.Exception.Message
            
            # Try to get status code from different possible locations
            if ($_.Exception.Response.StatusCode) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }
            elseif ($_.Exception.Message -match 'HTTP\s+(\d+)') {
                $statusCode = [int]$matches[1]
            }
            elseif ($errorMessage -match '(\d{3})') {
                $statusCode = [int]$matches[1]
            }
            
            # Handle 404 Not Found errors (device no longer exists or is inaccessible)
            if ($statusCode -eq 404) {
                Write-Warning "Resource not found (404) for URI: $Uri - Device may have been deleted or is inaccessible"
                return $null  # Return null to allow script to continue
            }
                
            # Handle authentication errors (401 Unauthorized)
            if ($statusCode -eq 401) {
                if ($retryCount -le $MaxRetries) {
                    Write-Warning "Authentication failed, refreshing token and retrying... (Attempt $retryCount/$MaxRetries)"
                    # Force token refresh by clearing current token
                    $Global:CurrentToken = $null
                    $Global:TokenExpiration = $null
                    Start-Sleep -Seconds 2
                    continue
                }
            }
                
            # Handle rate limit errors (429 TooManyRequests)
            if ($statusCode -eq 429 -or $errorMessage -like "*TooManyRequests*" -or $errorMessage -like "*throttled*") {                
                if ($retryCount -le $MaxRetries) {
                    # Enhanced exponential backoff with cap for main function
                    $retryAfter = 60 # Default 60 seconds for rate limits
                    if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers["Retry-After"]) {
                        $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"]
                    }
                    else {
                        # Progressive backoff: 60s, 120s, 240s, 300s (capped at 5 min)
                        $retryAfter = [Math]::Min([Math]::Pow(2, $retryCount) * 30, 300)
                    }
                    
                    Write-Warning "Rate limit hit. Waiting $retryAfter seconds before retry $retryCount/$MaxRetries..."
                    Start-Sleep -Seconds $retryAfter
                    continue
                }
            }
            
            # For all other errors or max retries exceeded, throw immediately
            throw $_
        }
    } while ($retryCount -le $MaxRetries)
}

function Get-AllManagedDevices {
    try {
        Write-Host "Fetching all managed devices..." -ForegroundColor Yellow

        $allDevices = @()
        
        # Build URI with appropriate OS filter and optimized select fields
        $baseUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices"
        $selectFields = "`$select=id,deviceName,userPrincipalName,operatingSystem,osVersion,model,manufacturer"
        $filter = ""
        
        switch ($true) {
            $IOSOnly { 
                $filter = "&`$filter=operatingSystem eq 'iOS'"
                Write-Host "Filtering for iOS devices only..." -ForegroundColor Cyan
                break 
            }
            $AndroidOnly { 
                $filter = "&`$filter=operatingSystem eq 'Android'"
                Write-Host "Filtering for Android devices only..." -ForegroundColor Cyan
                break 
            }
            $IOSAndAndroidOnly { 
                $filter = "&`$filter=operatingSystem eq 'iOS' or operatingSystem eq 'Android'"
                Write-Host "Filtering for iOS and Android devices only..." -ForegroundColor Cyan
                break 
            }
            $MacOSOnly { 
                $filter = "&`$filter=operatingSystem eq 'macOS'"
                Write-Host "Filtering for macOS devices only..." -ForegroundColor Cyan
                break 
            }
            $WindowsOnly { 
                $filter = "&`$filter=operatingSystem eq 'Windows'"
                Write-Host "Filtering for Windows devices only..." -ForegroundColor Cyan
                break 
            }
            $AllOS { 
                $filter = ""
                Write-Host "Fetching devices for all operating systems..." -ForegroundColor Cyan
                break 
            }
            default { 
                $filter = ""
                Write-Host "No specific OS filter provided, fetching all devices..." -ForegroundColor Cyan
                break 
            }
        }
        
        $uri = $baseUri + "?" + $selectFields + $filter
        
        $accessToken = Get-ValidToken
        $headers = @{
            Authorization = "Bearer $accessToken"
        }

        do {
            $response = Invoke-GraphRequestWithRetry -Uri $uri -Headers $headers
            $allDevices += $response.value
            $uri = $response.'@odata.nextLink'
        } while ($uri)

        Write-Host "Found $($allDevices.Count) devices" -ForegroundColor Green
        return $allDevices
    }
    catch {
        Write-Error "Failed to get managed devices: $_"
        return @()
    }
}

#main

Write-Host "Using individual device queries for app discovery..." -ForegroundColor Yellow
    
$devices = Get-AllManagedDevices
$totalDevicesScanned = $devices.Count
Write-Host "Total devices to scan: $totalDevicesScanned" -ForegroundColor Green

#get the time for end time
$endTime = Get-Date

#Get access token
$accessToken = Get-ValidToken

Write-Host "Starting batch processing of $($devices.Count) devices with throttle limit of $ThrottleLimit..." -ForegroundColor Green
Write-Host "Batch size: $BatchSize devices per batch, Inter-batch delay: $InterBatchDelay seconds" -ForegroundColor Cyan
Write-Host "This may take some time due to rate limiting controls..." -ForegroundColor Yellow

# Process devices in smaller batches to reduce API pressure
$results = @()
    
for ($i = 0; $i -lt $devices.Count; $i += $BatchSize) {
    $batchEnd = [Math]::Min($i + $BatchSize - 1, $devices.Count - 1)
    $batch = $devices[$i..$batchEnd]
        
    Write-Host "Processing batch $([Math]::Floor($i / $BatchSize) + 1) of $([Math]::Ceiling($devices.Count / $BatchSize)) ($($batch.Count) devices)..." -ForegroundColor Cyan
        
    # Process current batch with configurable throttle limit
    $batchResults = $batch | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
                
        # Progressive delay based on position in batch
        $deviceIndex = $using:i + [Array]::IndexOf($using:batch, $_)
        $delayMs = [Math]::Min(1000 + ($deviceIndex * 200), 5000)
        Start-Sleep -Milliseconds $delayMs
    
        
        #functions
        function Get-FreshToken {
            $clientId = $using:clientId
            $clientSecret = $using:clientSecret
            $tenantId = $using:tenantId
            
            $body = @{
                "grant_type"    = "client_credentials"
                "client_id"     = $clientId
                "client_secret" = $clientSecret
                "scope"         = "https://graph.microsoft.com/.default"
            }
            $uri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
                
            try {
                $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body
                return $response.access_token
            }
            catch {
                Write-Error "Failed to acquire authentication token in parallel thread: $_"
                throw
            }
        }
        
        function Invoke-GraphRequestWithRetry {
            param(
                [string]$Uri,
                [hashtable]$Headers,
                [string]$Method = "GET",
                [object]$Body = $null,
                [string]$ContentType = "application/json",
                [int]$MaxRetries = 5
            )
                
            $retryCount = 0
            do {
                try {
                    $params = @{
                        Uri     = $Uri
                        Headers = $Headers
                        Method  = $Method
                    }
                        
                    if ($Body) {
                        $params.Body = $Body
                        $params.ContentType = $ContentType
                    }
                        
                    return Invoke-RestMethod @params
                }
                catch {
                    $retryCount++
                    $statusCode = $null
                    $errorMessage = $_.Exception.Message
                            
                    # Try to get status code from different possible locations
                    if ($_.Exception.Response.StatusCode) {
                        $statusCode = $_.Exception.Response.StatusCode.value__
                    }
                    elseif ($_.Exception.Message -match 'HTTP\s+(\d+)') {
                        $statusCode = [int]$matches[1]
                    }
                    elseif ($errorMessage -match '(\d{3})') {
                        $statusCode = [int]$matches[1]
                    }
                    
                    # Handle 404 Not Found errors (device no longer exists or is inaccessible)
                    if ($statusCode -eq 404) {
                        Write-Warning "Resource not found (404) for URI: $Uri - Device may have been deleted or is inaccessible"
                        return $null  # Return null to allow script to continue
                    }
                    
                    # Handle authentication errors (401 Unauthorized)
                    if ($statusCode -eq 401) {
                        if ($retryCount -le $MaxRetries) {
                            Write-Warning "Authentication failed (401), refreshing token and retrying... (Attempt $retryCount/$MaxRetries)"
                            # Get a fresh token
                            $freshToken = Get-FreshToken
                            $Headers["Authorization"] = "Bearer $freshToken"
                            Start-Sleep -Seconds 2
                            continue
                        }
                    }
                            
                    # Handle rate limit errors (429 TooManyRequests)
                    if ($statusCode -eq 429 -or $errorMessage -like "*TooManyRequests*" -or $errorMessage -like "*throttled*") {
                        if ($retryCount -le $MaxRetries) {
                            # Enhanced exponential backoff with cap
                            $retryAfter = 60 # Default 60 seconds for rate limits
                            if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers["Retry-After"]) {
                                $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"]
                            }
                            else {
                                # Progressive backoff: 60s, 120s, 240s, 300s (capped at 5 min)
                                $retryAfter = [Math]::Min([Math]::Pow(2, $retryCount) * 30, 300)
                            }
                                
                            Write-Warning "Rate limit hit for device query (Status: $statusCode). Waiting $retryAfter seconds before retry $retryCount/$MaxRetries..."
                            Start-Sleep -Seconds $retryAfter
                            continue
                        }
                        else {
                            Write-Error "Max retries exceeded for rate limiting. Error: $errorMessage"
                            throw $_
                        }
                    }
                        
                    # For all other errors, throw immediately
                    Write-Error "API request failed with status $statusCode`: $errorMessage"
                    throw $_
                }
            } while ($retryCount -le $MaxRetries)
        }
                
        function Get-DeviceDiscoveredApps {

            param(
                [Parameter(Mandatory = $true)]
                [string]$DeviceId,
                [string]$DeviceName
            )
    
            try {
                # Try beta endpoint with detectedApps
                $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$DeviceId')?`$expand=detectedApps"
                $accessToken = $using:accessToken
                $headers = @{
                    Authorization = "Bearer $accessToken"
                }
                $response = Invoke-GraphRequestWithRetry -Uri $uri -Headers $headers
                
                # Check if response is null (404 error was handled)
                if ($null -eq $response) {
                    Write-Warning "Device $DeviceName (ID: $DeviceId) not found - skipping"
                    return @()
                }
        
                if ($response.detectedApps) {
                    return $response.detectedApps
                }
        
                # If no apps in the expand, try direct query
                # Note: Platform filtering on detectedApps endpoint can cause issues
                # We rely on device-level OS filtering instead for more reliable results
                $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$DeviceId')/detectedApps"
        
                $apps = @()
                do {
                    $response = Invoke-GraphRequestWithRetry -Uri $uri -Headers $headers
                    
                    # Check if response is null (404 error was handled)
                    if ($null -eq $response) {
                        Write-Warning "DetectedApps not found for device $DeviceName (ID: $DeviceId) - skipping"
                        break
                    }
                    
                    if ($response.value) {
                        $apps += $response.value
                    }
                    $uri = $response.'@odata.nextLink'
                } while ($uri)
        
                return $apps
            }
            catch {
                # If detectedApps fails, try alternative approach with installed apps
                try {
                    Write-Warning "DetectedApps not available for $DeviceName, trying alternative method..."
                    $accessToken = $using:accessToken
                    $headers = @{
                        Authorization = "Bearer $accessToken"
                    }
                    # Try getting apps through assignments
                    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$DeviceId')?`$select=id,deviceName,userId&`$expand=users(`$select=id)"
                    $deviceInfo = Invoke-GraphRequestWithRetry -Uri $uri -Headers $headers
                    
                    # Check if deviceInfo is null (404 error)
                    if ($null -eq $deviceInfo) {
                        Write-Warning "Device $DeviceName (ID: $DeviceId) not found in alternative method - skipping"
                        return @()
                    }
            
                    # Get app install status for this device
                    $uri = "https://graph.microsoft.com/beta/deviceManagement/reports/getDeviceInstallStatusReport"
                    $body = @{
                        filter = "(DeviceId eq '$DeviceId')"
                        select = @("ApplicationId", "AppInstallState", "AppVersion", "DisplayName")
                        skip   = 0
                        top    = 1000
                    } | ConvertTo-Json
            
                    $response = Invoke-GraphRequestWithRetry -Uri $uri -Headers $headers -Method "POST" -Body $body
                    
                    # Check if response is null
                    if ($null -eq $response) {
                        Write-Warning "Install status report not available for device $DeviceName - skipping"
                        return @()
                    }
            
                    if ($response.values) {
                        $apps = @()
                        foreach ($value in $response.values) {
                            $apps += @{
                                displayName  = $value[3]
                                version      = $value[2]
                                id           = $value[0]
                                installState = $value[1]
                            }
                        }
                        return $apps
                    }
                }
                catch {
                    Write-Verbose "Alternative method also failed: $_"
                }
        
                Write-Warning "Unable to get apps for device $DeviceName (ID: $DeviceId)"
                return @()
            }
        }
        $dAppresults = @()
        $deviceId = $_.id
        $deviceName = $_.deviceName
        $deviceUserPrincipalName = $_.userPrincipalName
        $deviceOperatingSystem = $_.operatingSystem
        $deviceOSVersion = $_.osVersion
        $deviceModel = $_.model
        $deviceManufacturer = $_.manufacturer

        Write-Host -Message "Processing device: $deviceName (ID: $deviceId)" -ForegroundColor Cyan 
        Get-DeviceDiscoveredApps -DeviceId $deviceId -DeviceName $deviceName | ForEach-Object {
            $dAppresults += [PSCustomObject]@{
                DeviceName        = $deviceName
                DeviceId          = $deviceId
                UserPrincipalName = $deviceUserPrincipalName
                OperatingSystem   = $deviceOperatingSystem
                OSVersion         = $deviceOSVersion
                DeviceModel       = $deviceModel
                Manufacturer      = $deviceManufacturer
                AppName           = $_.displayName
                AppVersion        = $_.version
                AppId             = $_.id
                AppPublisher      = $_.publisher
                AppSizeinBytes    = $_.sizeInBytes
                DeviceCount       = $_.deviceCount
                Platform          = $_.platform
            }
        }
                
        return $dAppresults
    }
        
    $results += $batchResults
    Write-Host "Batch completed. Total records so far: $($results.Count)" -ForegroundColor Green
        
    # Add delay between batches to prevent overwhelming the API
    if ($i + $BatchSize -lt $devices.Count) {
        Write-Host "Waiting $InterBatchDelay seconds before next batch to respect rate limits..." -ForegroundColor Yellow
        Start-Sleep -Seconds $InterBatchDelay
    }
}
    
$totalDevicesScanned = $devices.Count

Write-Host "`nData collection completed!" -ForegroundColor Green

# Show performance metrics
Write-Host "Performance: Used individual device queries with optimized batching and delays" -ForegroundColor Yellow

Write-Host "Total devices scanned: $totalDevicesScanned" -ForegroundColor Green
Write-Host "Total app records found: $($results.Count)" -ForegroundColor Green

# Calculate and display script execution time
$endTime = Get-Date
$duration = $endTime - $startTime
$hours = [math]::Floor($duration.TotalHours)
$minutes = [math]::Floor($duration.Minutes)
$seconds = [math]::Floor($duration.Seconds)
$timeFormat = "{0:00}:{1:00}:{2:00}" -f $hours, $minutes, $seconds

# Apply exclusion patterns if requested
if ($ExcludePatterns -and $results.Count -gt 0) {
    Write-Host "`nApplying exclusion patterns to filter out system/framework apps..." -ForegroundColor Yellow
    $originalCount = $results.Count
    
    # Filter out apps that match exclusion patterns
    $filteredResults = $results | Where-Object {
        $appName = $_.AppName
        $exclude = $false
        
        foreach ($pattern in $ExclusionPatterns) {
            if ($appName -like $pattern) {
                $exclude = $true
                break
            }
        }
        
        -not $exclude
    }
    
    $results = $filteredResults
    $removedCount = $originalCount - $results.Count
    
    Write-Host "Filtered from $originalCount to $($results.Count) entries" -ForegroundColor Green
    Write-Host "Removed $removedCount system/framework apps" -ForegroundColor Green
}

# Export to CSV if requested
if ($ExportToCSV) {
    # Determine which switch was used for filename
    $switchUsed = "AllOS"
    switch ($true) {
        $IOSOnly { $switchUsed = "IOSOnly"; break }
        $AndroidOnly { $switchUsed = "AndroidOnly"; break }
        $IOSAndAndroidOnly { $switchUsed = "IOSAndAndroidOnly"; break }
        $MacOSOnly { $switchUsed = "MacOSOnly"; break }
        $WindowsOnly { $switchUsed = "WindowsOnly"; break }
        default { $switchUsed = "AllOS"; break }
    }
    
    # Generate CSV filename with timestamp and switch
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvFileName = "IntuneAppDiscovery_${switchUsed}_${timestamp}.csv"
    $csvPath = Join-Path -Path (Get-Location) -ChildPath $csvFileName
    
    try {
        if ($results.Count -gt 0) {
            $results | Export-Csv -Path $csvPath -NoTypeInformation
            Write-Host "File saved to: $csvPath" -ForegroundColor Green
            Write-Host "Records exported: $($results.Count)" -ForegroundColor Green
        }
        else {
            Write-Host "`nNo results to export to CSV" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Error "Failed to export CSV: $_"
    }
}

Write-Host "`nScript execution completed!" -ForegroundColor Green
Write-Host "Total execution time: $timeFormat" -ForegroundColor Yellow    
$VerbosePreference = "SilentlyContinue"
