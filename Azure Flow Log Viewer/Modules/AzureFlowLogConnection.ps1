#Requires -Version 5.1
<#
.SYNOPSIS
    Azure Flow Log Connection Module
.DESCRIPTION
    Handles connection to Azure Storage Account and retrieval of flow log blobs
#>

# Helper function to download blob with timeout using a background job
function Get-BlobContentWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        $Blob,
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,
        [Parameter(Mandatory = $true)]
        $StorageContext,
        [int]$TimeoutSeconds = 60
    )
    
    $tempFile = [System.IO.Path]::GetTempFileName()
    
    try {
        # Try direct download first using BlobClient (newer SDK)
        if ($Blob.BlobClient) {
            try {
                $response = $Blob.BlobClient.DownloadContent()
                $content = $response.Value.Content.ToString()
                return @{ Success = $true; Content = $content; TempFile = $null }
            }
            catch {
                # Fall through to file-based download
            }
        }
        
        # Try ICloudBlob (older SDK)
        if ($Blob.ICloudBlob) {
            try {
                $memStream = New-Object System.IO.MemoryStream
                $Blob.ICloudBlob.DownloadToStream($memStream)
                $memStream.Position = 0
                $reader = New-Object System.IO.StreamReader($memStream)
                $content = $reader.ReadToEnd()
                $reader.Close()
                $memStream.Close()
                return @{ Success = $true; Content = $content; TempFile = $null }
            }
            catch {
                # Fall through to file-based download
            }
        }
        
        # Fallback: Use cmdlet to download to file
        $null = Get-AzStorageBlobContent -Container $ContainerName -Blob $Blob.Name -Destination $tempFile -Context $StorageContext -Force -ErrorAction Stop
        $content = Get-Content -Path $tempFile -Raw -ErrorAction Stop
        return @{ Success = $true; Content = $content; TempFile = $tempFile }
    }
    catch {
        return @{ Success = $false; Error = $_.Exception.Message; TempFile = $tempFile }
    }
}

function Connect-ToAzureStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorageAccountName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )
    
    try {
        # Check if Az module is installed
        if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
            return @{
                Success = $false
                Error = "Az.Storage module is not installed. Please run: Install-Module -Name Az -Scope CurrentUser"
            }
        }
        
        # Import Az.Storage module
        Import-Module Az.Storage -ErrorAction Stop
        Import-Module Az.Accounts -ErrorAction Stop
        
        # Check if already connected to Azure
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $context) {
            # Connect to Azure
            Connect-AzAccount -ErrorAction Stop
            $context = Get-AzContext
        }
        
        # Verify access to storage account
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
        
        if ($storageAccount) {
            # Try storage account key first (requires key operator or contributor role)
            $useRBAC = $false
            $authMethod = "Unknown"
            
            try {
                $keys = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
                
                if ($keys -and $keys.Count -gt 0) {
                    # Use storage account key for authentication
                    $script:StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $keys[0].Value
                    $authMethod = "StorageKey"
                    
                    # Test the connection by listing containers
                    $null = Get-AzStorageContainer -Context $script:StorageContext -MaxCount 1 -ErrorAction Stop
                }
                else {
                    $useRBAC = $true
                }
            }
            catch {
                # Key access failed, fall back to RBAC
                Write-Verbose "Storage key access failed: $($_.Exception.Message). Falling back to RBAC."
                $useRBAC = $true
            }
            
            if ($useRBAC) {
                try {
                    # Fallback to Azure AD/RBAC authentication (requires Storage Blob Data Reader role)
                    $script:StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
                    $authMethod = "RBAC"
                    
                    # Test the connection by listing containers
                    $null = Get-AzStorageContainer -Context $script:StorageContext -MaxCount 1 -ErrorAction Stop
                }
                catch {
                    return @{
                        Success = $false
                        Error = "Authentication failed. Tried both storage key and RBAC methods.`n`nFor storage key access: Need 'Storage Account Key Operator' or 'Contributor' role on storage account.`n`nFor RBAC access: Need 'Storage Blob Data Reader' role on storage account.`n`nError: $($_.Exception.Message)"
                    }
                }
            }
            
            return @{
                Success = $true
                StorageAccount = $storageAccount
                Context = $script:StorageContext
                AuthMethod = $authMethod
            }
        }
        else {
            return @{
                Success = $false
                Error = "Storage account not found"
            }
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-FlowLogBlobs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorageAccountName,
        
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$StartDate,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$EndDate
    )
    
    try {
        # Ensure we have a storage context
        if (-not $script:StorageContext) {
            $connection = Connect-ToAzureStorage -StorageAccountName $StorageAccountName -ResourceGroupName $ResourceGroupName
            if (-not $connection.Success) {
                throw $connection.Error
            }
        }
        
        # Keep UI responsive
        if ([System.Windows.Forms.Application]) {
            [System.Windows.Forms.Application]::DoEvents()
        }
        
        # Get all blobs in the container
        $allBlobs = @(Get-AzStorageBlob -Container $ContainerName -Context $script:StorageContext -ErrorAction Stop)
        
        # Keep UI responsive
        if ([System.Windows.Forms.Application]) {
            [System.Windows.Forms.Application]::DoEvents()
        }
        
        # Flow log blobs are organized by date in the path
        # Pattern: resourceId=/SUBSCRIPTIONS/{subId}/RESOURCEGROUPS/{rg}/PROVIDERS/MICROSOFT.NETWORK/NETWORKWATCHERS/{nw}/FLOWLOGS/{fl}/y={year}/m={month}/d={day}/h={hour}/m={minute}/macAddress={mac}/PT1H.json
        
        $filteredBlobs = [System.Collections.ArrayList]@()
        $count = 0
        
        foreach ($blob in $allBlobs) {
            $count++
            # Keep UI responsive every 50 blobs
            if ($count % 50 -eq 0 -and [System.Windows.Forms.Application]) {
                [System.Windows.Forms.Application]::DoEvents()
            }
            
            # Extract date from blob path
            $blobDate = Get-DateFromBlobPath -BlobPath $blob.Name
            
            if ($blobDate -and $blobDate -ge $StartDate.Date -and $blobDate -le $EndDate.Date.AddDays(1)) {
                $null = $filteredBlobs.Add($blob)
            }
        }
        
        return @($filteredBlobs)
    }
    catch {
        Write-Error "Error getting flow log blobs: $_"
        return @()
    }
}

function Get-DateFromBlobPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BlobPath
    )
    
    try {
        # Extract year, month, day from path - support multiple formats
        
        # Format 1: y=2024/m=01/d=15/h=10
        if ($BlobPath -match 'y=(\d{4})/m=(\d{2})/d=(\d{2})') {
            $year = [int]$Matches[1]
            $month = [int]$Matches[2]
            $day = [int]$Matches[3]
            return Get-Date -Year $year -Month $month -Day $day -Hour 0 -Minute 0 -Second 0
        }
        
        # Format 2: year=2024/month=01/day=15
        if ($BlobPath -match 'year=(\d{4})/month=(\d{2})/day=(\d{2})') {
            $year = [int]$Matches[1]
            $month = [int]$Matches[2]
            $day = [int]$Matches[3]
            return Get-Date -Year $year -Month $month -Day $day -Hour 0 -Minute 0 -Second 0
        }
        
        # Format 3: /2024/01/15/ (date segments in path)
        if ($BlobPath -match '/(\d{4})/(\d{2})/(\d{2})/') {
            $year = [int]$Matches[1]
            $month = [int]$Matches[2]
            $day = [int]$Matches[3]
            return Get-Date -Year $year -Month $month -Day $day -Hour 0 -Minute 0 -Second 0
        }
        
        return $null
    }
    catch {
        return $null
    }
}

function Get-FlowLogData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorageAccountName,
        
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$StartDate,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$EndDate,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )
    
    try {
        # Ensure we have a storage context
        if (-not $script:StorageContext) {
            $connection = Connect-ToAzureStorage -StorageAccountName $StorageAccountName -ResourceGroupName $ResourceGroupName
            if (-not $connection.Success) {
                throw $connection.Error
            }
        }
        
        # Get filtered blobs
        $blobs = Get-FlowLogBlobs -StorageAccountName $StorageAccountName `
                                   -ContainerName $ContainerName `
                                   -ResourceGroupName $ResourceGroupName `
                                   -StartDate $StartDate `
                                   -EndDate $EndDate
        
        if ($null -eq $blobs -or $blobs.Count -eq 0) {
            Write-Warning "No blobs found for the specified date range"
            return @()
        }
        
        Write-Host "Found $($blobs.Count) flow log files to process"
        
        $allFlowRecords = [System.Collections.ArrayList]@()
        $processedCount = 0
        $totalBlobs = @($blobs).Count
        
        foreach ($blob in $blobs) {
            $processedCount++
            
            # Update status and keep UI responsive
            if ($script:StatusLabel) {
                $script:StatusLabel.Text = "Downloading blob $processedCount of $totalBlobs..."
            }
            if ([System.Windows.Forms.Application]) {
                [System.Windows.Forms.Application]::DoEvents()
            }
            
            try {
                # Download blob content using helper function
                $downloadResult = Get-BlobContentWithTimeout -Blob $blob -ContainerName $ContainerName -StorageContext $script:StorageContext
                
                # Keep UI responsive after download
                if ([System.Windows.Forms.Application]) {
                    [System.Windows.Forms.Application]::DoEvents()
                }
                
                if (-not $downloadResult.Success) {
                    Write-Warning "Failed to download blob $($blob.Name): $($downloadResult.Error)"
                    continue
                }
                
                $jsonText = $downloadResult.Content
                
                # Clean up temp file if one was created
                if ($downloadResult.TempFile -and (Test-Path $downloadResult.TempFile)) {
                    Remove-Item -Path $downloadResult.TempFile -Force -ErrorAction SilentlyContinue
                }
                
                # Parse the JSON content
                $jsonContent = $jsonText | ConvertFrom-Json -ErrorAction Stop
                
                # Keep UI responsive during parsing
                if ([System.Windows.Forms.Application]) {
                    [System.Windows.Forms.Application]::DoEvents()
                }
                
                # Parse flow records
                $records = Parse-FlowLogJson -JsonContent $jsonContent -BlobPath $blob.Name
                if ($records -and $records.Count -gt 0) {
                    foreach ($record in $records) {
                        $null = $allFlowRecords.Add($record)
                    }
                }
                
                # Update status with record count
                if ($script:StatusLabel) {
                    $script:StatusLabel.Text = "Processed $processedCount of $totalBlobs blobs ($($allFlowRecords.Count) records)..."
                }
            }
            catch {
                Write-Warning "Error processing blob $($blob.Name): $($_.Exception.Message)"
            }
            
            # Keep UI responsive between blobs
            if ([System.Windows.Forms.Application]) {
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        
        # Filter by exact date range (including time)
        if ($allFlowRecords.Count -gt 0) {
            $filteredRecords = @($allFlowRecords | Where-Object {
                $_.Timestamp -ge $StartDate -and $_.Timestamp -le $EndDate
            })
            return $filteredRecords
        }
        else {
            return @()
        }
    }
    catch {
        Write-Error "Error getting flow log data: $($_.Exception.Message)"
        return @()
    }
}

function Get-FlowLogDataFromLocalFiles {
    <#
    .SYNOPSIS
        Load flow log data from local JSON files (for testing/offline use)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$StartDate,
        
        [Parameter(Mandatory = $true)]
        [DateTime]$EndDate
    )
    
    try {
        $jsonFiles = Get-ChildItem -Path $FolderPath -Filter "*.json" -Recurse
        
        $allFlowRecords = @()
        
        foreach ($file in $jsonFiles) {
            try {
                $jsonContent = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                $records = Parse-FlowLogJson -JsonContent $jsonContent -BlobPath $file.Name
                $allFlowRecords += $records
            }
            catch {
                Write-Warning "Error processing file $($file.Name): $_"
            }
        }
        
        # Filter by date range
        $filteredRecords = $allFlowRecords | Where-Object {
            $_.Timestamp -ge $StartDate -and $_.Timestamp -le $EndDate
        }
        
        return $filteredRecords
    }
    catch {
        Write-Error "Error loading local flow log files: $_"
        return @()
    }
}
