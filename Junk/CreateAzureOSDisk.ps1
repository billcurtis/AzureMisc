
#region functions
function New-ImageAzResourceGroup {

    param ($ResourceGroupName, $LocationName)

    # Import Az.Resources
    $VerbosePreference = 'SilentlyContinue'
    Import-Module Az.Resources
    $VerbosePreference = 'Continue'


    $isResGrp = Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName }
    if (!$isResGrp) {

        Write-Verbose "Resource Group named $ResourceGroupName not found. Creating Resource Group"
        New-AzResourceGroup -Name $ResourceGroupName -Location $LocationName -Force | Out-Null

    }
    else { Write-Verbose  "Resource Group Name $ResourceGroupName already exists." }
}

function New-ImageAzNetwork {

    param (
        
        $NetworkName, 
        $ResourceGroupName,
        $LocationName, 
        $SubnetName,
        $SubnetAddressPrefix,
        $VnetAddressPrefix, 
        $NICName )

    # Import modules
    $VerbosePreference = 'SilentlyContinue'
    Import-Module Az.Network
    $VerbosePreference = 'Continue'


    # Check to see if network already exists

    $isVnet = Get-AzVirtualNetwork | Where-Object { $_.Name -eq $NetworkName -and $_.ResourceGroupName -eq $ResourceGroupName }
    if (!$isVnet) {

        Write-Verbose "Network named $NetworkName not found. Creating Network"
        
        $SingleSubnet = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $SubnetAddressPrefix

        # Create Virtual Network
        $params = @{

            Name              = $NetworkName
            ResourceGroupName = $ResourceGroupName
            Location          = $LocationName
            AddressPrefix     = $VnetAddressPrefix
            Subnet            = $SingleSubnet

        }

        $vNet = New-AzVirtualNetwork @params
        
        # Create NIC

        $params = @{

            Name              = $NICName
            ResourceGroupName = $ResourceGroupName
            Location          = $LocationName
            SubnetId          = ($vNet.Subnets[0].Id)

        }

        $NIC = New-AzNetworkInterface @params

    }
    else { 
        
        Write-Verbose  "Virtual Network Name $NetwworkName already exists."
        
        $NIC = Get-AzNetworkInterface | Where-Object { $_.Name -eq $NICName -and $_.ResourceGroupName -eq $ResourceGroupName }
        if (!$NIC) {
        
            Write-Verbose 'Creating NIC $NICName as it does not exist in network $NetworkName'

            $params = @{

                Name              = $NICName
                ResourceGroupName = $ResourceGroupName
                Location          = $LocationName
                SubnetId          = $vNet.Subnets[0].Id

            }

            $NIC = New-AzNetworkInterface @params

        }          

    }

    return $NIC

}

function New-ImageAzVMConfig {

    param (

        $VMName,
        $VMSize,
        $ComputerName,
        $VMComputerName,
        $Credential,
        $NIC,
        $PublisherName,
        $Offer,
        $SKUs,
        $Version
   
    )

    # Import Modules
    Import-Module -Name Az.Compute
    
    Write-Verbose 'Creating Virtual Machine Config'
    $VirtualMachine = New-AzVMConfig -VMName $VMName -VMSize $VMSize

    $params = @{

        VM               = $VirtualMachine
        Windows          = $true
        ComputerName     = $VMComputerName
        Credential       = $Credential
        ProvisionVMAgent = $true
        EnableAutoUpdate = $true

    }

    Write-Verbose 'Creating VM Operating System Configuration'
    $VirtualMachine = Set-AzVMOperatingSystem @params

    Write-Verbose 'Adding the vm network adatper to the VM configuration'
    $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id

    $params = @{
        
        VM            = $VirtualMachine
        Offer         = $Offer
        Skus          = $SKUs
        Version       = $Version
        PublisherName = $PublisherName

    }
    
    Write-Verbose 'Setting source image options on the VM configuration'
    $VirtualMachine = Set-AzVMSourceImage @params


    return $VirtualMachine

}

#endregion

# Set Location
$ResourceGroupName = 'test-vmgroup6'
$LocationName = 'East US'

# Set-Network Information
$NetworkName = "MyNet"
$NICName = "MyNIC"
$SubnetName = "MySubnet"
$SubnetAddressPrefix = "10.0.0.0/24"
$VnetAddressPrefix = "10.0.0.0/16"

# Set Login Credentials
$VMLocalAdminUser = 'wcurtis'
$VMLocalAdminPassword = 'P@ssw0rd123456'
$VMLocalAdminSecurePassword = ConvertTo-SecureString $VMLocalAdminPassword -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUser, $VMLocalAdminSecurePassword)

# Set VM Image Version
$PublisherName = 'MicrosoftWindowsServer'
$SKUs = '2019-datacenter-gensecond'
$Offer = 'WindowsServer'
$Version = 'latest'
$VMSize = 'Standard_B1s'

# Set VM Name Information
$VMName = 'SourceVM'
$VMComputerName = $Offer


#region Main

# Set Preferences
$ErrorActionPreference = 'Stop'

# Create Resource Group (if not exist)
New-ImageAzResourceGroup -ResourceGroupName $ResourceGroupName -LocationName $LocationName

# Create vNet (if not exist)
$params = @{

    NetworkName         = $NetworkName
    ResourceGroupName   = $ResourceGroupName
    LocationName        = $LocationName
    SubnetName          = $SubnetName
    SubnetAddressPrefix = $SubnetAddressPrefix
    VnetAddressPrefix   = $VnetAddressPrefix
    NICName             = $NICName
}

$NIC = New-ImageAzNetwork @params

# Create Virtual Machine Configuraton

$params = @{

    VMName         = $VMName
    VMSize         = $VMSize
    ComputerName   = $ComputerName
    VMComputerName = $VMComputerName
    Credential     = $Credential
    NIC            = $NIC
    PublisherName  = $PublisherName
    Offer          = $Offer
    SKUs           = $SKUs
    Version        = $Version

}

$VirtualMachine = New-ImageAzVMConfig @params

# Create VM

Write-Verbose 'Creating VM'

$params = @{

    ResourceGroupName      = $ResourceGroupName
    Location               = $LocationName
    VM                     = $VirtualMachine
    DisableBginfoExtension = $true

}

$vmCreation = New-AzVM @params 


# Add Applications

# Add Answer Files

# Generalize VM

# Store VM in storage Blob

# Destroy VM

# Return VHD Location
 
#endregion
