<#
.SYNOPSIS
    Deploys Azure Virtual Desktop with Ephemeral VMs as Session Hosts.

.DESCRIPTION
    This script creates the following resources:
    - Resource Group
    - Virtual Network with Subnet
    - NAT Gateway with Public IP
    - AVD Host Pool
    - AVD Application Group
    - AVD Workspace
    - Ephemeral VMs as Session Hosts (Entra Joined with Intune enrollment)

.PARAMETER SubscriptionId
    The Azure Subscription ID to deploy resources to.

.PARAMETER ResourceGroupName
    Name of the Resource Group to create.

.PARAMETER Location
    Azure region for deployment. Default is EastUS2.

.PARAMETER VNetName
    Name of the Virtual Network.

.PARAMETER HostPoolName
    Name of the AVD Host Pool.

.PARAMETER SessionHostCount
    Number of Session Hosts to deploy.

.PARAMETER MinCores
    Minimum number of CPU cores for the VM. Default is 2.

.PARAMETER AdminUsername
    Local admin username for VMs.

.PARAMETER AdminPassword
    Local admin password for VMs.

.PARAMETER EnableAutoShutdown
    Enable auto-shutdown schedule for the VMs. Default is $true.

.PARAMETER AutoShutdownTime
    Time to auto-shutdown VMs in 24-hour format (HHmm). Default is 1900 (7:00 PM).

.PARAMETER AutoShutdownTimeZone
    Time zone for auto-shutdown. Default is Eastern Standard Time.

.EXAMPLE
    .\Deploy-EphemeralAVD.ps1 -SubscriptionId "your-sub-id" -AdminPassword (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force)

.NOTES
    Author: Azure Administrator
    Date: January 2026
    Requires: Az PowerShell module, appropriate Azure permissions
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "rg-avd-ephemeral-eastus2",

    [Parameter(Mandatory = $false)]
    [string]$Location = "EastUS2",

    [Parameter(Mandatory = $false)]
    [string]$VNetName = "vnet-avd-eastus2",

    [Parameter(Mandatory = $false)]
    [string]$SubnetName = "snet-avd-hosts",

    [Parameter(Mandatory = $false)]
    [string]$VNetAddressPrefix = "10.0.0.0/16",

    [Parameter(Mandatory = $false)]
    [string]$SubnetAddressPrefix = "10.0.1.0/24",

    [Parameter(Mandatory = $false)]
    [string]$HostPoolName = "hp-avd-ephemeral",

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceName = "ws-avd-ephemeral",

    [Parameter(Mandatory = $false)]
    [string]$AppGroupName = "dag-avd-ephemeral",

    [Parameter(Mandatory = $false)]
    [int]$SessionHostCount = 2,

    [Parameter(Mandatory = $false)]
    [int]$MinCores = 2,

    [Parameter(Mandatory = $false)]
    [string]$NatGatewayName = "natgw-avd-eastus2",

    [Parameter(Mandatory = $false)]
    [string]$PublicIpName = "pip-natgw-avd",

    [Parameter(Mandatory = $false)]
    [string]$VMPrefix = "avdeph",

    [Parameter(Mandatory = $false)]
    [string]$AdminUsername = "avdadmin",

    [Parameter(Mandatory = $true)]
    [SecureString]$AdminPassword,

    [Parameter(Mandatory = $false)]
    [string]$ImagePublisher = "MicrosoftWindowsDesktop",

    [Parameter(Mandatory = $false)]
    [string]$ImageOffer = "windows-11",

    [Parameter(Mandatory = $false)]
    [string]$ImageSku = "win11-23h2-avd",

    [Parameter(Mandatory = $false)]
    [string]$ImageVersion = "latest",

    [Parameter(Mandatory = $false)]
    [bool]$EnableAutoShutdown = $true,

    [Parameter(Mandatory = $false)]
    [string]$AutoShutdownTime = "1900",

    [Parameter(Mandatory = $false)]
    [string]$AutoShutdownTimeZone = "Eastern Standard Time",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Pooled", "Personal")]
    [string]$HostPoolType = "Pooled"
)

#region Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Info" { "Cyan" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Success" { "Green" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-EphemeralVMSize {
    <#
    .SYNOPSIS
        Finds an Ephemeral OS disk capable VM size with at least the specified number of cores.
    #>
    param(
        [string]$Location,
        [int]$MinCores = 2
    )

    Write-Log "Searching for Ephemeral OS disk capable VM with at least $MinCores cores in region '$Location'..." -Level Info

    try {
        # Get all VM sizes in the region
        $allVMSizes = Get-AzComputeResourceSku -Location $Location | 
        Where-Object { $_.ResourceType -eq "virtualMachines" }

        # Filter for Ephemeral support, minimum cores, and sufficient disk space for Windows 11 AVD (127GB)
        $ephemeralSizes = $allVMSizes | Where-Object {
            $sku = $_
            $skuName = $sku.Name
            
            # Exclude specialty VM families (GPU, HPC, confidential, etc.) - prefer general purpose VMs
            # NC/ND/NV = GPU, H = HPC, L = Storage, M = Memory, DC = Confidential
            if ($skuName -match "^Standard_(NC|ND|NV|H[A-Z]|L[0-9]|M[0-9]|DC|EC|A[0-9])") { return $false }
            
            # Prefer D-series, E-series, F-series (general purpose VMs commonly available)
            if ($skuName -notmatch "^Standard_(D|E|F)") { return $false }
            
            $ephemeralSupport = $sku.Capabilities | Where-Object { $_.Name -eq "EphemeralOSDiskSupported" -and $_.Value -eq "True" }
            $vCPUs = ($sku.Capabilities | Where-Object { $_.Name -eq "vCPUs" }).Value
            $cacheDiskSize = ($sku.Capabilities | Where-Object { $_.Name -eq "CachedDiskBytes" }).Value
            $resourceDiskSize = ($sku.Capabilities | Where-Object { $_.Name -eq "MaxResourceVolumeMB" }).Value
            
            # Check if ephemeral is supported
            if (-not $ephemeralSupport) { return $false }
            
            # Check minimum cores
            if ([int]$vCPUs -lt $MinCores) { return $false }
            
            # Check if either cache disk or resource disk is large enough for Windows 11 AVD (127GB for full image)
            $cacheDiskGB = if ($cacheDiskSize) { [math]::Floor([long]$cacheDiskSize / 1GB) } else { 0 }
            $resourceDiskGB = if ($resourceDiskSize) { [math]::Floor([long]$resourceDiskSize / 1024) } else { 0 }
            
            # Require at least 127GB on either cache or resource disk for Windows 11 AVD image
            if ($cacheDiskGB -lt 127 -and $resourceDiskGB -lt 127) { return $false }
            
            # Exclude restricted/preview SKUs
            $restrictions = $sku.Restrictions | Where-Object { $_.Type -eq "Location" }
            if ($restrictions) { return $false }
            
            return $true
        } | ForEach-Object {
            $sku = $_
            $vCPUs = [int](($sku.Capabilities | Where-Object { $_.Name -eq "vCPUs" }).Value)
            $memoryGB = [math]::Round([decimal](($sku.Capabilities | Where-Object { $_.Name -eq "MemoryGB" }).Value), 2)
            $cacheDiskSize = ($sku.Capabilities | Where-Object { $_.Name -eq "CachedDiskBytes" }).Value
            $resourceDiskSize = ($sku.Capabilities | Where-Object { $_.Name -eq "MaxResourceVolumeMB" }).Value
            $cacheDiskGB = if ($cacheDiskSize) { [math]::Floor([long]$cacheDiskSize / 1GB) } else { 0 }
            $resourceDiskGB = if ($resourceDiskSize) { [math]::Floor([long]$resourceDiskSize / 1024) } else { 0 }
            
            [PSCustomObject]@{
                Name           = $sku.Name
                vCPUs          = $vCPUs
                MemoryGB       = $memoryGB
                CacheDiskGB    = $cacheDiskGB
                ResourceDiskGB = $resourceDiskGB
            }
        } | Sort-Object vCPUs, MemoryGB

        if (-not $ephemeralSizes -or $ephemeralSizes.Count -eq 0) {
            Write-Log "No Ephemeral OS disk capable VM sizes found with at least $MinCores cores in region '$Location'." -Level Error
            return $null
        }

        # Select the smallest VM that meets the requirements (cost-effective choice)
        $selectedSize = $ephemeralSizes | Select-Object -First 1
        
        Write-Log "Found $($ephemeralSizes.Count) Ephemeral-capable VM sizes with at least $MinCores cores." -Level Success
        Write-Log "Selected VM Size: $($selectedSize.Name)" -Level Success
        Write-Log "  - vCPUs: $($selectedSize.vCPUs)" -Level Info
        Write-Log "  - Memory: $($selectedSize.MemoryGB) GB" -Level Info
        Write-Log "  - Cache Disk: $($selectedSize.CacheDiskGB) GB" -Level Info
        Write-Log "  - Resource Disk: $($selectedSize.ResourceDiskGB) GB" -Level Info

        return $selectedSize.Name
    }
    catch {
        Write-Log "Error finding Ephemeral VM size: $_" -Level Error
        return $null
    }
}

function Get-EphemeralPlacement {
    <#
    .SYNOPSIS
        Determines the best placement for Ephemeral OS disk (CacheDisk or ResourceDisk).
        Returns $null if neither option has sufficient space.
    #>
    param(
        [string]$Location,
        [string]$VMSize,
        [int]$RequiredDiskSizeGB = 127  # Windows 11 AVD image default size
    )

    $vmSizes = Get-AzComputeResourceSku -Location $Location | 
    Where-Object { $_.ResourceType -eq "virtualMachines" -and $_.Name -eq $VMSize }

    $cacheDiskBytes = ($vmSizes.Capabilities | Where-Object { $_.Name -eq "CachedDiskBytes" }).Value
    $resourceDiskMB = ($vmSizes.Capabilities | Where-Object { $_.Name -eq "MaxResourceVolumeMB" }).Value
    
    $cacheDiskGB = if ($cacheDiskBytes) { [math]::Floor([long]$cacheDiskBytes / 1GB) } else { 0 }
    $resourceDiskGB = if ($resourceDiskMB) { [math]::Floor([long]$resourceDiskMB / 1024) } else { 0 }
    
    Write-Log "  VM '$VMSize' disk sizes - Cache: ${cacheDiskGB}GB, Resource: ${resourceDiskGB}GB (Required: ${RequiredDiskSizeGB}GB)" -Level Info
    
    # Prefer CacheDisk placement if cache is large enough
    if ($cacheDiskGB -ge $RequiredDiskSizeGB) {
        Write-Log "  Using CacheDisk placement (${cacheDiskGB}GB available)" -Level Info
        return "CacheDisk"
    }
    # Fall back to ResourceDisk if large enough
    elseif ($resourceDiskGB -ge $RequiredDiskSizeGB) {
        Write-Log "  Using ResourceDisk placement (${resourceDiskGB}GB available)" -Level Info
        return "ResourceDisk"
    }
    else {
        Write-Log "  Neither CacheDisk (${cacheDiskGB}GB) nor ResourceDisk (${resourceDiskGB}GB) is large enough for ${RequiredDiskSizeGB}GB OS disk" -Level Warning
        return $null
    }
}

#endregion Functions

#region Main Script

Write-Log "========================================" -Level Info
Write-Log "Azure Virtual Desktop - Ephemeral VM Deployment" -Level Info
Write-Log "========================================" -Level Info
Write-Log "Location: $Location" -Level Info
Write-Log "Resource Group: $ResourceGroupName" -Level Info
Write-Log "Host Pool: $HostPoolName" -Level Info
Write-Log "Session Host Count: $SessionHostCount" -Level Info
Write-Log "Minimum Cores: $MinCores" -Level Info
Write-Log "========================================" -Level Info

# Step 0: Connect to Azure and set subscription
Write-Log "Connecting to Azure..." -Level Info
try {
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount -ErrorAction Stop
        $context = Get-AzContext
    }
    
    # If SubscriptionId is provided, switch to that subscription; otherwise use current context
    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
        $context = Get-AzContext
    }
    
    $currentSubscriptionId = $context.Subscription.Id
    $currentSubscriptionName = $context.Subscription.Name
    Write-Log "Connected to subscription: $currentSubscriptionName ($currentSubscriptionId)" -Level Success
}
catch {
    Write-Log "Failed to connect to Azure: $_" -Level Error
    exit 1
}

# Step 1: Register Required Resource Providers
Write-Log "Step 1: Registering required resource providers..." -Level Info
try {
    $requiredProviders = @(
        "Microsoft.DesktopVirtualization",
        "Microsoft.Compute",
        "Microsoft.Network"
    )
    
    foreach ($provider in $requiredProviders) {
        $providerState = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction SilentlyContinue
        if ($providerState.RegistrationState -ne "Registered") {
            Write-Log "  Registering $provider..." -Level Info
            Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | Out-Null
        }
        else {
            Write-Log "  $provider is already registered." -Level Info
        }
    }
    
    # Wait for Microsoft.DesktopVirtualization to be registered (it's required for AVD)
    Write-Log "  Waiting for resource providers to be registered..." -Level Info
    $maxWaitTime = 300  # 5 minutes max
    $waitTime = 0
    $waitInterval = 10
    
    do {
        $avdProvider = Get-AzResourceProvider -ProviderNamespace "Microsoft.DesktopVirtualization" -ErrorAction SilentlyContinue
        if ($avdProvider.RegistrationState -eq "Registered") {
            break
        }
        Start-Sleep -Seconds $waitInterval
        $waitTime += $waitInterval
        Write-Log "  Still waiting for Microsoft.DesktopVirtualization registration... ($waitTime seconds)" -Level Info
    } while ($waitTime -lt $maxWaitTime)
    
    if ($avdProvider.RegistrationState -ne "Registered") {
        Write-Log "Timeout waiting for Microsoft.DesktopVirtualization to register. Please try again later." -Level Error
        exit 1
    }
    
    Write-Log "All required resource providers are registered." -Level Success
}
catch {
    Write-Log "Failed to register resource providers: $_" -Level Error
    exit 1
}

# Step 2: Find Ephemeral VM Size
Write-Log "Step 2: Finding Ephemeral VM Size with at least $MinCores cores..." -Level Info
$VMSize = Get-EphemeralVMSize -Location $Location -MinCores $MinCores
if (-not $VMSize) {
    Write-Log "No suitable Ephemeral VM size found. Please try a different region or reduce MinCores." -Level Error
    exit 1
}

$ephemeralPlacement = Get-EphemeralPlacement -Location $Location -VMSize $VMSize
if (-not $ephemeralPlacement) {
    Write-Log "Selected VM size '$VMSize' does not have sufficient disk space for Windows 11 AVD. Trying to find another size..." -Level Error
    exit 1
}
Write-Log "Ephemeral OS disk placement will be: $ephemeralPlacement" -Level Success

# Step 3: Create Resource Group
Write-Log "Step 3: Creating Resource Group '$ResourceGroupName'..." -Level Info
try {
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        $rg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop
        Write-Log "Resource Group created successfully." -Level Success
    }
    else {
        Write-Log "Resource Group already exists." -Level Warning
    }
}
catch {
    Write-Log "Failed to create Resource Group: $_" -Level Error
    exit 1
}

# Step 4: Create Virtual Network and Subnet
Write-Log "Step 4: Creating Virtual Network '$VNetName'..." -Level Info
try {
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $vnet) {
        # Create subnet configuration
        $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetAddressPrefix

        # Create virtual network
        $vnet = New-AzVirtualNetwork `
            -Name $VNetName `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -AddressPrefix $VNetAddressPrefix `
            -Subnet $subnetConfig `
            -ErrorAction Stop

        Write-Log "Virtual Network created successfully." -Level Success
    }
    else {
        Write-Log "Virtual Network already exists." -Level Warning
    }

    # Get subnet reference
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet
}
catch {
    Write-Log "Failed to create Virtual Network: $_" -Level Error
    exit 1
}

# Step 4.5: Create NAT Gateway with Public IP
Write-Log "Step 4.5: Creating NAT Gateway '$NatGatewayName'..." -Level Info
try {
    $natGateway = Get-AzNatGateway -Name $NatGatewayName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $natGateway) {
        # Check if Public IP already exists
        $publicIp = Get-AzPublicIpAddress -Name $PublicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $publicIp) {
            Write-Log "  Creating Public IP '$PublicIpName' for NAT Gateway..." -Level Info
            $publicIp = New-AzPublicIpAddress `
                -Name $PublicIpName `
                -ResourceGroupName $ResourceGroupName `
                -Location $Location `
                -Sku "Standard" `
                -AllocationMethod "Static" `
                -ErrorAction Stop
            Write-Log "  Public IP created: $($publicIp.IpAddress)" -Level Success
        }
        else {
            Write-Log "  Public IP '$PublicIpName' already exists: $($publicIp.IpAddress)" -Level Warning
        }

        # Create NAT Gateway
        Write-Log "  Creating NAT Gateway..." -Level Info
        $natGateway = New-AzNatGateway `
            -Name $NatGatewayName `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -Sku "Standard" `
            -PublicIpAddress $publicIp `
            -IdleTimeoutInMinutes 10 `
            -ErrorAction Stop

        Write-Log "NAT Gateway created successfully." -Level Success
    }
    else {
        Write-Log "NAT Gateway already exists." -Level Warning
    }

    # Always ensure NAT Gateway is associated with the AVD subnet
    Write-Log "  Verifying NAT Gateway is attached to subnet '$SubnetName'..." -Level Info
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet
    
    # Check if NAT Gateway is already attached
    if (-not $subnet.NatGateway -or $subnet.NatGateway.Id -ne $natGateway.Id) {
        Write-Log "  Associating NAT Gateway with subnet '$SubnetName'..." -Level Info
        Set-AzVirtualNetworkSubnetConfig `
            -VirtualNetwork $vnet `
            -Name $SubnetName `
            -AddressPrefix $SubnetAddressPrefix `
            -NatGateway $natGateway | Out-Null
        $vnet | Set-AzVirtualNetwork | Out-Null
        Write-Log "NAT Gateway associated with subnet '$SubnetName'." -Level Success
    }
    else {
        Write-Log "NAT Gateway is already attached to subnet '$SubnetName'." -Level Success
    }

    # Refresh subnet reference after NAT Gateway association
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet

    # Verify attachment before proceeding
    if (-not $subnet.NatGateway) {
        Write-Log "Failed to attach NAT Gateway to subnet. Cannot proceed with VM deployment." -Level Error
        exit 1
    }
    Write-Log "Verified: NAT Gateway is attached to AVD subnet." -Level Success
}
catch {
    Write-Log "Failed to create NAT Gateway: $_" -Level Error
    exit 1
}

# Step 5: Create AVD Host Pool
Write-Log "Step 5: Creating AVD Host Pool '$HostPoolName'..." -Level Info
try {
    $hostPool = Get-AzWvdHostPool -Name $HostPoolName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $hostPool) {
        # Set LoadBalancerType based on HostPoolType
        $loadBalancerType = if ($HostPoolType -eq "Pooled") { "BreadthFirst" } else { "Persistent" }
        
        $hostPoolParams = @{
            Name                  = $HostPoolName
            ResourceGroupName     = $ResourceGroupName
            Location              = $Location
            HostPoolType          = $HostPoolType
            LoadBalancerType      = $loadBalancerType
            PreferredAppGroupType = "Desktop"
            ValidationEnvironment = $false
            StartVMOnConnect      = $true
            ErrorAction           = "Stop"
        }
        
        # MaxSessionLimit only applies to Pooled host pools
        if ($HostPoolType -eq "Pooled") {
            $hostPoolParams.MaxSessionLimit = 10
        }
        
        $hostPool = New-AzWvdHostPool @hostPoolParams

        Write-Log "AVD Host Pool created successfully." -Level Success
    }
    else {
        Write-Log "Host Pool already exists." -Level Warning
    }
    # Get the Host Pool ARM path for Application Group
    $hostPoolArmPath = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$HostPoolName"
}
catch {
    Write-Log "Failed to create Host Pool: $_" -Level Error
    exit 1
}

# Step 6: Create AVD Application Group
Write-Log "Step 6: Creating AVD Application Group '$AppGroupName'..." -Level Info
try {
    $appGroup = Get-AzWvdApplicationGroup -Name $AppGroupName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $appGroup) {
        $appGroup = New-AzWvdApplicationGroup `
            -Name $AppGroupName `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -HostPoolArmPath $hostPoolArmPath `
            -ApplicationGroupType "Desktop" `
            -ErrorAction Stop

        Write-Log "Application Group created successfully." -Level Success
    }
    else {
        Write-Log "Application Group already exists." -Level Warning
    }
    # Get the Application Group ARM path for Workspace
    $appGroupArmPath = "/subscriptions/$((Get-AzContext).Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.DesktopVirtualization/applicationGroups/$AppGroupName"
}
catch {
    Write-Log "Failed to create Application Group: $_" -Level Error
    exit 1
}

# Step 7: Create AVD Workspace
Write-Log "Step 7: Creating AVD Workspace '$WorkspaceName'..." -Level Info
try {
    $workspace = Get-AzWvdWorkspace -Name $WorkspaceName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $workspace) {
        $workspace = New-AzWvdWorkspace `
            -Name $WorkspaceName `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -ApplicationGroupReference $appGroupArmPath `
            -ErrorAction Stop

        Write-Log "Workspace created successfully." -Level Success
    }
    else {
        # Ensure the application group is linked to the workspace
        if ($workspace.ApplicationGroupReference -notcontains $appGroupArmPath) {
            Write-Log "  Adding Application Group to existing Workspace..." -Level Info
            $appGroupRefs = @($workspace.ApplicationGroupReference) + @($appGroupArmPath) | Select-Object -Unique
            Update-AzWvdWorkspace `
                -Name $WorkspaceName `
                -ResourceGroupName $ResourceGroupName `
                -ApplicationGroupReference $appGroupRefs `
                -ErrorAction Stop
            Write-Log "  Application Group added to Workspace." -Level Success
        }
        Write-Log "Workspace already exists." -Level Warning
    }
}
catch {
    Write-Log "Failed to create Workspace: $_" -Level Error
    exit 1
}

# Step 8: Generate Host Pool Registration Token
Write-Log "Step 8: Generating Host Pool Registration Token..." -Level Info
try {
    $tokenExpirationTime = (Get-Date).AddHours(24)
    $registrationInfo = New-AzWvdRegistrationInfo `
        -ResourceGroupName $ResourceGroupName `
        -HostPoolName $HostPoolName `
        -ExpirationTime $tokenExpirationTime `
        -ErrorAction Stop

    $registrationToken = $registrationInfo.Token
    Write-Log "Registration token generated (expires: $tokenExpirationTime)" -Level Success
}
catch {
    Write-Log "Failed to generate registration token: $_" -Level Error
    exit 1
}

# Step 9: Deploy Ephemeral VMs as Session Hosts
Write-Log "Step 9: Deploying $SessionHostCount Ephemeral VMs as Session Hosts..." -Level Info

# Create credential object
$credential = New-Object System.Management.Automation.PSCredential($AdminUsername, $AdminPassword)

for ($i = 1; $i -le $SessionHostCount; $i++) {
    $vmName = "$VMPrefix-$i"
    $nicName = "$vmName-nic"

    Write-Log "Creating Session Host $i of $SessionHostCount : $vmName" -Level Info

    try {
        # Check if VM already exists
        $existingVM = Get-AzVM -Name $vmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if ($existingVM) {
            Write-Log "VM '$vmName' already exists. Checking extensions..." -Level Warning
            
            # Remove old failed InstallAVDAgent extension if it exists
            $oldAvdExtension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $vmName -Name "InstallAVDAgent" -ErrorAction SilentlyContinue
            if ($oldAvdExtension) {
                Write-Log "  Removing old InstallAVDAgent extension..." -Level Info
                Remove-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $vmName -Name "InstallAVDAgent" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 10
            }
            
            # Check and install AADLoginForWindows extension if missing
            $aadExtension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $vmName -Name "AADLoginForWindows" -ErrorAction SilentlyContinue
            if (-not $aadExtension) {
                Write-Log "  Installing AADLoginForWindows extension on existing VM..." -Level Info
                Set-AzVMExtension `
                    -ResourceGroupName $ResourceGroupName `
                    -VMName $vmName `
                    -Name "AADLoginForWindows" `
                    -Publisher "Microsoft.Azure.ActiveDirectory" `
                    -Type "AADLoginForWindows" `
                    -TypeHandlerVersion "2.2" `
                    -Settings @{
                    "mdmId" = "0000000a-0000-0000-c000-000000000000"
                } `
                    -ErrorAction SilentlyContinue
            }
            elseif ($aadExtension.ProvisioningState -ne "Succeeded") {
                Write-Log "  AADLoginForWindows extension exists but status is $($aadExtension.ProvisioningState). Removing and reinstalling..." -Level Warning
                Remove-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $vmName -Name "AADLoginForWindows" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 30
                Set-AzVMExtension `
                    -ResourceGroupName $ResourceGroupName `
                    -VMName $vmName `
                    -Name "AADLoginForWindows" `
                    -Publisher "Microsoft.Azure.ActiveDirectory" `
                    -Type "AADLoginForWindows" `
                    -TypeHandlerVersion "2.2" `
                    -Settings @{
                    "mdmId" = "0000000a-0000-0000-c000-000000000000"
                } `
                    -ErrorAction SilentlyContinue
            }
            else {
                Write-Log "  AADLoginForWindows extension already installed." -Level Info
            }
            
            # Check and install AVD Agent extension if missing
            $avdExtension = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $vmName -Name "Microsoft.PowerShell.DSC" -ErrorAction SilentlyContinue
            
            if (-not $avdExtension) {
                Write-Log "  Installing AVD Agent on existing VM using DSC extension..." -Level Info
                $dscConfigurationUrl = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02797.442.zip"
                
                $dscSettings = @{
                    modulesUrl            = $dscConfigurationUrl
                    configurationFunction = "Configuration.ps1\AddSessionHost"
                    properties            = @{
                        hostPoolName                           = $HostPoolName
                        registrationInfoTokenCredential        = @{
                            UserName = "PLACEHOLDER"
                            Password = "PrivateSettingsRef:RegistrationInfoToken"
                        }
                        aadJoin                                = $true
                        aadJoinPreview                         = $false
                        mdmId                                  = "0000000a-0000-0000-c000-000000000000"
                        sessionHostConfigurationLastUpdateTime = ""
                    }
                }
                
                $dscProtectedSettings = @{
                    Items = @{
                        RegistrationInfoToken = $registrationToken
                    }
                }
                
                Set-AzVMExtension `
                    -ResourceGroupName $ResourceGroupName `
                    -VMName $vmName `
                    -Name "Microsoft.PowerShell.DSC" `
                    -Publisher "Microsoft.Powershell" `
                    -ExtensionType "DSC" `
                    -TypeHandlerVersion "2.77" `
                    -SettingString ($dscSettings | ConvertTo-Json -Depth 10) `
                    -ProtectedSettingString ($dscProtectedSettings | ConvertTo-Json -Depth 10) `
                    -ErrorAction SilentlyContinue
            }
            else {
                Write-Log "  AVD Agent extension already installed." -Level Info
            }
            
            continue
        }

        # Check if Network Interface already exists
        Write-Log "  Creating Network Interface '$nicName'..." -Level Info
        $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $nic) {
            $nic = New-AzNetworkInterface `
                -Name $nicName `
                -ResourceGroupName $ResourceGroupName `
                -Location $Location `
                -SubnetId $subnet.Id `
                -ErrorAction Stop
            Write-Log "  Network Interface created." -Level Success
        }
        else {
            Write-Log "  Network Interface '$nicName' already exists." -Level Warning
        }

        # Create VM Configuration
        Write-Log "  Configuring VM..." -Level Info
        $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $VMSize

        # Set OS profile
        $vmConfig = Set-AzVMOperatingSystem `
            -VM $vmConfig `
            -Windows `
            -ComputerName $vmName `
            -Credential $credential `
            -ProvisionVMAgent `
            -EnableAutoUpdate

        # Set source image
        $vmConfig = Set-AzVMSourceImage `
            -VM $vmConfig `
            -PublisherName $ImagePublisher `
            -Offer $ImageOffer `
            -Skus $ImageSku `
            -Version $ImageVersion

        # Add network interface
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id -Primary

        # Configure Ephemeral OS disk
        Write-Log "  Configuring Ephemeral OS disk (Placement: $ephemeralPlacement)..." -Level Info
        $vmConfig = Set-AzVMOSDisk `
            -VM $vmConfig `
            -Name "$vmName-osdisk" `
            -Caching "ReadOnly" `
            -CreateOption "FromImage" `
            -DiffDiskSetting "Local" `
            -DiffDiskPlacement $ephemeralPlacement

        # Configure boot diagnostics (disabled for ephemeral)
        $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

        # Set Entra Join (Azure AD Join) identity
        $vmConfig.Identity = New-Object Microsoft.Azure.Management.Compute.Models.VirtualMachineIdentity
        $vmConfig.Identity.Type = "SystemAssigned"

        # Create the VM
        Write-Log "  Creating VM '$vmName'..." -Level Info
        New-AzVM `
            -ResourceGroupName $ResourceGroupName `
            -Location $Location `
            -VM $vmConfig `
            -ErrorAction Stop

        Write-Log "  VM '$vmName' created successfully." -Level Success

        # Wait for VM to fully initialize before installing extensions
        Write-Log "  Waiting 60 seconds for VM to initialize before installing extensions..." -Level Info
        Start-Sleep -Seconds 60

        # Configure Entra Join using AADLoginForWindows extension
        Write-Log "  Configuring Entra ID Join and Intune enrollment for '$vmName'..." -Level Info
        
        # Retry logic for AAD Join extension
        $maxRetries = 3
        $retryCount = 0
        $aadJoinSuccess = $false
        
        while (-not $aadJoinSuccess -and $retryCount -lt $maxRetries) {
            try {
                $retryCount++
                if ($retryCount -gt 1) {
                    Write-Log "  Retry $retryCount of $maxRetries for AAD Join extension..." -Level Warning
                    Start-Sleep -Seconds 30
                }
                
                Set-AzVMExtension `
                    -ResourceGroupName $ResourceGroupName `
                    -VMName $vmName `
                    -Name "AADLoginForWindows" `
                    -Publisher "Microsoft.Azure.ActiveDirectory" `
                    -Type "AADLoginForWindows" `
                    -TypeHandlerVersion "2.2" `
                    -Settings @{
                    "mdmId" = "0000000a-0000-0000-c000-000000000000"  # Microsoft Intune MDM ID
                } `
                    -ErrorAction Stop
                
                $aadJoinSuccess = $true
                Write-Log "  Entra ID Join extension configured for '$vmName'." -Level Success
            }
            catch {
                Write-Log "  AAD Join attempt $retryCount failed: $_" -Level Warning
                if ($retryCount -ge $maxRetries) {
                    Write-Log "  AAD Join failed after $maxRetries attempts. VM created but not Entra joined." -Level Error
                }
            }
        }

        # Install AVD Agent using Microsoft's official DSC extension
        Write-Log "  Installing AVD Agent on '$vmName' using DSC extension..." -Level Info
        
        # Use the official Microsoft AVD DSC extension
        $dscConfigurationUrl = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02797.442.zip"
        
        $dscSettings = @{
            modulesUrl            = $dscConfigurationUrl
            configurationFunction = "Configuration.ps1\AddSessionHost"
            properties            = @{
                hostPoolName                           = $HostPoolName
                registrationInfoTokenCredential        = @{
                    UserName = "PLACEHOLDER"
                    Password = "PrivateSettingsRef:RegistrationInfoToken"
                }
                aadJoin                                = $true
                aadJoinPreview                         = $false
                mdmId                                  = "0000000a-0000-0000-c000-000000000000"
                sessionHostConfigurationLastUpdateTime = ""
            }
        }
        
        $dscProtectedSettings = @{
            Items = @{
                RegistrationInfoToken = $registrationToken
            }
        }
        
        Set-AzVMExtension `
            -ResourceGroupName $ResourceGroupName `
            -VMName $vmName `
            -Name "Microsoft.PowerShell.DSC" `
            -Publisher "Microsoft.Powershell" `
            -ExtensionType "DSC" `
            -TypeHandlerVersion "2.77" `
            -SettingString ($dscSettings | ConvertTo-Json -Depth 10) `
            -ProtectedSettingString ($dscProtectedSettings | ConvertTo-Json -Depth 10) `
            -ErrorAction Stop

        Write-Log "  AVD Agent installed on '$vmName'." -Level Success

        # Configure Auto-Shutdown if enabled
        if ($EnableAutoShutdown) {
            Write-Log "  Configuring auto-shutdown for '$vmName' at $AutoShutdownTime $AutoShutdownTimeZone..." -Level Info
            
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName
            $shutdownResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-$vmName"
            
            $properties = @{
                status               = "Enabled"
                taskType             = "ComputeVmShutdownTask"
                dailyRecurrence      = @{
                    time = $AutoShutdownTime
                }
                timeZoneId           = $AutoShutdownTimeZone
                targetResourceId     = $vm.Id
                notificationSettings = @{
                    status        = "Disabled"
                    timeInMinutes = 30
                }
            }
            
            New-AzResource -ResourceId $shutdownResourceId -Location $Location -Properties $properties -Force | Out-Null
            Write-Log "  Auto-shutdown configured for '$vmName'." -Level Success
        }

    }
    catch {
        Write-Log "Failed to create VM '$vmName': $_" -Level Error
        continue
    }
}

# Step 10: Verify Deployment
Write-Log "Step 10: Verifying deployment..." -Level Info
try {
    Start-Sleep -Seconds 30  # Wait for session hosts to register

    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction SilentlyContinue
    
    if ($sessionHosts) {
        Write-Log "Registered Session Hosts:" -Level Success
        $sessionHosts | ForEach-Object {
            $hostName = ($_.Name -split "/")[-1]
            Write-Log "  - $hostName (Status: $($_.Status), Allow New Sessions: $($_.AllowNewSession))" -Level Info
        }
    }
    else {
        Write-Log "No session hosts registered yet. They may take a few minutes to appear." -Level Warning
    }
}
catch {
    Write-Log "Failed to verify deployment: $_" -Level Warning
}

# Summary
Write-Log "========================================" -Level Info
Write-Log "Deployment Summary" -Level Success
Write-Log "========================================" -Level Info
Write-Log "Resource Group: $ResourceGroupName" -Level Info
Write-Log "Virtual Network: $VNetName" -Level Info
Write-Log "NAT Gateway: $NatGatewayName" -Level Info
Write-Log "Host Pool: $HostPoolName" -Level Info
Write-Log "Workspace: $WorkspaceName" -Level Info
Write-Log "Application Group: $AppGroupName" -Level Info
Write-Log "Session Hosts: $SessionHostCount VMs with Ephemeral OS disks" -Level Info
Write-Log "VM Size: $VMSize (auto-selected with $MinCores+ cores)" -Level Info
Write-Log "Ephemeral Disk Placement: $ephemeralPlacement" -Level Info
Write-Log "Entra ID Join: Enabled" -Level Info
Write-Log "Intune Enrollment: Enabled" -Level Info
Write-Log "========================================" -Level Info
Write-Log "Deployment completed successfully!" -Level Success
Write-Log "" -Level Info
Write-Log "Next Steps:" -Level Info
Write-Log "1. Assign users to the Application Group '$AppGroupName'" -Level Info
Write-Log "2. Configure Conditional Access policies for AVD" -Level Info
Write-Log "3. Test user connectivity via the Windows 365 App or web client" -Level Info
Write-Log "4. Monitor session hosts in the Azure Portal" -Level Info

#endregion Main Script
