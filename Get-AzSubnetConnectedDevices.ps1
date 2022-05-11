

<#

    .DESCRIPTION
       
    Out-Gridview driven example of how to get IPs and connected devices from a specified Azure Virtual
    Network subnet.

    .INPUTS
        None.
        

    .NOTES
        Must already be connected to Azure in order to run.


#>



# Load Modules
Import-Module -Name Az.Accounts
Import-Moduel -Name Az.Network

# Set Preferences

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

# Select Azure Subscription that contains the target Virtual Network

Write-Verbose "Getting target Subscription"
$subscriptions = Get-AzSubscription
$subscription = ($subscriptions | Out-GridView -Title 'Please select subscription and then click "OK"' -OutputMode Single).ID
Write-Verbose "Target subscription ID is $subscription"

Select-AzSubscription -SubscriptionId $subscription | Out-Null

# Select the target Virtual Network

Write-Verbose "Getting all Virtual Networks in subscription: $subscription"
$virtualNetworks = Get-AzVirtualNetwork
$virtualNetwork = ($virtualNetworks | Select-Object Name, ResourceGroupName, Id `
    | Out-GridView -Title 'Please select your Virtual Network ' -OutputMode Single)
Write-Verbose "The selected virtual network is: $($virtualNetwork.Name)"


# Get Subnet Information

$params = @{

    Name              = $virtualNetwork.Name
    ResourceGroupName = $virtualNetwork.ResourceGroupName
    ExpandResource    = 'subnets/ipConfigurations' 

}

$vNetSubNets = Get-AzVirtualNetwork @params

# Select Subnet

Write-Verbose "Getting target Subnet"
$subnetName = $vNetSubnets.Subnets.Name | Out-GridView -Title 'Select Subnet' -OutputMode Single
$subnet = $vNetSubnets.Subnets | Where-Object { $_.Name -match $subnetName }

# Get Subnet Information and output it.
$Report = @()
foreach ($ipConfig in $subnet.IpConfigurations) {

    $Report += [PSCustomObject]@{

        Device            = ($ipConfig.Id.Split('/')[8])
        Type              = ($ipConfig.Id.Split('/')[7])
        PrivateIPAddress  = $ipConfig.PrivateIPAddress
        PublicIPAddress   = $ipConfig.PublicIPAddress
        Subnet            = $subnetName
        ResourceGroupName = ($ipConfig.Id.Split('/')[4])

    }

}

$Report

$Report | Out-GridView -Title 'Results' -OutputMode None

# 