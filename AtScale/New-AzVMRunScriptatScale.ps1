#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.DesktopVirtualization, Az.Compute

<#
.SYNOPSIS
    Executes a PowerShell script asynchronously on running VMs in an Azure Virtual Desktop Host Pool

.DESCRIPTION
    This script connects to Azure, finds running VMs in a specified AVD Host Pool,
    and executes a specified PowerShell script on them using Invoke-AzVMRunCommand in fire-and-forget mode.
    The script does not wait for execution results and moves on immediately after starting each job.

.PARAMETER HostPoolName
    The name of the Azure Virtual Desktop Host Pool

.PARAMETER ResourceGroupName
    The resource group containing the Host Pool

.PARAMETER ScriptPath
    The path to the PowerShell script file to execute on the VMs

.PARAMETER ScriptContent
    The PowerShell script content to execute (alternative to ScriptPath)

.PARAMETER ScriptParameters
    Hashtable of parameters to pass to the script

.PARAMETER ThrottleLimit
    Number of VMs to process in parallel. Default is 50 (increased for async mode)

.PARAMETER DelayBetweenJobs
    Delay in milliseconds between starting each job. Default is 100ms

.EXAMPLE
    ./New-AzVMRunScriptatScale.ps1 -HostPoolName "MyHostPool" -ResourceGroupName "MyRG" -ScriptPath "C:\Scripts\HealthCheck.ps1"
    
.EXAMPLE
    ./New-AzVMRunScriptatScale.ps1 -HostPoolName "MyHostPool" -ResourceGroupName "MyRG" -ScriptContent "Get-Service | Where-Object {$_.Status -eq 'Running'}"

.EXAMPLE
    ./New-AzVMRunScriptatScale.ps1 -HostPoolName "MyHostPool" -ResourceGroupName "MyRG" -ScriptPath "C:\Scripts\Update.ps1" -ScriptParameters @{UpdateType="Critical"}

.NOTES
    Requires PowerShell 7.0+ and Azure PowerShell modules
    Run as an account with Contributor permissions on the VMs and Host Pool
    This script runs in fire-and-forget mode - no results are collected or displayed
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$HostPoolName,
    
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$ScriptPath,
    
    [Parameter(Mandatory = $false)]
    [string]$ScriptContent,
    
    [Parameter(Mandatory = $false)]
    [hashtable]$ScriptParameters = @{},
    
    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 50,
    
    [Parameter(Mandatory = $false)]
    [int]$DelayBetweenJobs = 100
)

# Validate parameters
if ([string]::IsNullOrEmpty($ScriptPath) -and [string]::IsNullOrEmpty($ScriptContent)) {
    throw "Either ScriptPath or ScriptContent must be provided"
}

if (![string]::IsNullOrEmpty($ScriptPath) -and ![string]::IsNullOrEmpty($ScriptContent)) {
    throw "Provide either ScriptPath or ScriptContent, not both"
}

# Start timing the script execution
$startTime = Get-Date

# Set verbose preference
$VerbosePreference = "Continue"

Write-Verbose "=== Azure VM PowerShell Script Execution at Scale (Async Mode) ===" 
Write-Verbose "Host Pool: $HostPoolName"
Write-Verbose "Resource Group: $ResourceGroupName"
Write-Verbose "Script Path: $ScriptPath"
Write-Verbose "Script Content Length: $($ScriptContent.Length) characters"
Write-Verbose "Script Parameters: $($ScriptParameters.Count) parameters"
Write-Verbose "Parallel Processing Limit: $ThrottleLimit"
Write-Verbose "Delay Between Jobs: $DelayBetweenJobs ms"
Write-Verbose "Mode: Fire-and-Forget (No result collection)"
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

# Function to get VM information and filter running VMs
function Get-RunningVMs {
    param(
        [array]$SessionHosts,
        [string]$tenantId
    )
    
    Write-Verbose "Checking VM power states to find running VMs..."
    
    $runningVMs = @()
    
    foreach ($sessionHost in $SessionHosts) {
        # Extract VM information from session host
        $vmResID = $sessionHost.ResourceId
        $vmSuBID = ($vmResID.Split('/'))[2]
        $vmName = ($vmResID.Split('/'))[-1]
        
        # Set context to the subscription of the VM
        Write-Verbose "Setting context to Subscription ID: $vmSuBID"
        Set-AzContext -SubscriptionId $vmSuBID -TenantId $tenantId | Out-Null

        try {
            # Get VM information
            $vm = $null
            $vmResourceGroup = $null
            
            try {
                $vm = Get-AzVM -ResourceId $vmResID -ErrorAction Stop
                $vmResourceGroup = $vm.ResourceGroupName
                Write-Verbose "Found VM '$vmName' in resource group: $vmResourceGroup"
            }
            catch {
                # If VM not found with resource ID, try searching across all resource groups
                Write-Verbose "VM '$vmName' not found with resource ID, searching across resource groups..."
                $allVMs = Get-AzVM | Where-Object { $_.id -eq $vmResID }
                
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
            $vmStatus = Get-AzVM -ResourceId $vmResID -Status -ErrorAction Stop
            $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
            
            Write-Verbose "VM: $vmName - Resource Group: $vmResourceGroup - Power State: $powerState"
            
            if ($powerState -eq "VM running") {
                $runningVMs += [PSCustomObject]@{
                    VMName            = $vmName
                    ResourceGroupName = $vmResourceGroup
                    SessionHostName   = $sessionHost.Name
                    VM                = $vm
                    VMSubscriptionId  = $vmSuBID
                    SessionHostStatus = $sessionHost.Status
                    ActiveSessions    = $sessionHost.Session
                }
                Write-Verbose "✓ VM '$vmName' is running and will be processed"
            }
            else {
                Write-Verbose "- VM '$vmName' is not running (State: $powerState) - skipping"
            }
        }
        catch {
            Write-Warning "Failed to get VM information for '$vmName' (from session host '$($sessionHost.Name)'): $($_.Exception.Message)"
        }
    }
    
    Write-Verbose "Found $($runningVMs.Count) running VMs ready for script execution"
    return $runningVMs
}

# Function to prepare script content
function Get-ScriptToExecute {
    param(
        [string]$ScriptPath,
        [string]$ScriptContent
    )
    
    if (![string]::IsNullOrEmpty($ScriptPath)) {
        if (Test-Path $ScriptPath) {
            $content = Get-Content $ScriptPath -Raw
            Write-Verbose "Loaded script from file: $ScriptPath ($($content.Length) characters)"
            return $content
        }
        else {
            throw "Script file not found: $ScriptPath"
        }
    }
    else {
        Write-Verbose "Using provided script content ($($ScriptContent.Length) characters)"
        return $ScriptContent
    }
}

# Function to start async script execution without waiting
function Start-AsyncScriptExecution {
    param(
        [array]$RunningVMs,
        [string]$ScriptToExecute,
        [hashtable]$ScriptParameters,
        [int]$ThrottleLimit,
        [int]$DelayBetweenJobs,
        [string]$TenantId
    )
    
    if ($RunningVMs.Count -eq 0) {
        Write-Verbose "No running VMs found. Nothing to execute."
        return
    }
    
    Write-Verbose "Starting asynchronous script execution on $($RunningVMs.Count) VMs..."
    Write-Verbose "Processing up to $ThrottleLimit VMs in parallel (fire-and-forget mode)"
    
    $jobCount = 0
    $activeJobs = @()
    $processedVMs = @()
    
    foreach ($vmInfo in $RunningVMs) {
        # Throttle control - wait if we have too many active jobs
        while ($activeJobs.Count -ge $ThrottleLimit) {
            # Clean up completed jobs without collecting results
            $completedJobs = $activeJobs | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' -or $_.State -eq 'Stopped' }
            foreach ($completedJob in $completedJobs) {
                Remove-Job -Job $completedJob -Force
                $activeJobs = $activeJobs | Where-Object { $_.Id -ne $completedJob.Id }
            }
            
            if ($activeJobs.Count -ge $ThrottleLimit) {
                Start-Sleep -Milliseconds 50  # Brief pause before checking again
            }
        }
        
        # Start job for this VM
        $job = Start-Job -ScriptBlock {
            param($vmName, $resourceGroup, $subscriptionId, $script, $parameters, $tenantId)
            
            try {
                # Import required modules
                Import-Module Az.Compute -Force
                
                # Set context for this VM's subscription
                Set-AzContext -SubscriptionId $subscriptionId -TenantId $tenantId | Out-Null
                
                # Prepare run command parameters
                $runCommandParams = @{
                    ResourceGroupName = $resourceGroup
                    VMName            = $vmName
                    CommandId         = "RunPowerShellScript"
                    ScriptString      = $script
                }
                
                # Add script parameters if provided
                if ($parameters.Count -gt 0) {
                    $parameterArray = @()
                    foreach ($key in $parameters.Keys) {
                        $parameterArray += @{
                            Name  = $key
                            Value = $parameters[$key].ToString()
                        }
                    }
                    $runCommandParams.Parameter = $parameterArray
                }
                
                # Execute the script (this runs async on the VM)
                $result = Invoke-AzVMRunCommand @runCommandParams
                
                # Return minimal success indicator
                return @{
                    VMName = $vmName
                    Success = $true
                    StartedAt = Get-Date
                }
                
            }
            catch {
                # Return minimal error indicator
                return @{
                    VMName = $vmName
                    Success = $false
                    Error = $_.Exception.Message
                    StartedAt = Get-Date
                }
            }
        } -ArgumentList $vmInfo.VMName, $vmInfo.ResourceGroupName, $vmInfo.VMSubscriptionId, $ScriptToExecute, $ScriptParameters, $TenantId
        
        $activeJobs += $job
        $jobCount++
        $processedVMs += $vmInfo.VMName
        
        Write-Verbose "[$($vmInfo.VMName)] Job started ($jobCount/$($RunningVMs.Count))"
        
        # Small delay between job starts to avoid overwhelming the system
        if ($DelayBetweenJobs -gt 0) {
            Start-Sleep -Milliseconds $DelayBetweenJobs
        }
    }
    
    Write-Verbose "`n========== Job Startup Summary =========="
    Write-Verbose "Total VMs Processed: $($RunningVMs.Count)"
    Write-Verbose "Jobs Started: $jobCount"
    Write-Verbose "Active Jobs Remaining: $($activeJobs.Count)"
    Write-Verbose "Mode: Fire-and-Forget (Jobs continue running in background)"
    
    # Optional: Clean up any remaining completed jobs without collecting results
    Write-Verbose "`nCleaning up any immediately completed jobs..."
    $immediatelyCompleted = $activeJobs | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' -or $_.State -eq 'Stopped' }
    foreach ($completedJob in $immediatelyCompleted) {
        Write-Verbose "Job for VM completed immediately: $($completedJob.Name)"
        Remove-Job -Job $completedJob -Force
    }
    
    $remainingJobs = $activeJobs | Where-Object { $_.State -eq 'Running' }
    Write-Verbose "Jobs still running in background: $($remainingJobs.Count)"
    
    return @{
        TotalVMs = $RunningVMs.Count
        JobsStarted = $jobCount
        ProcessedVMs = $processedVMs
        BackgroundJobs = $remainingJobs.Count
    }
}

# Main execution
try {
    # Step 1: Prepare script content
    $scriptToExecute = Get-ScriptToExecute -ScriptPath $ScriptPath -ScriptContent $ScriptContent
    
    # Step 2: Connect to Azure
    if (-not (Connect-ToAzure)) {
        throw "Failed to connect to Azure"
    }
    $tenantId = (Get-AzContext).Tenant.Id
    Write-Verbose "Operating under Tenant ID: $tenantId"
    
    # Step 3: Get Host Pool information
    $hostPool = Get-HostPoolInfo -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName
    
    # Step 4: Get session hosts
    $sessionHosts = Get-SessionHosts -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName
    
    if ($sessionHosts.Count -eq 0) {
        Write-Warning "No session hosts found in Host Pool '$HostPoolName'"
        exit 0
    }
    
    # Step 5: Get running VMs
    $runningVMs = Get-RunningVMs -SessionHosts $sessionHosts -tenantId $tenantId
    
    if ($runningVMs.Count -eq 0) {
        Write-Verbose "No running VMs found. All VMs are either stopped or in other states."
        Write-Verbose "Only running VMs can execute scripts."
        exit 0
    }
    
    # Step 6: Start async script execution (fire-and-forget)
    $executionSummary = Start-AsyncScriptExecution -RunningVMs $runningVMs -ScriptToExecute $scriptToExecute -ScriptParameters $ScriptParameters -ThrottleLimit $ThrottleLimit -DelayBetweenJobs $DelayBetweenJobs -TenantId $tenantId
    
    Write-Verbose "`n========== Final Summary =========="
    Write-Verbose "Script execution initiated on $($executionSummary.TotalVMs) VMs"
    Write-Verbose "Jobs started successfully: $($executionSummary.JobsStarted)"
    Write-Verbose "Background jobs still running: $($executionSummary.BackgroundJobs)"
    Write-Verbose "VMs being processed: $($executionSummary.ProcessedVMs -join ', ')"
    
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
    
    Write-Verbose "`nScript startup completed!"
    Write-Verbose "Total startup time: $timeFormat"
    Write-Verbose "Script ended at: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Verbose "`nNote: Script execution continues in background on target VMs"
    Write-Verbose "This script has completed its job of starting the remote executions"
}