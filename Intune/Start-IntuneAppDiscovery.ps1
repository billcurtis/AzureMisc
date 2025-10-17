#Requires -Version 7.0

    <#
.DESCRIPTION
    This script retrieves all managed iOS and Android devices from Microsoft Intune via Microsoft Graph API,
    then fetches the list of installed applications for each device, handling rate limits with retries and backoff. 

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

.EXAMPLE
    # Get all Windows devices, exclude system apps, and export to CSV
    ./Start-IntuneAppDiscovery.ps1 -WindowsOnly -ExcludePatterns -ExportToCSV 

    # GGet only iOS and Android devices and export to CSV
    ./Start-IntuneAppDiscovery.ps1 -IOSAndAndroidOnly -ExportToCSV

    # Get all devices but exclude system apps
    ./Start-IntuneAppDiscovery.ps1 -ExcludePatterns

    # Normal run without filtering
    ./Start-IntuneAppDiscovery.ps1 -ExportToCSV

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
    [switch]$ExcludePatterns
)


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

    $clientId = "<client_id>"
    $clientSecret = "<client_secret>"
    $tenantId = "<tenant_id>"

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
                
                # Handle authentication errors (401 Unauthorized)
                if ($_.Exception.Response.StatusCode -eq 401) {
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
                if ($_.Exception.Response.StatusCode -eq 429 -or $_.Exception.Message -like "*TooManyRequests*") {                
                    if ($retryCount -le $MaxRetries) {
                        # Get Retry-After header if available, otherwise use exponential backoff
                        $retryAfter = 30 # Default
                        if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers["Retry-After"]) {
                            $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"]
                        }
                        else {
                            $retryAfter = [Math]::Pow(2, $retryCount) * 10 # 10s, 20s, 40s
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
        
            # Build URI with appropriate OS filter based on switches
            $baseUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices"
            $filter = ""
        
            switch ($true) {
                $IOSOnly { 
                    $filter = "`?`$filter=operatingSystem eq 'iOS'"
                    Write-Host "Filtering for iOS devices only..." -ForegroundColor Cyan
                    break 
                }
                $AndroidOnly { 
                    $filter = "`?`$filter=operatingSystem eq 'Android'"
                    Write-Host "Filtering for Android devices only..." -ForegroundColor Cyan
                    break 
                }
                $IOSAndAndroidOnly { 
                    $filter = "`?`$filter=operatingSystem eq 'iOS' or operatingSystem eq 'Android'"
                    Write-Host "Filtering for iOS and Android devices only..." -ForegroundColor Cyan
                    break 
                }
                $MacOSOnly { 
                    $filter = "`?`$filter=operatingSystem eq 'macOS'"
                    Write-Host "Filtering for macOS devices only..." -ForegroundColor Cyan
                    break 
                }
                $WindowsOnly { 
                    $filter = "`?`$filter=operatingSystem eq 'Windows'"
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
        
            $uri = $baseUri + $filter
        
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

    $devices = Get-AllManagedDevices

    #get the time for end time
    $endTime = Get-Date

    #Get access token
    $accessToken = Get-ValidToken

    Write-Host "Starting parallel processing of $($devices.Count) devices with throttle limit of 3..." -ForegroundColor Green
    Write-Host "This may take some time due to rate limiting controls..." -ForegroundColor Yellow

    # iterate through each device in $devices using foreach-object -Parallel get all app information for that device
    $results = @()
    $results += $devices | ForEach-Object -ThrottleLimit 3 -Parallel {
        
        # Add small random delay to stagger requests
        Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)
    
        #functions
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
                    $statusCode = $null
                    $errorMessage = $_.Exception.Message
                    
                    # Try to get status code from different possible locations
                    if ($_.Exception.Response.StatusCode) {
                        $statusCode = $_.Exception.Response.StatusCode.value__
                    }
                    elseif ($_.Exception.Message -match 'HTTP\s+(\d+)') {
                        $statusCode = [int]$matches[1]
                    }
                    
                    # Handle rate limit errors (429 TooManyRequests)
                    if ($statusCode -eq 429 -or $errorMessage -like "*TooManyRequests*" -or $errorMessage -like "*throttled*") {
                        $retryCount++
                    
                        if ($retryCount -le $MaxRetries) {
                            # Get Retry-After header if available, otherwise use exponential backoff
                            $retryAfter = 30 # Default 30 seconds
                            if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers["Retry-After"]) {
                                $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"]
                            }
                            else {
                                $retryAfter = [Math]::Pow(2, $retryCount) * 15 # 30s, 60s, 120s, 240s, 480s
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
                    $apps += $response.value
                    $uri = $response.'@odata.nextLink'
                } while ($uri)
        
                return $apps
            }
            catch {
                # If detectedApps fails, try alternative approach with installed apps
                try {
                    Write-Error $_
                    Write-Warning "DetectedApps not available for $DeviceName, trying alternative method..."
                    $accessToken = $using:accessToken
                    $headers = @{
                        Authorization = "Bearer $accessToken"
                    }
                    # Try getting apps through assignments
                    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$DeviceId')?`$select=id,deviceName,userId&`$expand=users(`$select=id)"
                    $deviceInfo = Invoke-GraphRequestWithRetry -Uri $uri -Headers $headers
            
                    # Get app install status for this device
                    $uri = "https://graph.microsoft.com/beta/deviceManagement/reports/getDeviceInstallStatusReport"
                    $body = @{
                        filter = "(DeviceId eq '$DeviceId')"
                        select = @("ApplicationId", "AppInstallState", "AppVersion", "DisplayName")
                        skip   = 0
                        top    = 1000
                    } | ConvertTo-Json
            
                    $response = Invoke-GraphRequestWithRetry -Uri $uri -Headers $headers -Method "POST" -Body $body
            
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
    
        Write-Host -Message "Found $($dAppresults.Count) apps for device: $deviceName"
        return $dAppresults
    }

Write-Host "`nParallel processing completed! Collected data from $($devices.Count) devices." -ForegroundColor Green
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
        } else {
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
