# AVD Client Firewall Exclusions

This folder contains PowerShell scripts for Azure Virtual Desktop (AVD) client network requirements and Windows Firewall configuration.

## Scripts

### Get-AVDNetworkRequirements.ps1

**Purpose:** Outputs all network requirements for AVD connectivity without making any changes to the system.

This read-only, **firewall-agnostic** script produces a comprehensive report that can be used to configure **any firewall or network security solution** (Palo Alto, Fortinet, Cisco, Azure Firewall, NSGs, etc.).

The script:
- Downloads the latest Azure Service Tags JSON from Microsoft
- Resolves AVD-related FQDNs to IP addresses
- Outputs IP ranges, FQDNs, ports, and protocols in a format suitable for any firewall

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `-Region` | Azure region (e.g., "eastus2") to scope IP ranges. Omit for global ranges. |
| `-ExportCsv` | Path to export results as CSV for import into firewall management systems |
| `-ExportJson` | Path to export results as JSON for automation/API use |
| `-ResolveFQDNs` | Resolve FQDNs to IPv4 addresses (default: True) |

**Examples:**
```powershell
# Output all global AVD network requirements to console
.\Get-AVDNetworkRequirements.ps1

# Export EastUS2-scoped requirements to CSV for firewall import
.\Get-AVDNetworkRequirements.ps1 -Region eastus2 -ExportCsv .\avd-requirements.csv

# Export to JSON for automation
.\Get-AVDNetworkRequirements.ps1 -Region eastus2 -ExportJson .\avd-requirements.json
```

---

### Set-AVDFirewall.ps1

**Purpose:** Configures Windows Firewall to block all internet traffic **except** what's required for AVD connectivity.

This script requires **Administrator** privileges and:
- Downloads the latest Azure Service Tags to get current AVD IP ranges
- Creates firewall rules allowing only AVD-required traffic
- Sets default outbound policy to **Block**
- Creates a firewall backup before making changes

**Allowed Traffic:**
- Azure Virtual Desktop client connectivity
- DNS resolution
- DHCP for IP assignment
- NTP for time sync / token validation
- Certificate validation (OCSP, CRL, AIA)

**Parameters:**
| Parameter | Description |
|-----------|-------------|
| `-Enable` | Apply AVD firewall lockdown rules |
| `-Disable` | Remove all AVD rules and restore default Allow policy |

**Examples:**
```powershell
# Lock down firewall to AVD-only traffic
.\Set-AVDFirewall.ps1 -Enable

# Remove AVD rules and restore defaults
.\Set-AVDFirewall.ps1 -Disable
```

**Note:** Re-run periodically to pick up Azure Service Tag IP range changes.

## Sources

- [AVD Required FQDNs and Endpoints](https://learn.microsoft.com/en-us/azure/virtual-desktop/required-fqdn-endpoint?tabs=azure)
- [Azure CA Details](https://learn.microsoft.com/en-us/azure/security/fundamentals/azure-CA-details)
- [Azure Service Tags Download](https://www.microsoft.com/en-us/download/details.aspx?id=56519)
