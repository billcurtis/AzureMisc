#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.DesktopVirtualization, Az.Compute

<#
.SYNOPSIS
    Migrates storage SKU for deallocated VMs in an Azure Virtual Desktop Host Pool

.DESCRIPTION
    This script connects to Azure, finds deallocated VMs in a specified AVD Host Pool,
    and changes their disk SKU to the target storage type using parallel processing.

.PARAMETER HostPoolName
    The name of the Azure Virtual Desktop Host Pool

.PARAMETER ResourceGroupName
    The resource group containing the Host Pool

.PARAMETER TargetStorageSKU
    The target storage SKU for the managed disks. Default is Premium_LRS (P10)

.PARAMETER ThrottleLimit
    Number of VMs to process in parallel. Default is 10

.EXAMPLE
    ./Update-StorageSKUbyHostPool.ps1 -HostPoolName "MyHostPool" -ResourceGroupName "MyRG"
    
.EXAMPLE
    ./Update-StorageSKUbyHostPool.ps1 -HostPoolName "MyHostPool" -ResourceGroupName "MyRG" -TargetStorageSKU "StandardSSD_LRS"

.NOTES
    Requires PowerShell 7.0+ and Azure PowerShell modules
    Run as an account with Contributor permissions on the VMs and Host Pool
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$HostPoolName,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("Premium_LRS", "StandardSSD_LRS", "Standard_LRS", "UltraSSD_LRS", "Premium_ZRS", "StandardSSD_ZRS")]
    [string]$TargetStorageSKU = "Premium_LRS",
    
    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 10
)

# Start timing the script execution
$startTime = Get-Date

# Set verbose preference
$VerbosePreference = "Continue"

Write-Verbose "=== Azure Virtual Desktop Storage Migration Script ===" 
Write-Verbose "Host Pool: $HostPoolName"
Write-Verbose "Resource Group: $ResourceGroupName"
Write-Verbose "Target Storage SKU: $TargetStorageSKU"
Write-Verbose "Parallel Processing Limit: $ThrottleLimit"
Write-Verbose "Script started at: $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"

# Function to connect to Azure
function Connect-ToAzure {
    Write-Verbose "Checking Azure connection..."
    
    try {
        # Check if already connected
        $context = Get-AzContext
        if ($context) {
            Write-Verbose "Already connected to Azure as: $($context.Account.Id)"
            Write-Verbose "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"
            return $true
        }
    }
    catch {
        Write-Verbose "No existing Azure connection found"
    }
    
    try {
        Write-Verbose "Connecting to Azure..."
        Connect-AzAccount -ErrorAction Stop
        
        $context = Get-AzContext
        Write-Verbose "Successfully connected to Azure as: $($context.Account.Id)"
        Write-Verbose "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"
        return $true
    }
    catch {
        Write-Error "Failed to connect to Azure: $($_.Exception.Message)"
        return $false
    }
}

# Function to get Host Pool information
function Get-HostPoolInfo {
    param(
        [string]$HostPoolName,
        [string]$ResourceGroupName
    )
    
    Write-Verbose "Retrieving Host Pool information..."
    
    try {
        $hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction Stop
        Write-Verbose "Found Host Pool: $($hostPool.Name)"
        Write-Verbose "Host Pool Type: $($hostPool.HostPoolType)"
        Write-Verbose "Load Balancer Type: $($hostPool.LoadBalancerType)"
        Write-Verbose "Max Session Limit: $($hostPool.MaxSessionLimit)"
        
        return $hostPool
    }
    catch {
        Write-Error "Failed to retrieve Host Pool '$HostPoolName' in resource group '$ResourceGroupName': $($_.Exception.Message)"
        throw
    }
}

# Function to get session hosts from Host Pool
function Get-SessionHosts {
    param(
        [string]$HostPoolName,
        [string]$ResourceGroupName
    )
    
    Write-Verbose "Retrieving session hosts from Host Pool..."
    
    try {
        $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction Stop
        Write-Verbose "Found $($sessionHosts.Count) session hosts in Host Pool"
        
        foreach ($sessionHost in $sessionHosts) {
            Write-Verbose "Session Host: $($sessionHost.Name) - Status: $($sessionHost.Status) - Sessions: $($sessionHost.Session)"
        }
        
        return $sessionHosts
    }
    catch {
        Write-Error "Failed to retrieve session hosts: $($_.Exception.Message)"
        throw
    }
}


# Function to get VM information and filter deallocated VMs
function Get-DeallocatedVMs {
    param(
        [array]$SessionHosts
    )
    
    Write-Verbose "Checking VM power states to find deallocated VMs..."
    
    $deallocatedVMs = @()
    
    foreach ($sessionHost in $SessionHosts) {
        # Extract VM name from session host name
        # Session host names can be in format: "hostpool/vmname" or "vmname.domain.com"
        $vmName = $sessionHost.Name
        
        Write-Verbose "Original session host name: $($sessionHost.Name)"
        
        # If it contains a forward slash, take the part after the slash
        if ($vmName -like "*/*") {
            $vmName = $vmName.Split('/')[-1]
            Write-Verbose "Found forward slash, extracted: $vmName"
        }
        
        # If it contains a dot (FQDN), take the part before the first dot
        if ($vmName -like "*.*") {
            $vmName = $vmName.Split('.')[0]
            Write-Verbose "Found dot, extracted: $vmName"
        }
        
        Write-Verbose "Processing session host: $($sessionHost.Name) -> VM name: $vmName"
        
        # Validate that we have a clean VM name
        if ([string]::IsNullOrEmpty($vmName) -or $vmName -eq $sessionHost.Name) {
            Write-Warning "Could not extract valid VM name from session host '$($sessionHost.Name)'. Skipping."
            continue
        }
        
        try {
            # Try to find the VM - first attempt without specifying resource group
            $vm = $null
            $vmResourceGroup = $null
            
            try {
                $vm = Get-AzVM -Name $vmName -ErrorAction Stop
                $vmResourceGroup = $vm.ResourceGroupName
                Write-Verbose "Found VM '$vmName' in resource group: $vmResourceGroup"
            }
            catch {
                # If VM not found with simple name, try searching across all resource groups
                Write-Verbose "VM '$vmName' not found with simple lookup, searching across resource groups..."
                $allVMs = Get-AzVM | Where-Object { $_.Name -eq $vmName }
                
                if ($allVMs.Count -eq 1) {
                    $vm = $allVMs[0]
                    $vmResourceGroup = $vm.ResourceGroupName
                    Write-Verbose "Found VM '$vmName' in resource group: $vmResourceGroup"
                }
                elseif ($allVMs.Count -gt 1) {
                    Write-Warning "Multiple VMs found with name '$vmName' in different resource groups. Skipping."
                    continue
                }
                else {
                    Write-Warning "No VM found with name '$vmName'. Skipping session host '$($sessionHost.Name)'."
                    continue
                }
            }
            
            # Validate that we have both VM and resource group
            if ($null -eq $vm -or [string]::IsNullOrEmpty($vmResourceGroup)) {
                Write-Warning "Failed to get valid VM or resource group information for '$vmName'. Skipping."
                continue
            }
            
            # Get VM power state
            $vmStatus = Get-AzVM -ResourceGroupName $vmResourceGroup -Name $vmName -Status -ErrorAction Stop
            $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
            
            Write-Verbose "VM: $vmName - Resource Group: $vmResourceGroup - Power State: $powerState"
            
            if ($powerState -eq "VM deallocated") {
                $deallocatedVMs += [PSCustomObject]@{
                    VMName = $vmName
                    ResourceGroupName = $vmResourceGroup
                    SessionHostName = $sessionHost.Name
                    VM = $vm
                }
                Write-Verbose "✓ VM '$vmName' is deallocated and will be processed"
            }
            else {
                Write-Verbose "- VM '$vmName' is not deallocated (State: $powerState) - skipping"
            }
        }
        catch {
            Write-Warning "Failed to get VM information for '$vmName' (from session host '$($sessionHost.Name)'): $($_.Exception.Message)"
        }
    }
    
    Write-Verbose "Found $($deallocatedVMs.Count) deallocated VMs ready for storage migration"
    return $deallocatedVMs
}

# Function to migrate VM disk storage
function Invoke-StorageMigration {
    param(
        [array]$DeallocatedVMs,
        [string]$TargetStorageSKU,
        [int]$ThrottleLimit
    )
    
    if ($DeallocatedVMs.Count -eq 0) {
        Write-Verbose "No deallocated VMs found. Nothing to migrate."
        return
    }
    
    Write-Verbose "Starting parallel storage migration for $($DeallocatedVMs.Count) VMs..."
    Write-Verbose "Processing $ThrottleLimit VMs in parallel"
    
    $results = $DeallocatedVMs | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $vm = $_.VM
        $vmName = $_.VMName
        $resourceGroup = $_.ResourceGroupName
        $targetSKU = $using:TargetStorageSKU
        
        # Import required modules in parallel runspace
        Import-Module Az.Compute -Force
        
        $result = [PSCustomObject]@{
            VMName = $vmName
            ResourceGroup = $resourceGroup
            Success = $false
            Message = ""
            DisksProcessed = 0
            OriginalSKUs = @()
            NewSKUs = @()
        }
        
        try {
            Write-Verbose "[$vmName] Starting storage migration to $targetSKU"
            
            # Get all disks attached to the VM
            $disks = @()
            
            # OS Disk
            if ($vm.StorageProfile.OsDisk.ManagedDisk) {
                $osDisk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $vm.StorageProfile.OsDisk.Name
                $disks += $osDisk
                Write-Verbose "[$vmName] Found OS Disk: $($osDisk.Name) - Current SKU: $($osDisk.Sku.Name)"
            }
            
            # Data Disks
            foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
                if ($dataDisk.ManagedDisk) {
                    $disk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName $dataDisk.Name
                    $disks += $disk
                    Write-Verbose "[$vmName] Found Data Disk: $($disk.Name) - Current SKU: $($disk.Sku.Name)"
                }
            }
            
            # Process each disk
            foreach ($disk in $disks) {
                $originalSKU = $disk.Sku.Name
                $result.OriginalSKUs += "$($disk.Name):$originalSKU"
                
                if ($originalSKU -eq $targetSKU) {
                    Write-Verbose "[$vmName] Disk '$($disk.Name)' already has target SKU '$targetSKU' - skipping"
                    $result.NewSKUs += "$($disk.Name):$originalSKU (unchanged)"
                    continue
                }
                
                Write-Verbose "[$vmName] Migrating disk '$($disk.Name)' from '$originalSKU' to '$targetSKU'"
                
                # Update disk SKU
                $disk.Sku = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new($targetSKU)
                $updateResult = $disk | Update-AzDisk
                
                Write-Verbose "[$vmName] Successfully migrated disk '$($disk.Name)' to '$targetSKU'"
                $result.NewSKUs += "$($disk.Name):$targetSKU"
                $result.DisksProcessed++
            }
            
            $result.Success = $true
            $result.Message = "Successfully migrated $($result.DisksProcessed) disks to $targetSKU"
            Write-Verbose "[$vmName] ✓ Storage migration completed successfully"
            
        }
        catch {
            $result.Success = $false
            $result.Message = "Failed: $($_.Exception.Message)"
            Write-Warning "[$vmName] ✗ Storage migration failed: $($_.Exception.Message)"
        }
        
        return $result
    }
    
    return $results
}

# Function to display migration results
function Show-MigrationResults {
    param(
        [array]$Results
    )
    
    Write-Verbose "`n========== Migration Results =========="
    
    $successCount = ($Results | Where-Object { $_.Success }).Count
    $failedCount = ($Results | Where-Object { -not $_.Success }).Count
    $totalDisks = ($Results | Measure-Object -Property DisksProcessed -Sum).Sum
    
    Write-Verbose "Total VMs Processed: $($Results.Count)"
    Write-Verbose "Successful Migrations: $successCount"
    Write-Verbose "Failed Migrations: $failedCount"
    Write-Verbose "Total Disks Migrated: $totalDisks"
    
    Write-Verbose "`n--- Detailed Results ---"
    foreach ($result in $Results) {
        $status = if ($result.Success) { "✓ SUCCESS" } else { "✗ FAILED" }
        Write-Verbose "[$($result.VMName)] $status - $($result.Message)"
        
        if ($result.OriginalSKUs.Count -gt 0) {
            Write-Verbose "  Original SKUs: $($result.OriginalSKUs -join ', ')"
            Write-Verbose "  New SKUs: $($result.NewSKUs -join ', ')"
        }
    }
}

# Main execution
try {
    # Step 1: Connect to Azure
    if (-not (Connect-ToAzure)) {
        throw "Failed to connect to Azure"
    }
    
    # Step 2: Get Host Pool information
    $hostPool = Get-HostPoolInfo -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName
    
    # Step 3: Get session hosts
    $sessionHosts = Get-SessionHosts -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName
    
    if ($sessionHosts.Count -eq 0) {
        Write-Warning "No session hosts found in Host Pool '$HostPoolName'"
        exit 0
    }
    
    # Step 4: Get deallocated VMs
    $deallocatedVMs = Get-DeallocatedVMs -SessionHosts $sessionHosts
    
    if ($deallocatedVMs.Count -eq 0) {
        Write-Verbose "No deallocated VMs found. All VMs are either running or in other states."
        Write-Verbose "Only deallocated VMs can have their storage migrated safely."
        exit 0
    }
    
    # Step 5: Migrate storage for deallocated VMs
    $migrationResults = Invoke-StorageMigration -DeallocatedVMs $deallocatedVMs -TargetStorageSKU $TargetStorageSKU -ThrottleLimit $ThrottleLimit
    
    # Step 6: Display results
    Show-MigrationResults -Results $migrationResults
    
}
catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    exit 1
}
finally {
    # Calculate and display execution time
    $endTime = Get-Date
    $duration = $endTime - $startTime
    $hours = [math]::Floor($duration.TotalHours)
    $minutes = [math]::Floor($duration.Minutes)
    $seconds = [math]::Floor($duration.Seconds)
    $timeFormat = "{0:00}:{1:00}:{2:00}" -f $hours, $minutes, $seconds
    
    Write-Verbose "`nScript execution completed!"
    Write-Verbose "Total execution time: $timeFormat"
    Write-Verbose "Script ended at: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
}