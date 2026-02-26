#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Flow Log Viewer - Main Entry Point
.DESCRIPTION
    GUI application for viewing and analyzing Azure VNET Flow Logs
.NOTES
    Author: Azure Flow Log Viewer
    Date: 2026-02-03
    Requires: PowerShell 7.0 or later
    
    USAGE: Double-click FlowLogViewer.bat to launch, or run from a regular PowerShell window.
           Do NOT run from VS Code's integrated terminal - use the .bat file instead.
#>

param(
    [switch]$NoRelaunch  # Used to prevent infinite relaunch loop
)

# Verify PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: This script requires PowerShell 7 or later." -ForegroundColor Red
    Write-Host "Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To install PowerShell 7:" -ForegroundColor Cyan
    Write-Host "  winget install Microsoft.PowerShell" -ForegroundColor White
    Write-Host ""
    Write-Host "Or download from: https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# Set script location as working directory
$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ScriptPath)) {
    $ScriptPath = $PWD.Path
}

# Check and install required Azure modules
$requiredModules = @('Az.Accounts', 'Az.Storage')
$missingModules = @()

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        $missingModules += $module
    }
}

if ($missingModules.Count -gt 0) {
    Write-Host "The following required Azure PowerShell modules are missing:" -ForegroundColor Yellow
    foreach ($module in $missingModules) {
        Write-Host "  - $module" -ForegroundColor Yellow
    }
    Write-Host ""
    
    $response = Read-Host "Would you like to install them now? (Y/N)"
    
    if ($response -eq 'Y' -or $response -eq 'y') {
        Write-Host ""
        Write-Host "Installing modules (this may take a few minutes)..." -ForegroundColor Cyan
        
        foreach ($module in $missingModules) {
            Write-Host "Installing $module..." -ForegroundColor White
            try {
                Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                Write-Host "  $module installed successfully" -ForegroundColor Green
            }
            catch {
                Write-Host "  Failed to install $module : $($_.Exception.Message)" -ForegroundColor Red
                Write-Host ""
                Write-Host "Please try installing manually:" -ForegroundColor Yellow
                Write-Host "  Install-Module -Name $module -Scope CurrentUser -Force" -ForegroundColor White
                Write-Host ""
                Read-Host "Press Enter to exit"
                exit 1
            }
        }
        
        Write-Host ""
        Write-Host "All modules installed successfully!" -ForegroundColor Green
        Write-Host ""
    }
    else {
        Write-Host ""
        Write-Host "Cannot continue without required modules." -ForegroundColor Red
        Write-Host ""
        Write-Host "To install manually, run:" -ForegroundColor Cyan
        Write-Host "  Install-Module -Name Az.Accounts -Scope CurrentUser -Force" -ForegroundColor White
        Write-Host "  Install-Module -Name Az.Storage -Scope CurrentUser -Force" -ForegroundColor White
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 1
    }
}

$script:ModulesPath = Join-Path $ScriptPath "Modules"
Set-Location $ScriptPath

# Import required modules
. "$ScriptPath\Modules\AzureFlowLogConnection.ps1"
. "$ScriptPath\Modules\FlowLogParser.ps1"
. "$ScriptPath\Modules\IPFilterManager.ps1"
. "$ScriptPath\Modules\GUIComponents.ps1"
. "$ScriptPath\Modules\IPOwnerLookup.ps1"

# Configuration
$script:Config = @{
    StorageAccountName = ""
    ResourceGroupName = ""
    ContainerName = "insights-logs-flowlogflowevent"
    ExcludedIPs = @()
    ExcludedRanges = @()
    CurrentData = $null
    FilteredData = $null
}

# Add required assemblies for GUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Create main form
$mainForm = New-Object System.Windows.Forms.Form
$mainForm.Text = "Azure Virtual Network Flow Log Viewer"
$mainForm.Size = New-Object System.Drawing.Size(1400, 900)
$mainForm.StartPosition = "CenterScreen"
$mainForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$mainForm.MinimumSize = New-Object System.Drawing.Size(1200, 700)

# Create ToolTip for button hover help
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 10000
$toolTip.InitialDelay = 500
$toolTip.ReshowDelay = 200
$toolTip.ShowAlways = $true

# Create menu strip
$menuStrip = New-Object System.Windows.Forms.MenuStrip

# File Menu
$fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem("File")
$exportCsvMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Export to CSV")
$exportSummaryMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Export Summary Report")
$separatorMenuItem = New-Object System.Windows.Forms.ToolStripSeparator
$exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
$fileMenu.DropDownItems.AddRange(@($exportCsvMenuItem, $exportSummaryMenuItem, $separatorMenuItem, $exitMenuItem))

# Filter Menu
$filterMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Filters")
$manageExclusionsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Manage IP Exclusions")
$clearExclusionsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Clear All Exclusions")
$filterMenu.DropDownItems.AddRange(@($manageExclusionsMenuItem, $clearExclusionsMenuItem))

# View Menu
$viewMenu = New-Object System.Windows.Forms.ToolStripMenuItem("View")
$refreshMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh Data")
$null = $viewMenu.DropDownItems.Add($refreshMenuItem)

# Help Menu
$helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Help")
$aboutMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("About")
$null = $helpMenu.DropDownItems.Add($aboutMenuItem)

$menuStrip.Items.AddRange(@($fileMenu, $filterMenu, $viewMenu, $helpMenu))
$mainForm.MainMenuStrip = $menuStrip
$mainForm.Controls.Add($menuStrip)

# Create status strip
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel("Ready")
$statusLabel.Spring = $true
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$progressBar = New-Object System.Windows.Forms.ToolStripProgressBar
$progressBar.Visible = $false
$statusStrip.Items.AddRange(@($statusLabel, $progressBar))
$mainForm.Controls.Add($statusStrip)

# Create main split container
$mainSplitContainer = New-Object System.Windows.Forms.SplitContainer
$mainSplitContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainSplitContainer.Orientation = [System.Windows.Forms.Orientation]::Horizontal
# Set minimal sizes - SplitterDistance will be set in form Load event
$mainSplitContainer.Panel1MinSize = 50
$mainSplitContainer.Panel2MinSize = 50

# Top panel - Controls
$controlPanel = New-Object System.Windows.Forms.Panel
$controlPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$controlPanel.Padding = New-Object System.Windows.Forms.Padding(10)

# Date range group box
$dateGroupBox = New-Object System.Windows.Forms.GroupBox
$dateGroupBox.Text = "Date Range"
$dateGroupBox.Location = New-Object System.Drawing.Point(10, 5)
$dateGroupBox.Size = New-Object System.Drawing.Size(510, 100)

$lblStartDate = New-Object System.Windows.Forms.Label
$lblStartDate.Text = "Start Date:"
$lblStartDate.Location = New-Object System.Drawing.Point(10, 25)
$lblStartDate.AutoSize = $true

$dtpStartDate = New-Object System.Windows.Forms.DateTimePicker
$dtpStartDate.Location = New-Object System.Drawing.Point(80, 22)
$dtpStartDate.Size = New-Object System.Drawing.Size(130, 23)
$dtpStartDate.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$dtpStartDate.CustomFormat = "yyyy-MM-dd"
$dtpStartDate.Value = (Get-Date).AddDays(-7)

$lblEndDate = New-Object System.Windows.Forms.Label
$lblEndDate.Text = "End Date:"
$lblEndDate.Location = New-Object System.Drawing.Point(220, 25)
$lblEndDate.AutoSize = $true

$dtpEndDate = New-Object System.Windows.Forms.DateTimePicker
$dtpEndDate.Location = New-Object System.Drawing.Point(290, 22)
$dtpEndDate.Size = New-Object System.Drawing.Size(130, 23)
$dtpEndDate.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$dtpEndDate.CustomFormat = "yyyy-MM-dd"
$dtpEndDate.Value = Get-Date

$lblQuickRange = New-Object System.Windows.Forms.Label
$lblQuickRange.Text = "Quick Select:"
$lblQuickRange.Location = New-Object System.Drawing.Point(10, 58)
$lblQuickRange.AutoSize = $true

$cmbQuickRange = New-Object System.Windows.Forms.ComboBox
$cmbQuickRange.Location = New-Object System.Drawing.Point(90, 55)
$cmbQuickRange.Size = New-Object System.Drawing.Size(120, 23)
$cmbQuickRange.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbQuickRange.Items.AddRange(@("Custom", "Today", "Yesterday", "Last 7 Days", "Last 30 Days", "This Month", "Last Month"))
$cmbQuickRange.SelectedIndex = 3

$btnLoadData = New-Object System.Windows.Forms.Button
$btnLoadData.Text = "Load Data"
$btnLoadData.Location = New-Object System.Drawing.Point(350, 53)
$btnLoadData.Size = New-Object System.Drawing.Size(80, 28)
$btnLoadData.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnLoadData.ForeColor = [System.Drawing.Color]::White
$btnLoadData.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$btnCancelLoad = New-Object System.Windows.Forms.Button
$btnCancelLoad.Text = "Cancel"
$btnCancelLoad.Location = New-Object System.Drawing.Point(435, 53)
$btnCancelLoad.Size = New-Object System.Drawing.Size(60, 28)
$btnCancelLoad.Enabled = $false
$btnCancelLoad.BackColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
$btnCancelLoad.ForeColor = [System.Drawing.Color]::White
$btnCancelLoad.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$dateGroupBox.Controls.AddRange(@($lblStartDate, $dtpStartDate, $lblEndDate, $dtpEndDate, $lblQuickRange, $cmbQuickRange, $btnLoadData, $btnCancelLoad))

# Filter group box
$filterGroupBox = New-Object System.Windows.Forms.GroupBox
$filterGroupBox.Text = "Quick Filters"
$filterGroupBox.Location = New-Object System.Drawing.Point(530, 5)
$filterGroupBox.Size = New-Object System.Drawing.Size(590, 100)

$lblSearchIP = New-Object System.Windows.Forms.Label
$lblSearchIP.Text = "Search IP:"
$lblSearchIP.Location = New-Object System.Drawing.Point(10, 25)
$lblSearchIP.AutoSize = $true

$txtSearchIP = New-Object System.Windows.Forms.TextBox
$txtSearchIP.Location = New-Object System.Drawing.Point(80, 22)
$txtSearchIP.Size = New-Object System.Drawing.Size(120, 23)

$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Text = "Search"
$btnSearch.Location = New-Object System.Drawing.Point(205, 20)
$btnSearch.Size = New-Object System.Drawing.Size(60, 25)

$btnClearSearch = New-Object System.Windows.Forms.Button
$btnClearSearch.Text = "Clear"
$btnClearSearch.Location = New-Object System.Drawing.Point(270, 20)
$btnClearSearch.Size = New-Object System.Drawing.Size(45, 25)

$lblSrcPort = New-Object System.Windows.Forms.Label
$lblSrcPort.Text = "Src Port:"
$lblSrcPort.Location = New-Object System.Drawing.Point(325, 25)
$lblSrcPort.AutoSize = $true

$txtSrcPort = New-Object System.Windows.Forms.TextBox
$txtSrcPort.Location = New-Object System.Drawing.Point(385, 22)
$txtSrcPort.Size = New-Object System.Drawing.Size(60, 23)

$lblDstPort = New-Object System.Windows.Forms.Label
$lblDstPort.Text = "Dst Port:"
$lblDstPort.Location = New-Object System.Drawing.Point(455, 25)
$lblDstPort.AutoSize = $true

$txtDstPort = New-Object System.Windows.Forms.TextBox
$txtDstPort.Location = New-Object System.Drawing.Point(515, 22)
$txtDstPort.Size = New-Object System.Drawing.Size(60, 23)

$lblDirection = New-Object System.Windows.Forms.Label
$lblDirection.Text = "Direction:"
$lblDirection.Location = New-Object System.Drawing.Point(10, 58)
$lblDirection.AutoSize = $true

$cmbDirection = New-Object System.Windows.Forms.ComboBox
$cmbDirection.Location = New-Object System.Drawing.Point(80, 55)
$cmbDirection.Size = New-Object System.Drawing.Size(100, 23)
$cmbDirection.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbDirection.Items.AddRange(@("All", "Inbound", "Outbound"))
$cmbDirection.SelectedIndex = 0

$lblAction = New-Object System.Windows.Forms.Label
$lblAction.Text = "Action:"
$lblAction.Location = New-Object System.Drawing.Point(190, 58)
$lblAction.AutoSize = $true

$cmbAction = New-Object System.Windows.Forms.ComboBox
$cmbAction.Location = New-Object System.Drawing.Point(240, 55)
$cmbAction.Size = New-Object System.Drawing.Size(100, 23)
$cmbAction.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbAction.Items.AddRange(@("All", "Allow", "Deny"))
$cmbAction.SelectedIndex = 0

$filterGroupBox.Controls.AddRange(@($lblSearchIP, $txtSearchIP, $btnSearch, $btnClearSearch, $lblSrcPort, $txtSrcPort, $lblDstPort, $txtDstPort, $lblDirection, $cmbDirection, $lblAction, $cmbAction))

$controlPanel.Controls.AddRange(@($dateGroupBox, $filterGroupBox))
$mainSplitContainer.Panel1.Controls.Add($controlPanel)

# Bottom panel - Tab control with data views
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill

# Tab 1: Flow Log Details
$tabFlowLogs = New-Object System.Windows.Forms.TabPage
$tabFlowLogs.Text = "Flow Log Details"
$tabFlowLogs.Padding = New-Object System.Windows.Forms.Padding(5)

$dgvFlowLogs = New-Object System.Windows.Forms.DataGridView
$dgvFlowLogs.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvFlowLogs.AllowUserToAddRows = $false
$dgvFlowLogs.AllowUserToDeleteRows = $false
$dgvFlowLogs.ReadOnly = $true
$dgvFlowLogs.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvFlowLogs.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvFlowLogs.MultiSelect = $true
$dgvFlowLogs.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$dgvFlowLogs.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$dgvFlowLogs.EnableHeadersVisualStyles = $false
$dgvFlowLogs.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$dgvFlowLogs.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White

$tabFlowLogs.Controls.Add($dgvFlowLogs)

# Tab 2: IP Summary
$tabIPSummary = New-Object System.Windows.Forms.TabPage
$tabIPSummary.Text = "IP Summary"
$tabIPSummary.Padding = New-Object System.Windows.Forms.Padding(5)

$splitIPSummary = New-Object System.Windows.Forms.SplitContainer
$splitIPSummary.Dock = [System.Windows.Forms.DockStyle]::Fill
$splitIPSummary.Orientation = [System.Windows.Forms.Orientation]::Vertical
$splitIPSummary.SplitterDistance = 500

$dgvIPSummary = New-Object System.Windows.Forms.DataGridView
$dgvIPSummary.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvIPSummary.AllowUserToAddRows = $false
$dgvIPSummary.AllowUserToDeleteRows = $false
$dgvIPSummary.ReadOnly = $true
$dgvIPSummary.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvIPSummary.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvIPSummary.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$dgvIPSummary.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$dgvIPSummary.EnableHeadersVisualStyles = $false
$dgvIPSummary.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$dgvIPSummary.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White

# Right-click context menu for IP Summary
$contextMenuIP = New-Object System.Windows.Forms.ContextMenuStrip
$excludeIPMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exclude Selected IP(s)")
$copyIPMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Copy IP Address")
$lookupIPOwnerMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Lookup IP Owner")
$contextMenuIP.Items.AddRange(@($excludeIPMenuItem, $copyIPMenuItem, $lookupIPOwnerMenuItem))
$dgvIPSummary.ContextMenuStrip = $contextMenuIP

$splitIPSummary.Panel1.Controls.Add($dgvIPSummary)

# Statistics panel
$statsPanel = New-Object System.Windows.Forms.Panel
$statsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$statsPanel.AutoScroll = $true

$lblStatsTitle = New-Object System.Windows.Forms.Label
$lblStatsTitle.Text = "Statistics Summary"
$lblStatsTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblStatsTitle.Location = New-Object System.Drawing.Point(10, 10)
$lblStatsTitle.AutoSize = $true

$txtStats = New-Object System.Windows.Forms.RichTextBox
$txtStats.Location = New-Object System.Drawing.Point(10, 40)
$txtStats.Size = New-Object System.Drawing.Size(400, 450)
$txtStats.ReadOnly = $true
$txtStats.BackColor = [System.Drawing.Color]::White
$txtStats.Font = New-Object System.Drawing.Font("Consolas", 10)

$statsPanel.Controls.AddRange(@($lblStatsTitle, $txtStats))
$splitIPSummary.Panel2.Controls.Add($statsPanel)

$tabIPSummary.Controls.Add($splitIPSummary)

# Tab 3: Daily/Monthly Summary
$tabTimeSummary = New-Object System.Windows.Forms.TabPage
$tabTimeSummary.Text = "Time-Based Summary"
$tabTimeSummary.Padding = New-Object System.Windows.Forms.Padding(5)

$splitTimeSummary = New-Object System.Windows.Forms.SplitContainer
$splitTimeSummary.Dock = [System.Windows.Forms.DockStyle]::Fill
$splitTimeSummary.Orientation = [System.Windows.Forms.Orientation]::Vertical
$splitTimeSummary.SplitterDistance = 500

$panelTimeControls = New-Object System.Windows.Forms.Panel
$panelTimeControls.Dock = [System.Windows.Forms.DockStyle]::Top
$panelTimeControls.Height = 40

$lblGroupBy = New-Object System.Windows.Forms.Label
$lblGroupBy.Text = "Group By:"
$lblGroupBy.Location = New-Object System.Drawing.Point(10, 10)
$lblGroupBy.AutoSize = $true

$cmbGroupBy = New-Object System.Windows.Forms.ComboBox
$cmbGroupBy.Location = New-Object System.Drawing.Point(80, 7)
$cmbGroupBy.Size = New-Object System.Drawing.Size(120, 23)
$cmbGroupBy.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbGroupBy.Items.AddRange(@("Daily", "Monthly", "Hourly"))
$cmbGroupBy.SelectedIndex = 0

$panelTimeControls.Controls.AddRange(@($lblGroupBy, $cmbGroupBy))

$dgvTimeSummary = New-Object System.Windows.Forms.DataGridView
$dgvTimeSummary.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvTimeSummary.AllowUserToAddRows = $false
$dgvTimeSummary.AllowUserToDeleteRows = $false
$dgvTimeSummary.ReadOnly = $true
$dgvTimeSummary.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvTimeSummary.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvTimeSummary.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$dgvTimeSummary.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$dgvTimeSummary.EnableHeadersVisualStyles = $false
$dgvTimeSummary.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$dgvTimeSummary.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White

$panelTimeGrid = New-Object System.Windows.Forms.Panel
$panelTimeGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$panelTimeGrid.Controls.Add($dgvTimeSummary)
$panelTimeGrid.Controls.Add($panelTimeControls)

$splitTimeSummary.Panel1.Controls.Add($panelTimeGrid)

# IP per time period panel
$dgvIPPerTime = New-Object System.Windows.Forms.DataGridView
$dgvIPPerTime.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvIPPerTime.AllowUserToAddRows = $false
$dgvIPPerTime.AllowUserToDeleteRows = $false
$dgvIPPerTime.ReadOnly = $true
$dgvIPPerTime.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvIPPerTime.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvIPPerTime.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$dgvIPPerTime.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$dgvIPPerTime.EnableHeadersVisualStyles = $false
$dgvIPPerTime.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$dgvIPPerTime.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White

$splitTimeSummary.Panel2.Controls.Add($dgvIPPerTime)
$tabTimeSummary.Controls.Add($splitTimeSummary)

# Tab 4: Exclusions Management
$tabExclusions = New-Object System.Windows.Forms.TabPage
$tabExclusions.Text = "IP Exclusions"
$tabExclusions.Padding = New-Object System.Windows.Forms.Padding(10)

# Main panel for exclusions - use FlowLayoutPanel for side-by-side layout
$pnlExclusions = New-Object System.Windows.Forms.Panel
$pnlExclusions.Dock = [System.Windows.Forms.DockStyle]::Fill
$pnlExclusions.AutoScroll = $true

# Single IP exclusions - Left side
$grpSingleIP = New-Object System.Windows.Forms.GroupBox
$grpSingleIP.Text = "Excluded IP Addresses"
$grpSingleIP.Location = New-Object System.Drawing.Point(10, 10)
$grpSingleIP.Size = New-Object System.Drawing.Size(350, 280)

$lstExcludedIPs = New-Object System.Windows.Forms.ListBox
$lstExcludedIPs.Location = New-Object System.Drawing.Point(10, 25)
$lstExcludedIPs.Size = New-Object System.Drawing.Size(220, 200)
$lstExcludedIPs.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended

$txtAddIP = New-Object System.Windows.Forms.TextBox
$txtAddIP.Location = New-Object System.Drawing.Point(10, 235)
$txtAddIP.Size = New-Object System.Drawing.Size(150, 23)

$btnAddIP = New-Object System.Windows.Forms.Button
$btnAddIP.Text = "Add IP"
$btnAddIP.Location = New-Object System.Drawing.Point(170, 233)
$btnAddIP.Size = New-Object System.Drawing.Size(80, 25)

$btnRemoveIP = New-Object System.Windows.Forms.Button
$btnRemoveIP.Text = "Remove"
$btnRemoveIP.Location = New-Object System.Drawing.Point(255, 233)
$btnRemoveIP.Size = New-Object System.Drawing.Size(85, 25)

$grpSingleIP.Controls.AddRange(@($lstExcludedIPs, $txtAddIP, $btnAddIP, $btnRemoveIP))
$pnlExclusions.Controls.Add($grpSingleIP)

# IP Range exclusions - Right side (next to IP addresses)
$grpIPRange = New-Object System.Windows.Forms.GroupBox
$grpIPRange.Text = "Excluded IP Ranges (CIDR Notation)"
$grpIPRange.Location = New-Object System.Drawing.Point(370, 10)
$grpIPRange.Size = New-Object System.Drawing.Size(350, 280)

$lstExcludedRanges = New-Object System.Windows.Forms.ListBox
$lstExcludedRanges.Location = New-Object System.Drawing.Point(10, 25)
$lstExcludedRanges.Size = New-Object System.Drawing.Size(220, 200)
$lstExcludedRanges.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended

$txtAddRange = New-Object System.Windows.Forms.TextBox
$txtAddRange.Location = New-Object System.Drawing.Point(10, 235)
$txtAddRange.Size = New-Object System.Drawing.Size(150, 23)

$lblRangeExample = New-Object System.Windows.Forms.Label
$lblRangeExample.Text = "e.g. 10.0.0.0/8"
$lblRangeExample.Location = New-Object System.Drawing.Point(240, 60)
$lblRangeExample.AutoSize = $true
$lblRangeExample.ForeColor = [System.Drawing.Color]::Gray

$btnAddRange = New-Object System.Windows.Forms.Button
$btnAddRange.Text = "Add Range"
$btnAddRange.Location = New-Object System.Drawing.Point(170, 233)
$btnAddRange.Size = New-Object System.Drawing.Size(80, 25)

$btnRemoveRange = New-Object System.Windows.Forms.Button
$btnRemoveRange.Text = "Remove"
$btnRemoveRange.Location = New-Object System.Drawing.Point(255, 233)
$btnRemoveRange.Size = New-Object System.Drawing.Size(85, 25)

$grpIPRange.Controls.AddRange(@($lstExcludedRanges, $txtAddRange, $lblRangeExample, $btnAddRange, $btnRemoveRange))
$pnlExclusions.Controls.Add($grpIPRange)

# Action buttons - Below both groups
$btnApplyExclusions = New-Object System.Windows.Forms.Button
$btnApplyExclusions.Text = "Apply Exclusions"
$btnApplyExclusions.Location = New-Object System.Drawing.Point(10, 300)
$btnApplyExclusions.Size = New-Object System.Drawing.Size(130, 35)
$btnApplyExclusions.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnApplyExclusions.ForeColor = [System.Drawing.Color]::White
$btnApplyExclusions.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$btnSaveExclusions = New-Object System.Windows.Forms.Button
$btnSaveExclusions.Text = "Save Exclusions"
$btnSaveExclusions.Location = New-Object System.Drawing.Point(150, 300)
$btnSaveExclusions.Size = New-Object System.Drawing.Size(130, 35)

$btnLoadExclusions = New-Object System.Windows.Forms.Button
$btnLoadExclusions.Text = "Load Exclusions"
$btnLoadExclusions.Location = New-Object System.Drawing.Point(290, 300)
$btnLoadExclusions.Size = New-Object System.Drawing.Size(130, 35)

$btnAddAzureRanges = New-Object System.Windows.Forms.Button
$btnAddAzureRanges.Text = "Add Azure IP Ranges"
$btnAddAzureRanges.Location = New-Object System.Drawing.Point(430, 300)
$btnAddAzureRanges.Size = New-Object System.Drawing.Size(150, 35)

$btnClearExclusions = New-Object System.Windows.Forms.Button
$btnClearExclusions.Text = "Clear All"
$btnClearExclusions.Location = New-Object System.Drawing.Point(590, 300)
$btnClearExclusions.Size = New-Object System.Drawing.Size(100, 35)
$btnClearExclusions.ForeColor = [System.Drawing.Color]::DarkRed

$pnlExclusions.Controls.AddRange(@($btnApplyExclusions, $btnSaveExclusions, $btnLoadExclusions, $btnAddAzureRanges, $btnClearExclusions))

$tabExclusions.Controls.Add($pnlExclusions)

# Tab 5: IP Owners
$tabIPOwners = New-Object System.Windows.Forms.TabPage
$tabIPOwners.Text = "IP Owners"
$tabIPOwners.Padding = New-Object System.Windows.Forms.Padding(5)

$splitIPOwners = New-Object System.Windows.Forms.SplitContainer
$splitIPOwners.Dock = [System.Windows.Forms.DockStyle]::Fill
$splitIPOwners.Orientation = [System.Windows.Forms.Orientation]::Vertical
$splitIPOwners.SplitterDistance = 700

# IP Owners control panel
$pnlIPOwnersControls = New-Object System.Windows.Forms.Panel
$pnlIPOwnersControls.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlIPOwnersControls.Height = 50

$btnLookupIPOwners = New-Object System.Windows.Forms.Button
$btnLookupIPOwners.Text = "Lookup All Public IP Owners"
$btnLookupIPOwners.Location = New-Object System.Drawing.Point(10, 10)
$btnLookupIPOwners.Size = New-Object System.Drawing.Size(200, 30)
$btnLookupIPOwners.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnLookupIPOwners.ForeColor = [System.Drawing.Color]::White
$btnLookupIPOwners.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$btnClearIPOwnerCache = New-Object System.Windows.Forms.Button
$btnClearIPOwnerCache.Text = "Clear Cache"
$btnClearIPOwnerCache.Location = New-Object System.Drawing.Point(220, 10)
$btnClearIPOwnerCache.Size = New-Object System.Drawing.Size(100, 30)

$btnExportIPOwners = New-Object System.Windows.Forms.Button
$btnExportIPOwners.Text = "Export to CSV"
$btnExportIPOwners.Location = New-Object System.Drawing.Point(330, 10)
$btnExportIPOwners.Size = New-Object System.Drawing.Size(100, 30)

$lblIPOwnerNote = New-Object System.Windows.Forms.Label
$lblIPOwnerNote.Text = "Uses ip-api.com (free, no API key). Private IPs are automatically skipped."
$lblIPOwnerNote.Location = New-Object System.Drawing.Point(445, 17)
$lblIPOwnerNote.AutoSize = $true
$lblIPOwnerNote.ForeColor = [System.Drawing.Color]::Gray

$pnlIPOwnersControls.Controls.AddRange(@($btnLookupIPOwners, $btnClearIPOwnerCache, $btnExportIPOwners, $lblIPOwnerNote))

# IP Owners DataGridView
$dgvIPOwners = New-Object System.Windows.Forms.DataGridView
$dgvIPOwners.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvIPOwners.AllowUserToAddRows = $false
$dgvIPOwners.AllowUserToDeleteRows = $false
$dgvIPOwners.ReadOnly = $true
$dgvIPOwners.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvIPOwners.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvIPOwners.MultiSelect = $true
$dgvIPOwners.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$dgvIPOwners.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$dgvIPOwners.EnableHeadersVisualStyles = $false
$dgvIPOwners.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$dgvIPOwners.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White

# Context menu for IP Owners grid
$contextMenuIPOwners = New-Object System.Windows.Forms.ContextMenuStrip
$copyIPOwnerMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Copy IP Address")
$copyOwnerInfoMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Copy Owner Info")
$contextMenuIPOwners.Items.AddRange(@($copyIPOwnerMenuItem, $copyOwnerInfoMenuItem))
$dgvIPOwners.ContextMenuStrip = $contextMenuIPOwners

$pnlIPOwnersGrid = New-Object System.Windows.Forms.Panel
$pnlIPOwnersGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$pnlIPOwnersGrid.Controls.Add($dgvIPOwners)
$pnlIPOwnersGrid.Controls.Add($pnlIPOwnersControls)

$splitIPOwners.Panel1.Controls.Add($pnlIPOwnersGrid)

# IP Owner stats panel
$pnlIPOwnerStats = New-Object System.Windows.Forms.Panel
$pnlIPOwnerStats.Dock = [System.Windows.Forms.DockStyle]::Fill
$pnlIPOwnerStats.AutoScroll = $true

$lblIPOwnerStatsTitle = New-Object System.Windows.Forms.Label
$lblIPOwnerStatsTitle.Text = "IP Owner Statistics"
$lblIPOwnerStatsTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblIPOwnerStatsTitle.Location = New-Object System.Drawing.Point(10, 10)
$lblIPOwnerStatsTitle.AutoSize = $true

$txtIPOwnerStats = New-Object System.Windows.Forms.RichTextBox
$txtIPOwnerStats.Location = New-Object System.Drawing.Point(10, 40)
$txtIPOwnerStats.Size = New-Object System.Drawing.Size(400, 450)
$txtIPOwnerStats.ReadOnly = $true
$txtIPOwnerStats.BackColor = [System.Drawing.Color]::White
$txtIPOwnerStats.Font = New-Object System.Drawing.Font("Consolas", 10)

$pnlIPOwnerStats.Controls.AddRange(@($lblIPOwnerStatsTitle, $txtIPOwnerStats))
$splitIPOwners.Panel2.Controls.Add($pnlIPOwnerStats)

$tabIPOwners.Controls.Add($splitIPOwners)

# Tab 6: Port Summary
$tabPortSummary = New-Object System.Windows.Forms.TabPage
$tabPortSummary.Text = "Port Summary"
$tabPortSummary.Padding = New-Object System.Windows.Forms.Padding(5)

$splitPortSummary = New-Object System.Windows.Forms.SplitContainer
$splitPortSummary.Dock = [System.Windows.Forms.DockStyle]::Fill
$splitPortSummary.Orientation = [System.Windows.Forms.Orientation]::Vertical
$splitPortSummary.SplitterDistance = 500

# Port Summary DataGridView
$dgvPortSummary = New-Object System.Windows.Forms.DataGridView
$dgvPortSummary.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvPortSummary.AllowUserToAddRows = $false
$dgvPortSummary.AllowUserToDeleteRows = $false
$dgvPortSummary.ReadOnly = $true
$dgvPortSummary.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvPortSummary.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvPortSummary.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$dgvPortSummary.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$dgvPortSummary.EnableHeadersVisualStyles = $false
$dgvPortSummary.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$dgvPortSummary.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White

$splitPortSummary.Panel1.Controls.Add($dgvPortSummary)

# Port filter panel
$pnlPortFilter = New-Object System.Windows.Forms.Panel
$pnlPortFilter.Dock = [System.Windows.Forms.DockStyle]::Fill
$pnlPortFilter.AutoScroll = $true

$lblPortFilterTitle = New-Object System.Windows.Forms.Label
$lblPortFilterTitle.Text = "Filter by Port"
$lblPortFilterTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblPortFilterTitle.Location = New-Object System.Drawing.Point(10, 10)
$lblPortFilterTitle.AutoSize = $true

$lblFilterPort = New-Object System.Windows.Forms.Label
$lblFilterPort.Text = "Port Number:"
$lblFilterPort.Location = New-Object System.Drawing.Point(10, 50)
$lblFilterPort.AutoSize = $true

$txtFilterPort = New-Object System.Windows.Forms.TextBox
$txtFilterPort.Location = New-Object System.Drawing.Point(100, 47)
$txtFilterPort.Size = New-Object System.Drawing.Size(80, 23)

$lblPortType = New-Object System.Windows.Forms.Label
$lblPortType.Text = "Port Type:"
$lblPortType.Location = New-Object System.Drawing.Point(200, 50)
$lblPortType.AutoSize = $true

$cmbPortType = New-Object System.Windows.Forms.ComboBox
$cmbPortType.Location = New-Object System.Drawing.Point(275, 47)
$cmbPortType.Size = New-Object System.Drawing.Size(120, 23)
$cmbPortType.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbPortType.Items.AddRange(@("Both", "Source Port", "Destination Port"))
$cmbPortType.SelectedIndex = 0

$btnFilterByPort = New-Object System.Windows.Forms.Button
$btnFilterByPort.Text = "Filter by Port"
$btnFilterByPort.Location = New-Object System.Drawing.Point(10, 85)
$btnFilterByPort.Size = New-Object System.Drawing.Size(120, 30)
$btnFilterByPort.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnFilterByPort.ForeColor = [System.Drawing.Color]::White
$btnFilterByPort.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$btnShowAllPorts = New-Object System.Windows.Forms.Button
$btnShowAllPorts.Text = "Show All"
$btnShowAllPorts.Location = New-Object System.Drawing.Point(140, 85)
$btnShowAllPorts.Size = New-Object System.Drawing.Size(100, 30)

# Common ports quick filter
$lblCommonPorts = New-Object System.Windows.Forms.Label
$lblCommonPorts.Text = "Common Ports:"
$lblCommonPorts.Location = New-Object System.Drawing.Point(10, 130)
$lblCommonPorts.AutoSize = $true

$cmbCommonPorts = New-Object System.Windows.Forms.ComboBox
$cmbCommonPorts.Location = New-Object System.Drawing.Point(110, 127)
$cmbCommonPorts.Size = New-Object System.Drawing.Size(200, 23)
$cmbCommonPorts.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbCommonPorts.Items.AddRange(@(
    "-- Select --",
    "22 - SSH",
    "23 - Telnet",
    "25 - SMTP",
    "53 - DNS",
    "80 - HTTP",
    "110 - POP3",
    "143 - IMAP",
    "443 - HTTPS",
    "445 - SMB",
    "587 - SMTP (Submission)",
    "993 - IMAPS",
    "995 - POP3S",
    "1433 - SQL Server",
    "1521 - Oracle",
    "3306 - MySQL",
    "3389 - RDP",
    "5432 - PostgreSQL",
    "5985 - WinRM HTTP",
    "5986 - WinRM HTTPS",
    "8080 - HTTP Alt",
    "8443 - HTTPS Alt"
))
$cmbCommonPorts.SelectedIndex = 0

# Port statistics text box
$lblPortStats = New-Object System.Windows.Forms.Label
$lblPortStats.Text = "Port Statistics:"
$lblPortStats.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblPortStats.Location = New-Object System.Drawing.Point(10, 170)
$lblPortStats.AutoSize = $true

$txtPortStats = New-Object System.Windows.Forms.RichTextBox
$txtPortStats.Location = New-Object System.Drawing.Point(10, 195)
$txtPortStats.Size = New-Object System.Drawing.Size(400, 250)
$txtPortStats.ReadOnly = $true
$txtPortStats.BackColor = [System.Drawing.Color]::White
$txtPortStats.Font = New-Object System.Drawing.Font("Consolas", 10)

$pnlPortFilter.Controls.AddRange(@($lblPortFilterTitle, $lblFilterPort, $txtFilterPort, $lblPortType, $cmbPortType, $btnFilterByPort, $btnShowAllPorts, $lblCommonPorts, $cmbCommonPorts, $lblPortStats, $txtPortStats))
$splitPortSummary.Panel2.Controls.Add($pnlPortFilter)

$tabPortSummary.Controls.Add($splitPortSummary)

# Tab 7: Connection
$tabConnection = New-Object System.Windows.Forms.TabPage
$tabConnection.Text = "Connection"
$tabConnection.Padding = New-Object System.Windows.Forms.Padding(10)

$pnlConnection = New-Object System.Windows.Forms.Panel
$pnlConnection.Dock = [System.Windows.Forms.DockStyle]::Fill
$pnlConnection.AutoScroll = $true

# Azure Sign-In Section
$grpAzureSignIn = New-Object System.Windows.Forms.GroupBox
$grpAzureSignIn.Text = "Step 1: Sign in to Azure"
$grpAzureSignIn.Location = New-Object System.Drawing.Point(10, 10)
$grpAzureSignIn.Size = New-Object System.Drawing.Size(400, 80)

$lblSignInStatus = New-Object System.Windows.Forms.Label
$lblSignInStatus.Text = "Not connected to Azure"
$lblSignInStatus.Location = New-Object System.Drawing.Point(15, 30)
$lblSignInStatus.Size = New-Object System.Drawing.Size(250, 20)
$lblSignInStatus.ForeColor = [System.Drawing.Color]::Gray

$btnAzureSignIn = New-Object System.Windows.Forms.Button
$btnAzureSignIn.Text = "Sign In to Azure"
$btnAzureSignIn.Location = New-Object System.Drawing.Point(280, 25)
$btnAzureSignIn.Size = New-Object System.Drawing.Size(105, 30)
$btnAzureSignIn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnAzureSignIn.ForeColor = [System.Drawing.Color]::White
$btnAzureSignIn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$grpAzureSignIn.Controls.AddRange(@($lblSignInStatus, $btnAzureSignIn))

# Subscription Selection
$grpSubscription = New-Object System.Windows.Forms.GroupBox
$grpSubscription.Text = "Step 2: Select Subscription with Flow Logs"
$grpSubscription.Location = New-Object System.Drawing.Point(10, 100)
$grpSubscription.Size = New-Object System.Drawing.Size(400, 70)

$lblSubscription = New-Object System.Windows.Forms.Label
$lblSubscription.Text = "Subscription:"
$lblSubscription.Location = New-Object System.Drawing.Point(15, 30)
$lblSubscription.AutoSize = $true

$cmbSubscription = New-Object System.Windows.Forms.ComboBox
$cmbSubscription.Location = New-Object System.Drawing.Point(100, 27)
$cmbSubscription.Size = New-Object System.Drawing.Size(285, 23)
$cmbSubscription.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbSubscription.Enabled = $false

$grpSubscription.Controls.AddRange(@($lblSubscription, $cmbSubscription))

# Storage Account Selection
$grpStorageAccount = New-Object System.Windows.Forms.GroupBox
$grpStorageAccount.Text = "Step 3: Select Flow Log Storage Account"
$grpStorageAccount.Location = New-Object System.Drawing.Point(10, 180)
$grpStorageAccount.Size = New-Object System.Drawing.Size(400, 70)

$lblStorageAcct = New-Object System.Windows.Forms.Label
$lblStorageAcct.Text = "Storage Account:"
$lblStorageAcct.Location = New-Object System.Drawing.Point(15, 30)
$lblStorageAcct.AutoSize = $true

$cmbStorageAccount = New-Object System.Windows.Forms.ComboBox
$cmbStorageAccount.Location = New-Object System.Drawing.Point(120, 27)
$cmbStorageAccount.Size = New-Object System.Drawing.Size(265, 23)
$cmbStorageAccount.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbStorageAccount.Enabled = $false

$grpStorageAccount.Controls.AddRange(@($lblStorageAcct, $cmbStorageAccount))

# Container Selection
$grpContainer = New-Object System.Windows.Forms.GroupBox
$grpContainer.Text = "Step 4: Select Container containing Flow Logs"
$grpContainer.Location = New-Object System.Drawing.Point(10, 260)
$grpContainer.Size = New-Object System.Drawing.Size(400, 70)

$lblContainerSelect = New-Object System.Windows.Forms.Label
$lblContainerSelect.Text = "Container:"
$lblContainerSelect.Location = New-Object System.Drawing.Point(15, 30)
$lblContainerSelect.AutoSize = $true

$cmbContainer = New-Object System.Windows.Forms.ComboBox
$cmbContainer.Location = New-Object System.Drawing.Point(100, 27)
$cmbContainer.Size = New-Object System.Drawing.Size(285, 23)
$cmbContainer.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbContainer.Enabled = $false

$grpContainer.Controls.AddRange(@($lblContainerSelect, $cmbContainer))

# Connection Summary
$grpConnectionSummary = New-Object System.Windows.Forms.GroupBox
$grpConnectionSummary.Text = "Connection Summary"
$grpConnectionSummary.Location = New-Object System.Drawing.Point(10, 340)
$grpConnectionSummary.Size = New-Object System.Drawing.Size(400, 120)

$txtConnectionSummary = New-Object System.Windows.Forms.TextBox
$txtConnectionSummary.Location = New-Object System.Drawing.Point(15, 25)
$txtConnectionSummary.Size = New-Object System.Drawing.Size(370, 80)
$txtConnectionSummary.Multiline = $true
$txtConnectionSummary.ReadOnly = $true
$txtConnectionSummary.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtConnectionSummary.Text = "Not connected"
$txtConnectionSummary.BackColor = [System.Drawing.Color]::White

$grpConnectionSummary.Controls.Add($txtConnectionSummary)

$pnlConnection.Controls.AddRange(@($grpAzureSignIn, $grpSubscription, $grpStorageAccount, $grpContainer, $grpConnectionSummary))
$tabConnection.Controls.Add($pnlConnection)

# Add tabs to tab control
$tabControl.TabPages.AddRange(@($tabConnection, $tabFlowLogs, $tabIPSummary, $tabIPOwners, $tabTimeSummary, $tabPortSummary, $tabExclusions))

$mainSplitContainer.Panel2.Controls.Add($tabControl)
$mainForm.Controls.Add($mainSplitContainer)

# ============================================
# EVENT HANDLERS
# ============================================

# Flag to prevent recursive date change events
$script:UpdatingDatesFromQuickSelect = $false

# When user manually changes dates, set Quick Select to Custom
$dtpStartDate.Add_ValueChanged({
    if (-not $script:UpdatingDatesFromQuickSelect) {
        $cmbQuickRange.SelectedIndex = 0  # "Custom"
    }
})

$dtpEndDate.Add_ValueChanged({
    if (-not $script:UpdatingDatesFromQuickSelect) {
        $cmbQuickRange.SelectedIndex = 0  # "Custom"
    }
})

# Quick date range selection
$cmbQuickRange.Add_SelectedIndexChanged({
    if ($cmbQuickRange.SelectedItem -eq "Custom") { return }
    
    $script:UpdatingDatesFromQuickSelect = $true
    try {
        switch ($cmbQuickRange.SelectedItem) {
            "Today" {
                $dtpStartDate.Value = (Get-Date).Date
                $dtpEndDate.Value = Get-Date
            }
            "Yesterday" {
                $dtpStartDate.Value = (Get-Date).AddDays(-1).Date
                $dtpEndDate.Value = (Get-Date).AddDays(-1).Date.AddHours(23).AddMinutes(59).AddSeconds(59)
            }
            "Last 7 Days" {
                $dtpStartDate.Value = (Get-Date).AddDays(-7)
                $dtpEndDate.Value = Get-Date
            }
            "Last 30 Days" {
                $dtpStartDate.Value = (Get-Date).AddDays(-30)
                $dtpEndDate.Value = Get-Date
            }
            "This Month" {
                $dtpStartDate.Value = Get-Date -Day 1
                $dtpEndDate.Value = Get-Date
            }
            "Last Month" {
                $firstOfThisMonth = Get-Date -Day 1
                $dtpStartDate.Value = $firstOfThisMonth.AddMonths(-1)
                $dtpEndDate.Value = $firstOfThisMonth.AddDays(-1)
            }
        }
    }
    finally {
        $script:UpdatingDatesFromQuickSelect = $false
    }
})

# Store subscription and storage account data
$script:Subscriptions = @()
$script:StorageAccounts = @()

# Azure Sign In button
$btnAzureSignIn.Add_Click({
    $statusLabel.Text = "Signing in to Azure..."
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $mainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnAzureSignIn.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        # Import Az modules
        Import-Module Az.Accounts -ErrorAction Stop
        Import-Module Az.Storage -ErrorAction Stop
        
        $statusLabel.Text = "Waiting for Azure sign-in..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Disconnect any existing account first to force fresh login
        Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
        
        # Clear cached tokens
        Clear-AzContext -Force -ErrorAction SilentlyContinue | Out-Null
        [System.Windows.Forms.Application]::DoEvents()
        
        # Disable the interactive subscription selection menu
        $env:AZURE_CLIENTS_SHOW_SECRETS_WARNING = 'false'
        Update-AzConfig -LoginExperienceV2 Off -ErrorAction SilentlyContinue | Out-Null
        
        # Connect to Azure - subscription will be selected in GUI
        $context = Connect-AzAccount -SkipContextPopulation -ErrorAction Stop
        [System.Windows.Forms.Application]::DoEvents()
        
        # Verify we have a context
        $context = Get-AzContext
        if (-not $context -or -not $context.Account) {
            throw "Failed to establish Azure context after sign-in"
        }
        
        # Get subscriptions
        $statusLabel.Text = "Loading subscriptions..."
        [System.Windows.Forms.Application]::DoEvents()
        
        $script:Subscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' })
        [System.Windows.Forms.Application]::DoEvents()
        
        if ($script:Subscriptions.Count -eq 0) {
            throw "No active subscriptions found"
        }
        
        # Populate subscription dropdown
        $cmbSubscription.Items.Clear()
        foreach ($sub in $script:Subscriptions) {
            $null = $cmbSubscription.Items.Add("$($sub.Name) ($($sub.Id))")
        }
        $cmbSubscription.Enabled = $true
        [System.Windows.Forms.Application]::DoEvents()
        
        # Update status
        $lblSignInStatus.Text = "Signed in as: $($context.Account.Id)"
        $lblSignInStatus.ForeColor = [System.Drawing.Color]::Green
        $btnAzureSignIn.Text = "Refresh"
        
        $statusLabel.Text = "Connected to Azure. Select a subscription."
        
        # Auto-select first subscription if only one
        if ($script:Subscriptions.Count -eq 1) {
            $cmbSubscription.SelectedIndex = 0
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $statusLabel.Text = "Azure sign-in failed"
        $lblSignInStatus.Text = "Sign-in failed"
        $lblSignInStatus.ForeColor = [System.Drawing.Color]::Red
        [System.Windows.Forms.MessageBox]::Show("Error signing in to Azure:`n`n$errorMessage", "Sign-In Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        $progressBar.Visible = $false
        $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnAzureSignIn.Enabled = $true
    }
})

# Subscription selection changed
$cmbSubscription.Add_SelectedIndexChanged({
    if ($cmbSubscription.SelectedIndex -lt 0) { return }
    
    $statusLabel.Text = "Loading storage accounts..."
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $mainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        $selectedSub = $script:Subscriptions[$cmbSubscription.SelectedIndex]
        
        # Set subscription context
        $null = Set-AzContext -SubscriptionId $selectedSub.Id -ErrorAction Stop
        
        # Get storage accounts
        $script:StorageAccounts = @(Get-AzStorageAccount -ErrorAction Stop)
        
        # Populate storage account dropdown
        $cmbStorageAccount.Items.Clear()
        $cmbContainer.Items.Clear()
        $cmbContainer.Enabled = $false
        
        if ($script:StorageAccounts.Count -eq 0) {
            $cmbStorageAccount.Items.Add("(No storage accounts found)")
            $cmbStorageAccount.Enabled = $false
            $statusLabel.Text = "No storage accounts found in subscription"
        }
        else {
            foreach ($sa in $script:StorageAccounts) {
                $null = $cmbStorageAccount.Items.Add("$($sa.StorageAccountName) ($($sa.ResourceGroupName))")
            }
            $cmbStorageAccount.Enabled = $true
            $statusLabel.Text = "Found $($script:StorageAccounts.Count) storage accounts. Select one."
        }
        
        Update-ConnectionSummary
    }
    catch {
        $errorMessage = $_.Exception.Message
        $statusLabel.Text = "Error loading storage accounts"
        [System.Windows.Forms.MessageBox]::Show("Error:`n`n$errorMessage", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        $progressBar.Visible = $false
        $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# Storage account selection changed
$cmbStorageAccount.Add_SelectedIndexChanged({
    if ($cmbStorageAccount.SelectedIndex -lt 0) { return }
    if ($script:StorageAccounts.Count -eq 0) { return }
    
    $statusLabel.Text = "Loading containers..."
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $mainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        $selectedSA = $script:StorageAccounts[$cmbStorageAccount.SelectedIndex]
        
        # Store in config
        $script:Config.StorageAccountName = $selectedSA.StorageAccountName
        $script:Config.ResourceGroupName = $selectedSA.ResourceGroupName
        
        # Try storage account key first, fall back to RBAC
        $authMethod = "Unknown"
        $script:StorageContext = $null
        
        try {
            $statusLabel.Text = "Trying storage key authentication..."
            [System.Windows.Forms.Application]::DoEvents()
            
            $keys = Get-AzStorageAccountKey -ResourceGroupName $selectedSA.ResourceGroupName -Name $selectedSA.StorageAccountName -ErrorAction Stop
            $script:StorageContext = New-AzStorageContext -StorageAccountName $selectedSA.StorageAccountName -StorageAccountKey $keys[0].Value
            $authMethod = "StorageKey"
            
            # Test connection
            $null = Get-AzStorageContainer -Context $script:StorageContext -MaxCount 1 -ErrorAction Stop
        }
        catch {
            # Key-based auth failed, try RBAC
            $statusLabel.Text = "Storage key failed, trying RBAC authentication..."
            [System.Windows.Forms.Application]::DoEvents()
            
            try {
                $script:StorageContext = New-AzStorageContext -StorageAccountName $selectedSA.StorageAccountName -UseConnectedAccount
                $authMethod = "RBAC"
                
                # Test connection
                $null = Get-AzStorageContainer -Context $script:StorageContext -MaxCount 1 -ErrorAction Stop
            }
            catch {
                throw "Both authentication methods failed.`n`nStorage Key Error: Unable to retrieve storage account keys.`n`nRBAC Error: $($_.Exception.Message)`n`nRequired permissions:`n- Storage Key: 'Storage Account Key Operator' or 'Contributor' on storage account`n- RBAC: 'Storage Blob Data Reader' on storage account"
            }
        }
        
        $statusLabel.Text = "Connected via $authMethod. Loading containers..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Get containers
        $containers = @(Get-AzStorageContainer -Context $script:StorageContext -ErrorAction Stop)
        
        # Populate container dropdown
        $cmbContainer.Items.Clear()
        
        if ($containers.Count -eq 0) {
            $cmbContainer.Items.Add("(No containers found)")
            $cmbContainer.Enabled = $false
            $statusLabel.Text = "No containers found in storage account"
        }
        else {
            foreach ($container in $containers) {
                $null = $cmbContainer.Items.Add($container.Name)
            }
            $cmbContainer.Enabled = $true
            
            # Auto-select flow log container if exists
            $flowLogIndex = $cmbContainer.Items.IndexOf("insights-logs-flowlogflowevent")
            if ($flowLogIndex -ge 0) {
                $cmbContainer.SelectedIndex = $flowLogIndex
            }
            
            $statusLabel.Text = "Found $($containers.Count) containers. Select one."
        }
        
        Update-ConnectionSummary
    }
    catch {
        $errorMessage = $_.Exception.Message
        $statusLabel.Text = "Error loading containers"
        [System.Windows.Forms.MessageBox]::Show("Error:`n`n$errorMessage", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        $progressBar.Visible = $false
        $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# Container selection changed
$cmbContainer.Add_SelectedIndexChanged({
    if ($cmbContainer.SelectedIndex -lt 0) { return }
    
    $script:Config.ContainerName = $cmbContainer.SelectedItem.ToString()
    Update-ConnectionSummary
    $statusLabel.Text = "Ready to load data. Go to Flow Log Details tab and click Load Data."
})

# Helper function to update connection summary
function Update-ConnectionSummary {
    $summary = ""
    
    if ($cmbSubscription.SelectedIndex -ge 0 -and $script:Subscriptions.Count -gt 0) {
        $sub = $script:Subscriptions[$cmbSubscription.SelectedIndex]
        $summary += "Subscription: $($sub.Name)`r`n"
    }
    
    if ($script:Config.ResourceGroupName) {
        $summary += "Resource Group: $($script:Config.ResourceGroupName)`r`n"
    }
    
    if ($script:Config.StorageAccountName) {
        $summary += "Storage Account: $($script:Config.StorageAccountName)`r`n"
    }
    
    if ($script:Config.ContainerName) {
        $summary += "Container: $($script:Config.ContainerName)`r`n"
    }
    
    if ([string]::IsNullOrEmpty($summary)) {
        $summary = "Not connected"
    }
    
    $txtConnectionSummary.Text = $summary
}

# Timer for background job monitoring
$script:LoadTimer = New-Object System.Windows.Forms.Timer
$script:LoadTimer.Interval = 500  # Check every 500ms
$script:LoadJob = $null
$script:LoadStartTime = $null
$script:ProgressFile = $null

$script:LoadTimer.Add_Tick({
    if ($null -ne $script:LoadJob) {
        # Update UI
        [System.Windows.Forms.Application]::DoEvents()
        
        # Calculate elapsed time
        $elapsed = ""
        if ($null -ne $script:LoadStartTime) {
            $timeSpan = (Get-Date) - $script:LoadStartTime
            $elapsed = " ({0:mm\:ss})" -f $timeSpan
        }
        
        # Read progress from file if exists
        $progressText = ""
        if ($script:ProgressFile -and (Test-Path $script:ProgressFile)) {
            try {
                $progressText = Get-Content $script:ProgressFile -Raw -ErrorAction SilentlyContinue
                if ($progressText) { $progressText = " - $progressText" }
            } catch { }
        }
        
        # Check if job is complete
        if ($script:LoadJob.State -eq 'Completed') {
            $script:LoadTimer.Stop()
            
            try {
                # Get results from job
                $flowData = Receive-Job -Job $script:LoadJob -ErrorAction Stop
                Remove-Job -Job $script:LoadJob -Force
                $script:LoadJob = $null
                
                if ($flowData -and @($flowData).Count -gt 0) {
                    $script:Config.CurrentData = @($flowData)
                    
                    $statusLabel.Text = "Applying filters..."
                    [System.Windows.Forms.Application]::DoEvents()
                    
                    # Apply exclusions if any
                    $script:Config.FilteredData = @(Apply-IPExclusions -FlowData $script:Config.CurrentData `
                                                                      -ExcludedIPs $script:Config.ExcludedIPs `
                                                                      -ExcludedRanges $script:Config.ExcludedRanges)
                    
                    $statusLabel.Text = "Updating views..."
                    [System.Windows.Forms.Application]::DoEvents()
                    
                    # Update all views
                    Update-FlowLogGrid -DataGridView $dgvFlowLogs -Data $script:Config.FilteredData -IPOwnerCache $script:IPOwnerResults
                    [System.Windows.Forms.Application]::DoEvents()
                    
                    Update-IPSummaryGrid -DataGridView $dgvIPSummary -Data $script:Config.FilteredData -StatsTextBox $txtStats -IPOwnerCache $script:IPOwnerResults
                    [System.Windows.Forms.Application]::DoEvents()
                    
                    Update-TimeSummaryGrid -DataGridView $dgvTimeSummary -Data $script:Config.FilteredData -GroupBy $cmbGroupBy.SelectedItem
                    [System.Windows.Forms.Application]::DoEvents()
                    
                    Update-PortSummaryGrid -DataGridView $dgvPortSummary -Data $script:Config.FilteredData -StatsTextBox $txtPortStats
                    
                    $statusLabel.Text = "Loaded $($script:Config.FilteredData.Count) flow records"
                }
                else {
                    $script:Config.CurrentData = @()
                    $script:Config.FilteredData = @()
                    $statusLabel.Text = "No data found for the selected date range"
                    [System.Windows.Forms.MessageBox]::Show("No flow log data found for the selected date range.`n`nMake sure:`n- The container name is correct`n- Flow logs exist for the selected dates`n- You have proper permissions", "No Data", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                }
            }
            catch {
                $errorMessage = $_.Exception.Message
                if ([string]::IsNullOrEmpty($errorMessage)) { $errorMessage = $_.ToString() }
                $statusLabel.Text = "Error loading data"
                [System.Windows.Forms.MessageBox]::Show("Error loading data:`n`n$errorMessage", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
            finally {
                # Clean up progress file
                if ($script:ProgressFile -and (Test-Path $script:ProgressFile)) {
                    Remove-Item $script:ProgressFile -Force -ErrorAction SilentlyContinue
                }
                $script:ProgressFile = $null
                
                $progressBar.Visible = $false
                $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
                $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
                $btnLoadData.Enabled = $true
                $btnCancelLoad.Enabled = $false
            }
        }
        elseif ($script:LoadJob.State -eq 'Failed') {
            $script:LoadTimer.Stop()
            $errorInfo = $script:LoadJob.ChildJobs[0].JobStateInfo.Reason.Message
            Remove-Job -Job $script:LoadJob -Force
            $script:LoadJob = $null
            
            # Clean up progress file
            if ($script:ProgressFile -and (Test-Path $script:ProgressFile)) {
                Remove-Item $script:ProgressFile -Force -ErrorAction SilentlyContinue
            }
            $script:ProgressFile = $null
            
            $statusLabel.Text = "Error loading data"
            [System.Windows.Forms.MessageBox]::Show("Job failed:`n`n$errorInfo", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            
            $progressBar.Visible = $false
            $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnLoadData.Enabled = $true
            $btnCancelLoad.Enabled = $false
        }
        else {
            # Job still running - update status with elapsed time and progress
            $statusLabel.Text = "Loading flow log data$progressText$elapsed"
        }
    }
})

# Load data button
$btnLoadData.Add_Click({
    # Validate connection
    if ([string]::IsNullOrEmpty($script:Config.StorageAccountName) -or [string]::IsNullOrEmpty($script:Config.ContainerName)) {
        [System.Windows.Forms.MessageBox]::Show("Please go to the Connection tab and configure the Azure connection first.", "Not Connected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        $tabControl.SelectedTab = $tabConnection
        return
    }
    
    $statusLabel.Text = "Loading flow log data..."
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $mainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnLoadData.Enabled = $false
    $btnCancelLoad.Enabled = $true
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        $startDate = $dtpStartDate.Value
        $endDate = $dtpEndDate.Value
        
        # Ensure connected first (this is quick)
        if (-not $script:StorageContext) {
            $statusLabel.Text = "Connecting to Azure..."
            [System.Windows.Forms.Application]::DoEvents()
            $connResult = Connect-ToAzureStorage -StorageAccountName $script:Config.StorageAccountName -ResourceGroupName $script:Config.ResourceGroupName
            if (-not $connResult.Success) {
                throw "Connection failed: $($connResult.Error)"
            }
        }
        
        $statusLabel.Text = "Starting background data load..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Get context info for the job
        $storageAccountName = $script:Config.StorageAccountName
        $containerName = $script:Config.ContainerName
        $resourceGroupName = $script:Config.ResourceGroupName
        $storageContext = $script:StorageContext
        
        # Create progress file for communication
        $script:ProgressFile = [System.IO.Path]::GetTempFileName()
        $progressFile = $script:ProgressFile
        
        # Save Azure context so background job can use it for RBAC
        $azContextFile = [System.IO.Path]::GetTempFileName()
        Save-AzContext -Path $azContextFile -Force
        
        # Start background job for data loading
        $script:LoadJob = Start-Job -ScriptBlock {
            param($StorageAccountName, $ContainerName, $StartDate, $EndDate, $ResourceGroupName, $ModulesPath, $ProgressFile, $AzContextFile)
            
            # Helper function to update progress
            function Update-Progress {
                param($Message)
                $Message | Out-File -FilePath $ProgressFile -Force -NoNewline
            }
            
            Update-Progress "Connecting to Azure..."
            
            # Import required modules
            Import-Module Az.Storage -ErrorAction Stop
            Import-Module Az.Accounts -ErrorAction Stop
            . "$ModulesPath\FlowLogParser.ps1"
            
            # Import Azure context from main session (needed for RBAC)
            if (Test-Path $AzContextFile) {
                Import-AzContext -Path $AzContextFile -ErrorAction SilentlyContinue | Out-Null
            }
            
            # Try storage key first, fall back to RBAC
            $context = $null
            
            try {
                Update-Progress "Trying storage key authentication..."
                $keys = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
                $context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $keys[0].Value
                
                # Test the connection
                $null = Get-AzStorageContainer -Context $context -MaxCount 1 -ErrorAction Stop
            }
            catch {
                # Key access failed, try RBAC
                Update-Progress "Storage key failed, trying RBAC..."
                try {
                    $context = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
                    
                    # Test the connection
                    $null = Get-AzStorageContainer -Context $context -MaxCount 1 -ErrorAction Stop
                }
                catch {
                    throw "Authentication failed. Both storage key and RBAC methods failed. Error: $($_.Exception.Message)"
                }
            }
            
            Update-Progress "Listing blobs..."
            
            # Get blobs
            $allBlobs = @(Get-AzStorageBlob -Container $ContainerName -Context $context -ErrorAction Stop)
            
            Update-Progress "Found $($allBlobs.Count) total blobs, filtering..."
            
            # Filter by date - support multiple path formats
            $filteredBlobs = @()
            foreach ($blob in $allBlobs) {
                $blobDate = $null
                
                # Format 1: y=2024/m=01/d=15
                if ($blob.Name -match 'y=(\d{4})/m=(\d{2})/d=(\d{2})') {
                    $blobDate = Get-Date -Year ([int]$Matches[1]) -Month ([int]$Matches[2]) -Day ([int]$Matches[3])
                }
                # Format 2: year=2024/month=01/day=15
                elseif ($blob.Name -match 'year=(\d{4})/month=(\d{2})/day=(\d{2})') {
                    $blobDate = Get-Date -Year ([int]$Matches[1]) -Month ([int]$Matches[2]) -Day ([int]$Matches[3])
                }
                # Format 3: /2024/01/15/ (date in path)
                elseif ($blob.Name -match '/(\d{4})/(\d{2})/(\d{2})/') {
                    $blobDate = Get-Date -Year ([int]$Matches[1]) -Month ([int]$Matches[2]) -Day ([int]$Matches[3])
                }
                
                if ($blobDate -and $blobDate -ge $StartDate.Date -and $blobDate -le $EndDate.Date.AddDays(1)) {
                    $filteredBlobs += $blob
                }
            }
            
            Update-Progress "$($filteredBlobs.Count) blobs match date range"
            
            if ($filteredBlobs.Count -eq 0) {
                return @()
            }
            
            # Sort by date (most recent first)
            $filteredBlobs = $filteredBlobs | Sort-Object -Property LastModified -Descending
            
            # Download and parse each blob
            $allRecords = [System.Collections.ArrayList]@()
            $blobCount = 0
            $totalBlobs = $filteredBlobs.Count
            foreach ($blob in $filteredBlobs) {
                $blobCount++
                Update-Progress "Processing blob $blobCount of $totalBlobs ($($allRecords.Count) records so far)"
                try {
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    $null = Get-AzStorageBlobContent -Container $ContainerName -Blob $blob.Name -Destination $tempFile -Context $context -Force -ErrorAction Stop
                    $jsonContent = Get-Content -Path $tempFile -Raw | ConvertFrom-Json
                    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    
                    $records = Parse-FlowLogJson -JsonContent $jsonContent -BlobPath $blob.Name
                    if ($records -and $records.Count -gt 0) {
                        foreach ($r in $records) {
                            $null = $allRecords.Add($r)
                        }
                    }
                }
                catch {
                    # Skip failed blobs silently
                }
            }
            
            Update-Progress "Filtering $($allRecords.Count) records..."
            
            # Filter by exact date range
            $filtered = @($allRecords | Where-Object { $_.Timestamp -ge $StartDate -and $_.Timestamp -le $EndDate })
            
            Update-Progress "Complete: $($filtered.Count) records"
            
            # Clean up context file
            if (Test-Path $AzContextFile) {
                Remove-Item $AzContextFile -Force -ErrorAction SilentlyContinue
            }
            
            return $filtered
            
        } -ArgumentList $storageAccountName, $containerName, $startDate, $endDate, $resourceGroupName, $script:ModulesPath, $progressFile, $azContextFile
        
        # Start timer to monitor job
        $script:LoadStartTime = Get-Date
        $script:LoadTimer.Start()
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ([string]::IsNullOrEmpty($errorMessage)) {
            $errorMessage = $_.ToString()
        }
        $statusLabel.Text = "Error loading data"
        [System.Windows.Forms.MessageBox]::Show("Error loading data:`n`n$errorMessage", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        
        # Clean up progress file
        if ($script:ProgressFile -and (Test-Path $script:ProgressFile)) {
            Remove-Item $script:ProgressFile -Force -ErrorAction SilentlyContinue
        }
        
        $progressBar.Visible = $false
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnLoadData.Enabled = $true
        $btnCancelLoad.Enabled = $false
    }
})

# Cancel load button
$btnCancelLoad.Add_Click({
    if ($null -ne $script:LoadJob) {
        $script:LoadTimer.Stop()
        Stop-Job -Job $script:LoadJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:LoadJob -Force -ErrorAction SilentlyContinue
        $script:LoadJob = $null
        
        # Clean up progress file
        if ($script:ProgressFile -and (Test-Path $script:ProgressFile)) {
            Remove-Item $script:ProgressFile -Force -ErrorAction SilentlyContinue
        }
        $script:ProgressFile = $null
        
        $statusLabel.Text = "Load cancelled"
        $progressBar.Visible = $false
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
        $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnLoadData.Enabled = $true
        $btnCancelLoad.Enabled = $false
    }
})

# Search button
$btnSearch.Add_Click({
    if ($null -eq $script:Config.FilteredData) { return }
    
    $searchIP = $txtSearchIP.Text.Trim()
    $srcPort = $txtSrcPort.Text.Trim()
    $dstPort = $txtDstPort.Text.Trim()
    
    # If all filters are empty, do nothing
    if ([string]::IsNullOrEmpty($searchIP) -and [string]::IsNullOrEmpty($srcPort) -and [string]::IsNullOrEmpty($dstPort)) { 
        return 
    }
    
    $filtered = $script:Config.FilteredData
    
    # Filter by IP
    if (-not [string]::IsNullOrEmpty($searchIP)) {
        $filtered = $filtered | Where-Object { 
            $_.SourceIP -like "*$searchIP*" -or $_.DestinationIP -like "*$searchIP*" 
        }
    }
    
    # Filter by Source Port
    if (-not [string]::IsNullOrEmpty($srcPort) -and $srcPort -match '^\d+$') {
        $portNum = [int]$srcPort
        $filtered = $filtered | Where-Object { $_.SourcePort -eq $portNum }
    }
    
    # Filter by Destination Port
    if (-not [string]::IsNullOrEmpty($dstPort) -and $dstPort -match '^\d+$') {
        $portNum = [int]$dstPort
        $filtered = $filtered | Where-Object { $_.DestinationPort -eq $portNum }
    }
    
    Update-FlowLogGrid -DataGridView $dgvFlowLogs -Data $filtered -IPOwnerCache $script:IPOwnerResults
    $statusLabel.Text = "Found $(@($filtered).Count) matching records"
})

# Clear search button
$btnClearSearch.Add_Click({
    $txtSearchIP.Text = ""
    $txtSrcPort.Text = ""
    $txtDstPort.Text = ""
    # Reset dropdowns to "All"
    $cmbDirection.SelectedIndex = 0
    $cmbAction.SelectedIndex = 0
    
    if ($null -ne $script:Config.FilteredData) {
        $statusLabel.Text = "Refreshing view... Please wait"
        [System.Windows.Forms.Application]::DoEvents()
        
        Update-FlowLogGrid -DataGridView $dgvFlowLogs -Data $script:Config.FilteredData -IPOwnerCache $script:IPOwnerResults
        $statusLabel.Text = "Showing all $($script:Config.FilteredData.Count) records"
    }
})

# Direction filter
$cmbDirection.Add_SelectedIndexChanged({
    if ($null -eq $script:Config.FilteredData) { return }
    Apply-QuickFilters
})

# Action filter
$cmbAction.Add_SelectedIndexChanged({
    if ($null -eq $script:Config.FilteredData) { return }
    Apply-QuickFilters
})

function Apply-QuickFilters {
    $data = $script:Config.FilteredData
    
    # Apply direction filter
    if ($cmbDirection.SelectedItem -ne "All") {
        $direction = if ($cmbDirection.SelectedItem -eq "Inbound") { "I" } else { "O" }
        $data = $data | Where-Object { $_.Direction -eq $direction }
    }
    
    # Apply action filter
    if ($cmbAction.SelectedItem -ne "All") {
        $action = if ($cmbAction.SelectedItem -eq "Allow") { "A" } else { "D" }
        $data = $data | Where-Object { $_.Action -eq $action }
    }
    
    Update-FlowLogGrid -DataGridView $dgvFlowLogs -Data $data -IPOwnerCache $script:IPOwnerResults
    $statusLabel.Text = "Showing $($data.Count) filtered records"
}

# Group by change
$cmbGroupBy.Add_SelectedIndexChanged({
    if ($null -eq $script:Config.FilteredData) { return }
    Update-TimeSummaryGrid -DataGridView $dgvTimeSummary -Data $script:Config.FilteredData -GroupBy $cmbGroupBy.SelectedItem
})

# Time summary row selection - show IP details for that period
$dgvTimeSummary.Add_SelectionChanged({
    if ($dgvTimeSummary.SelectedRows.Count -eq 0) { return }
    if ($null -eq $script:Config.FilteredData) { return }
    
    $selectedPeriod = $dgvTimeSummary.SelectedRows[0].Cells["Period"].Value
    if ($null -eq $selectedPeriod) { return }
    
    $groupBy = $cmbGroupBy.SelectedItem
    $periodData = Get-FlowDataForPeriod -Data $script:Config.FilteredData -Period $selectedPeriod -GroupBy $groupBy
    
    if ($periodData) {
        Update-IPPerTimeGrid -DataGridView $dgvIPPerTime -Data $periodData
    }
})

# Add IP exclusion
$btnAddIP.Add_Click({
    $ip = $txtAddIP.Text.Trim()
    if (-not [string]::IsNullOrEmpty($ip)) {
        if (Test-ValidIP -IPAddress $ip) {
            if (-not $lstExcludedIPs.Items.Contains($ip)) {
                $lstExcludedIPs.Items.Add($ip)
                $script:Config.ExcludedIPs += $ip
                $txtAddIP.Text = ""
            }
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Invalid IP address format.", "Invalid IP", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    }
})

# Remove IP exclusion
$btnRemoveIP.Add_Click({
    $selectedItems = @($lstExcludedIPs.SelectedItems)
    foreach ($item in $selectedItems) {
        $lstExcludedIPs.Items.Remove($item)
        $script:Config.ExcludedIPs = $script:Config.ExcludedIPs | Where-Object { $_ -ne $item }
    }
})

# Add IP range exclusion
$btnAddRange.Add_Click({
    $range = $txtAddRange.Text.Trim()
    if (-not [string]::IsNullOrEmpty($range)) {
        if (Test-ValidCIDR -CIDR $range) {
            if (-not $lstExcludedRanges.Items.Contains($range)) {
                $lstExcludedRanges.Items.Add($range)
                $script:Config.ExcludedRanges += $range
                $txtAddRange.Text = ""
            }
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Invalid CIDR format. Use format like: 10.0.0.0/8", "Invalid CIDR", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    }
})

# Remove IP range exclusion
$btnRemoveRange.Add_Click({
    $selectedItems = @($lstExcludedRanges.SelectedItems)
    foreach ($item in $selectedItems) {
        $lstExcludedRanges.Items.Remove($item)
        $script:Config.ExcludedRanges = $script:Config.ExcludedRanges | Where-Object { $_ -ne $item }
    }
})

# Apply exclusions
$btnApplyExclusions.Add_Click({
    if ($null -eq $script:Config.CurrentData -or $script:Config.CurrentData.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please load data first.", "No Data", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $statusLabel.Text = "Applying exclusions..."
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $mainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnApplyExclusions.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        # Create progress callback
        $progressCallback = {
            param($message)
            $statusLabel.Text = $message
            [System.Windows.Forms.Application]::DoEvents()
        }
        
        $statusLabel.Text = "Starting exclusion filter with $($script:Config.ExcludedIPs.Count) IPs and $($script:Config.ExcludedRanges.Count) CIDR ranges..."
        [System.Windows.Forms.Application]::DoEvents()
        
        $result = Apply-IPExclusions -FlowData $script:Config.CurrentData `
                                       -ExcludedIPs $script:Config.ExcludedIPs `
                                       -ExcludedRanges $script:Config.ExcludedRanges `
                                       -ProgressCallback $progressCallback
        
        # Ensure we have an array (even if empty)
        $script:Config.FilteredData = @($result)
        
        $statusLabel.Text = "Updating Flow Logs grid..."
        [System.Windows.Forms.Application]::DoEvents()
        Update-FlowLogGrid -DataGridView $dgvFlowLogs -Data $script:Config.FilteredData -IPOwnerCache $script:IPOwnerResults
        
        $statusLabel.Text = "Updating IP Summary grid..."
        [System.Windows.Forms.Application]::DoEvents()
        Update-IPSummaryGrid -DataGridView $dgvIPSummary -Data $script:Config.FilteredData -StatsTextBox $txtStats -IPOwnerCache $script:IPOwnerResults
        
        $statusLabel.Text = "Updating Time Summary grid..."
        [System.Windows.Forms.Application]::DoEvents()
        Update-TimeSummaryGrid -DataGridView $dgvTimeSummary -Data $script:Config.FilteredData -GroupBy $cmbGroupBy.SelectedItem
        
        $statusLabel.Text = "Updating Port Summary grid..."
        [System.Windows.Forms.Application]::DoEvents()
        Update-PortSummaryGrid -DataGridView $dgvPortSummary -Data $script:Config.FilteredData -StatsTextBox $txtPortStats
        
        $originalCount = if ($script:Config.CurrentData) { $script:Config.CurrentData.Count } else { 0 }
        $filteredCount = $script:Config.FilteredData.Count
        $excluded = $originalCount - $filteredCount
        $statusLabel.Text = "Exclusions applied. $excluded records excluded, $filteredCount remaining"
    }
    finally {
        $progressBar.Visible = $false
        $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnApplyExclusions.Enabled = $true
    }
})

# Save exclusions
$btnSaveExclusions.Add_Click({
    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
    $saveDialog.DefaultExt = "json"
    $saveDialog.FileName = "FlowLogExclusions.json"
    
    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $exclusions = @{
            ExcludedIPs = $script:Config.ExcludedIPs
            ExcludedRanges = $script:Config.ExcludedRanges
        }
        $exclusions | ConvertTo-Json | Out-File -FilePath $saveDialog.FileName -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show("Exclusions saved successfully.", "Saved", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# Load exclusions
$btnLoadExclusions.Add_Click({
    $openDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openDialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
    
    if ($openDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $exclusions = Get-Content -Path $openDialog.FileName -Raw | ConvertFrom-Json
            
            $lstExcludedIPs.Items.Clear()
            $lstExcludedRanges.Items.Clear()
            
            $script:Config.ExcludedIPs = @($exclusions.ExcludedIPs)
            $script:Config.ExcludedRanges = @($exclusions.ExcludedRanges)
            
            foreach ($ip in $script:Config.ExcludedIPs) {
                $lstExcludedIPs.Items.Add($ip)
            }
            foreach ($range in $script:Config.ExcludedRanges) {
                $lstExcludedRanges.Items.Add($range)
            }
            
            [System.Windows.Forms.MessageBox]::Show("Exclusions loaded successfully.", "Loaded", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Error loading exclusions: $_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
})

# Add Azure IP Ranges button
$btnAddAzureRanges.Add_Click({
    $statusLabel.Text = "Downloading Azure IP ranges..."
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $mainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnAddAzureRanges.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        # Get the download page to find the current JSON file URL
        $downloadPageUrl = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519"
        
        $statusLabel.Text = "Connecting to Microsoft download page..."
        [System.Windows.Forms.Application]::DoEvents()
        
        $webResponse = Invoke-WebRequest -Uri $downloadPageUrl -UseBasicParsing -TimeoutSec 30
        
        $statusLabel.Text = "Parsing download page for JSON link..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Find the direct download link from the page
        $downloadLink = $webResponse.Links | Where-Object { $_.href -match 'ServiceTags_Public.*\.json' } | Select-Object -First 1 -ExpandProperty href
        
        if (-not $downloadLink) {
            throw "Could not find Azure IP ranges download link on the Microsoft download page."
        }
        
        $statusLabel.Text = "Downloading Azure IP ranges JSON (this may take a minute)..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Download the JSON file
        $jsonContent = Invoke-RestMethod -Uri $downloadLink -TimeoutSec 120
        
        if (-not $jsonContent -or -not $jsonContent.values) {
            throw "Downloaded file does not contain expected Azure IP range data."
        }
        
        $totalServices = $jsonContent.values.Count
        $statusLabel.Text = "Processing $totalServices Azure service tags..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Extract all IP prefixes from all service tags using hashtable for automatic deduplication
        $rangeHash = @{}
        $processedServices = 0
        foreach ($value in $jsonContent.values) {
            $processedServices++
            if ($processedServices % 50 -eq 0) {
                $statusLabel.Text = "Processing service tags: $processedServices / $totalServices..."
                [System.Windows.Forms.Application]::DoEvents()
            }
            if ($value.properties -and $value.properties.addressPrefixes) {
                foreach ($prefix in $value.properties.addressPrefixes) {
                    $rangeHash[$prefix] = $true
                }
            }
        }
        
        $statusLabel.Text = "Collected $($rangeHash.Count) unique ranges..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Get unique ranges (already deduplicated via hashtable)
        $uniqueRanges = @($rangeHash.Keys)
        
        $statusLabel.Text = "Checking $($uniqueRanges.Count) unique ranges against existing exclusions..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Count how many are new
        $existingRanges = @($lstExcludedRanges.Items)
        $existingHash = @{}
        foreach ($r in $existingRanges) { $existingHash[$r] = $true }
        
        $newRanges = [System.Collections.ArrayList]@()
        foreach ($range in $uniqueRanges) {
            if (-not $existingHash.ContainsKey($range)) {
                $null = $newRanges.Add($range)
            }
        }
        
        if ($newRanges.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("All Azure IP ranges are already in the exclusion list.", "No New Ranges", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            $statusLabel.Text = "All Azure IP ranges already present"
            return
        }
        
        # Confirm with user
        $confirmResult = [System.Windows.Forms.MessageBox]::Show(
            "Found $($uniqueRanges.Count) Azure IP ranges ($($newRanges.Count) new).`n`nThis will add $($newRanges.Count) new CIDR ranges to your exclusion list.`n`nContinue?",
            "Add Azure IP Ranges",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        
        if ($confirmResult -ne [System.Windows.Forms.DialogResult]::Yes) {
            $statusLabel.Text = "Cancelled adding Azure IP ranges"
            return
        }
        
        $statusLabel.Text = "Adding $($newRanges.Count) Azure IP ranges to list..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Add to the list with progress
        $addedCount = 0
        $lstExcludedRanges.BeginUpdate()
        try {
            foreach ($range in $newRanges) {
                $addedCount++
                $lstExcludedRanges.Items.Add($range)
                $script:Config.ExcludedRanges += $range
                
                if ($addedCount % 500 -eq 0) {
                    $statusLabel.Text = "Adding ranges: $addedCount / $($newRanges.Count)..."
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
        }
        finally {
            $lstExcludedRanges.EndUpdate()
        }
        
        $statusLabel.Text = "Successfully added $($newRanges.Count) Azure IP ranges"
        [System.Windows.Forms.MessageBox]::Show(
            "Successfully added $($newRanges.Count) Azure IP ranges to exclusions.`n`nClick 'Apply Exclusions' to filter the current data.",
            "Azure IP Ranges Added",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
    catch {
        $errorMessage = $_.Exception.Message
        $statusLabel.Text = "Failed to download Azure IP ranges"
        [System.Windows.Forms.MessageBox]::Show(
            "Could not download Azure IP ranges:`n`n$errorMessage`n`nPlease check your internet connection and try again.",
            "Download Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
    }
    finally {
        $progressBar.Visible = $false
        $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnAddAzureRanges.Enabled = $true
    }
})

# Clear all exclusions button
$btnClearExclusions.Add_Click({
    $ipCount = $lstExcludedIPs.Items.Count
    $rangeCount = $lstExcludedRanges.Items.Count
    
    if ($ipCount -eq 0 -and $rangeCount -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No exclusions to clear.", "Empty", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $confirmResult = [System.Windows.Forms.MessageBox]::Show(
        "Are you sure you want to clear all exclusions?`n`n$ipCount IP addresses`n$rangeCount CIDR ranges`n`nThis cannot be undone.",
        "Clear All Exclusions",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    
    if ($confirmResult -eq [System.Windows.Forms.DialogResult]::Yes) {
        $lstExcludedIPs.Items.Clear()
        $lstExcludedRanges.Items.Clear()
        $script:Config.ExcludedIPs = @()
        $script:Config.ExcludedRanges = @()
        $statusLabel.Text = "Cleared all exclusions ($ipCount IPs, $rangeCount ranges)"
    }
})

# Context menu - Exclude selected IP
$excludeIPMenuItem.Add_Click({
    if ($dgvIPSummary.SelectedRows.Count -gt 0) {
        foreach ($row in $dgvIPSummary.SelectedRows) {
            $ip = $row.Cells["IPAddress"].Value
            if ($ip -and -not $lstExcludedIPs.Items.Contains($ip)) {
                $lstExcludedIPs.Items.Add($ip)
                $script:Config.ExcludedIPs += $ip
            }
        }
        [System.Windows.Forms.MessageBox]::Show("IP(s) added to exclusion list. Click 'Apply Exclusions' to update the view.", "Added", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# Context menu - Copy IP
$copyIPMenuItem.Add_Click({
    if ($dgvIPSummary.SelectedRows.Count -gt 0) {
        $ips = ($dgvIPSummary.SelectedRows | ForEach-Object { $_.Cells["IPAddress"].Value }) -join "`r`n"
        [System.Windows.Forms.Clipboard]::SetText($ips)
    }
})

# Context menu - Lookup IP Owner
$lookupIPOwnerMenuItem.Add_Click({
    if ($dgvIPSummary.SelectedRows.Count -gt 0) {
        $ip = $dgvIPSummary.SelectedRows[0].Cells["IPAddress"].Value
        if ($ip) {
            $statusLabel.Text = "Looking up owner for $ip..."
            [System.Windows.Forms.Application]::DoEvents()
            
            $info = Get-IPOwnerInfo -IPAddress $ip
            
            $msg = "IP: $ip`n`n"
            $msg += "Owner/Org: $($info.Owner)`n"
            $msg += "ISP: $($info.ISP)`n"
            $msg += "AS: $($info.AS)`n"
            $msg += "Country: $($info.Country)`n"
            $msg += "City: $($info.City)`n"
            
            [System.Windows.Forms.MessageBox]::Show($msg, "IP Owner Lookup", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            $statusLabel.Text = "Ready"
        }
    }
})

# Export to CSV
$exportCsvMenuItem.Add_Click({
    if ($null -eq $script:Config.FilteredData -or $script:Config.FilteredData.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No data to export.", "No Data", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    $saveDialog.DefaultExt = "csv"
    $saveDialog.FileName = "FlowLogs_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    
    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Config.FilteredData | Export-Csv -Path $saveDialog.FileName -NoTypeInformation
        [System.Windows.Forms.MessageBox]::Show("Data exported successfully.", "Export Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# Export Summary Report
$exportSummaryMenuItem.Add_Click({
    if ($null -eq $script:Config.FilteredData -or $script:Config.FilteredData.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No data to export.", "No Data", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Select folder for summary reports"
    
    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $basePath = $folderDialog.SelectedPath
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        
        # Export detailed flow logs
        $script:Config.FilteredData | Export-Csv -Path "$basePath\FlowLogs_Detail_$timestamp.csv" -NoTypeInformation
        
        # Export IP Summary
        $ipSummary = Get-IPSummary -Data $script:Config.FilteredData
        $ipSummary | Export-Csv -Path "$basePath\FlowLogs_IPSummary_$timestamp.csv" -NoTypeInformation
        
        # Export Daily Summary
        $dailySummary = Get-TimeSummary -Data $script:Config.FilteredData -GroupBy "Daily"
        $dailySummary | Export-Csv -Path "$basePath\FlowLogs_DailySummary_$timestamp.csv" -NoTypeInformation
        
        # Export Monthly Summary
        $monthlySummary = Get-TimeSummary -Data $script:Config.FilteredData -GroupBy "Monthly"
        $monthlySummary | Export-Csv -Path "$basePath\FlowLogs_MonthlySummary_$timestamp.csv" -NoTypeInformation
        
        [System.Windows.Forms.MessageBox]::Show("Summary reports exported successfully to:`n$basePath", "Export Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# Refresh data
$refreshMenuItem.Add_Click({
    $btnLoadData.PerformClick()
})

# Manage exclusions menu item
$manageExclusionsMenuItem.Add_Click({
    $tabControl.SelectedTab = $tabExclusions
})

# Clear all exclusions
$clearExclusionsMenuItem.Add_Click({
    $result = [System.Windows.Forms.MessageBox]::Show("Are you sure you want to clear all exclusions?", "Confirm Clear", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $lstExcludedIPs.Items.Clear()
        $lstExcludedRanges.Items.Clear()
        $script:Config.ExcludedIPs = @()
        $script:Config.ExcludedRanges = @()
        
        if ($null -ne $script:Config.CurrentData) {
            $btnApplyExclusions.PerformClick()
        }
    }
})

# About menu item
$aboutMenuItem.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "Azure Flow Log Viewer`n`nVersion 1.0`n`nA tool for viewing and analyzing Azure VNET Flow Logs.`n`nFeatures:`n- View flow log details`n- IP-based data transfer analysis`n- Daily/Monthly/Custom date range analysis`n- IP and IP range exclusions`n- CSV export capabilities",
        "About",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
})

# Exit menu item
$exitMenuItem.Add_Click({
    $mainForm.Close()
})

# ============================================
# PORT SUMMARY EVENT HANDLERS
# ============================================

# Function to update port summary grid
function Update-PortSummaryGrid {
    param(
        [System.Windows.Forms.DataGridView]$DataGridView,
        [array]$Data,
        [System.Windows.Forms.RichTextBox]$StatsTextBox
    )
    
    $DataGridView.Columns.Clear()
    $DataGridView.Rows.Clear()
    
    if ($null -eq $Data -or $Data.Count -eq 0) {
        return
    }
    
    # Add columns
    $DataGridView.Columns.Add("Port", "Port")
    $DataGridView.Columns.Add("Protocol", "Protocol")
    $DataGridView.Columns.Add("ServiceName", "Service")
    $DataGridView.Columns.Add("ConnectionCount", "Connections")
    $DataGridView.Columns.Add("UniqueSourceIPs", "Unique Sources")
    $DataGridView.Columns.Add("UniqueDestIPs", "Unique Destinations")
    $DataGridView.Columns.Add("TotalMB", "Total MB")
    
    # Common port mappings
    $portNames = @{
        22 = "SSH"; 23 = "Telnet"; 25 = "SMTP"; 53 = "DNS"; 80 = "HTTP"
        110 = "POP3"; 143 = "IMAP"; 443 = "HTTPS"; 445 = "SMB"
        587 = "SMTP"; 993 = "IMAPS"; 995 = "POP3S"; 1433 = "SQL Server"
        1521 = "Oracle"; 3306 = "MySQL"; 3389 = "RDP"; 5432 = "PostgreSQL"
        5985 = "WinRM"; 5986 = "WinRM-S"; 8080 = "HTTP-Alt"; 8443 = "HTTPS-Alt"
    }
    
    # Group by destination port (most common use case)
    $portGroups = $Data | Group-Object -Property DestinationPort | ForEach-Object {
        $port = $_.Name
        $records = $_.Group
        $protocol = ($records | Select-Object -First 1).Protocol
        $serviceName = if ($portNames.ContainsKey([int]$port)) { $portNames[[int]$port] } else { "" }
        $totalBytes = ($records | Measure-Object -Property TotalBytes -Sum).Sum
        $uniqueSrc = ($records | Select-Object -ExpandProperty SourceIP -Unique).Count
        $uniqueDst = ($records | Select-Object -ExpandProperty DestinationIP -Unique).Count
        
        [PSCustomObject]@{
            Port = $port
            Protocol = $protocol
            ServiceName = $serviceName
            ConnectionCount = $records.Count
            UniqueSourceIPs = $uniqueSrc
            UniqueDestIPs = $uniqueDst
            TotalBytes = $totalBytes
        }
    } | Sort-Object -Property ConnectionCount -Descending
    
    foreach ($pg in $portGroups) {
        $totalMB = [math]::Round($pg.TotalBytes / 1MB, 2)
        $null = $DataGridView.Rows.Add($pg.Port, $pg.Protocol, $pg.ServiceName, $pg.ConnectionCount, $pg.UniqueSourceIPs, $pg.UniqueDestIPs, $totalMB)
    }
    
    # Update stats
    if ($StatsTextBox) {
        $totalPorts = $portGroups.Count
        $totalConnections = ($portGroups | Measure-Object -Property ConnectionCount -Sum).Sum
        $topPorts = $portGroups | Select-Object -First 10
        
        $statsText = "Port Summary Statistics`n"
        $statsText += "========================`n`n"
        $statsText += "Total Unique Ports: $totalPorts`n"
        $statsText += "Total Connections: $totalConnections`n`n"
        $statsText += "Top 10 Ports by Connection Count:`n"
        $statsText += "---------------------------------`n"
        
        foreach ($p in $topPorts) {
            $svcName = if ($p.ServiceName) { " ($($p.ServiceName))" } else { "" }
            $statsText += "Port $($p.Port)$svcName : $($p.ConnectionCount) connections`n"
        }
        
        $StatsTextBox.Text = $statsText
    }
}

# Filter by port button
$btnFilterByPort.Add_Click({
    if ($null -eq $script:Config.FilteredData -or $script:Config.FilteredData.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please load data first.", "No Data", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $portText = $txtFilterPort.Text.Trim()
    if ([string]::IsNullOrEmpty($portText)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a port number.", "No Port", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    if (-not ($portText -match '^\d+$')) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a valid port number.", "Invalid Port", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    
    $port = [int]$portText
    $portType = $cmbPortType.SelectedItem
    
    $statusLabel.Text = "Filtering by port $port..."
    [System.Windows.Forms.Application]::DoEvents()
    
    $filtered = switch ($portType) {
        "Source Port" { $script:Config.FilteredData | Where-Object { $_.SourcePort -eq $port } }
        "Destination Port" { $script:Config.FilteredData | Where-Object { $_.DestinationPort -eq $port } }
        default { $script:Config.FilteredData | Where-Object { $_.SourcePort -eq $port -or $_.DestinationPort -eq $port } }
    }
    
    $filtered = @($filtered)
    
    Update-PortSummaryGrid -DataGridView $dgvPortSummary -Data $filtered -StatsTextBox $txtPortStats
    $statusLabel.Text = "Showing $($filtered.Count) records for port $port ($portType)"
})

# Show all ports button
$btnShowAllPorts.Add_Click({
    if ($null -eq $script:Config.FilteredData -or $script:Config.FilteredData.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please load data first.", "No Data", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $statusLabel.Text = "Loading all port data..."
    [System.Windows.Forms.Application]::DoEvents()
    
    Update-PortSummaryGrid -DataGridView $dgvPortSummary -Data $script:Config.FilteredData -StatsTextBox $txtPortStats
    $txtFilterPort.Text = ""
    $statusLabel.Text = "Showing all port data"
})

# Common ports dropdown selection
$cmbCommonPorts.Add_SelectedIndexChanged({
    if ($cmbCommonPorts.SelectedIndex -le 0) { return }
    
    $selected = $cmbCommonPorts.SelectedItem.ToString()
    $portMatch = [regex]::Match($selected, '^(\d+)')
    
    if ($portMatch.Success) {
        $txtFilterPort.Text = $portMatch.Groups[1].Value
        $cmbPortType.SelectedIndex = 2  # Destination Port
    }
})

# ============================================
# IP OWNER LOOKUP EVENT HANDLERS
# ============================================

function Update-IPOwnerGrid {
    param(
        [System.Windows.Forms.DataGridView]$DataGridView,
        [hashtable]$OwnerData,
        [array]$IPSummaryData,
        [System.Windows.Forms.RichTextBox]$StatsTextBox
    )
    
    $DataGridView.SuspendLayout()
    $DataGridView.Visible = $false
    
    try {
        $DataGridView.Columns.Clear()
        $DataGridView.Rows.Clear()
        
        if ($null -eq $OwnerData -or $OwnerData.Count -eq 0) {
            return
        }
        
        # Add columns
        $columns = @(
            @{ Name = "IPAddress"; Header = "IP Address"; Width = 130 }
            @{ Name = "Owner"; Header = "Owner/Org"; Width = 200 }
            @{ Name = "ISP"; Header = "ISP"; Width = 180 }
            @{ Name = "AS"; Header = "AS Number"; Width = 160 }
            @{ Name = "Country"; Header = "Country"; Width = 100 }
            @{ Name = "City"; Header = "City"; Width = 100 }
            @{ Name = "Connections"; Header = "Connections"; Width = 90 }
            @{ Name = "TotalData"; Header = "Total Data"; Width = 100 }
        )
        
        foreach ($col in $columns) {
            $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
            $column.Name = $col.Name
            $column.HeaderText = $col.Header
            $column.Width = $col.Width
            $DataGridView.Columns.Add($column) | Out-Null
        }
        
        # Build a lookup from IP summary data for connection counts
        $ipStats = @{}
        if ($IPSummaryData) {
            $ipSummary = Get-IPSummary -Data $IPSummaryData
            foreach ($s in $ipSummary) {
                $ipStats[$s.IPAddress] = $s
            }
        }
        
        # Sort: public IPs first (by connections desc), then private
        $sortedEntries = $OwnerData.Values | Sort-Object @{Expression={$_.Status -eq 'private'}}, @{Expression={
            if ($ipStats.ContainsKey($_.IP)) { $ipStats[$_.IP].TotalConnections } else { 0 }
        }; Descending=$true}
        
        foreach ($entry in $sortedEntries) {
            $connections = 0
            $totalData = "N/A"
            if ($ipStats.ContainsKey($entry.IP)) {
                $connections = $ipStats[$entry.IP].TotalConnections
                $totalData = $ipStats[$entry.IP].TotalBytesFormatted
            }
            
            $row = $DataGridView.Rows.Add()
            $DataGridView.Rows[$row].Cells["IPAddress"].Value = $entry.IP
            $DataGridView.Rows[$row].Cells["Owner"].Value = $entry.Owner
            $DataGridView.Rows[$row].Cells["ISP"].Value = $entry.ISP
            $DataGridView.Rows[$row].Cells["AS"].Value = $entry.AS
            $DataGridView.Rows[$row].Cells["Country"].Value = $entry.Country
            $DataGridView.Rows[$row].Cells["City"].Value = $entry.City
            $DataGridView.Rows[$row].Cells["Connections"].Value = $connections
            $DataGridView.Rows[$row].Cells["TotalData"].Value = $totalData
            
            # Color code: private = light blue, failed/error = light red
            if ($entry.Status -eq 'private') {
                $DataGridView.Rows[$row].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(220, 235, 252)
            }
            elseif ($entry.Status -eq 'failed' -or $entry.Status -eq 'error') {
                $DataGridView.Rows[$row].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 220)
            }
        }
        
        # Update stats
        if ($StatsTextBox) {
            $publicIPs = @($OwnerData.Values | Where-Object { $_.Status -ne 'private' })
            $privateIPs = @($OwnerData.Values | Where-Object { $_.Status -eq 'private' })
            $successIPs = @($OwnerData.Values | Where-Object { $_.Status -eq 'success' })
            
            # Group by owner/org
            $ownerGroups = $successIPs | Group-Object -Property Owner | Sort-Object -Property Count -Descending
            
            # Group by country
            $countryGroups = $successIPs | Where-Object { $_.Country -ne 'N/A' } | Group-Object -Property Country | Sort-Object -Property Count -Descending
            
            $statsText = "IP OWNER STATISTICS`n"
            $statsText += "========================================`n`n"
            $statsText += "Total IPs Analyzed:  $($OwnerData.Count)`n"
            $statsText += "Public IPs:          $($publicIPs.Count)`n"
            $statsText += "Private/Reserved:    $($privateIPs.Count)`n"
            $statsText += "Successfully Resolved: $($successIPs.Count)`n`n"
            
            $statsText += "TOP ORGANIZATIONS`n"
            $statsText += "----------------------------------------`n"
            $top10Orgs = $ownerGroups | Select-Object -First 10
            foreach ($org in $top10Orgs) {
                $statsText += "$($org.Count.ToString().PadLeft(5)) IPs - $($org.Name)`n"
            }
            
            $statsText += "`nTOP COUNTRIES`n"
            $statsText += "----------------------------------------`n"
            $top10Countries = $countryGroups | Select-Object -First 10
            foreach ($country in $top10Countries) {
                $statsText += "$($country.Count.ToString().PadLeft(5)) IPs - $($country.Name)`n"
            }
            
            $StatsTextBox.Text = $statsText
        }
    }
    finally {
        $DataGridView.Visible = $true
        $DataGridView.ResumeLayout()
    }
}

# Lookup All Public IP Owners button
$btnLookupIPOwners.Add_Click({
    if ($null -eq $script:Config.FilteredData -or $script:Config.FilteredData.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please load flow log data first.", "No Data", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $statusLabel.Text = "Collecting unique IP addresses..."
    $progressBar.Visible = $true
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $mainForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnLookupIPOwners.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    
    try {
        # Get all unique IPs from current filtered data
        $allIPs = @()
        $allIPs += @($script:Config.FilteredData | Select-Object -ExpandProperty SourceIP -Unique)
        $allIPs += @($script:Config.FilteredData | Select-Object -ExpandProperty DestinationIP -Unique)
        $uniqueIPs = @($allIPs | Sort-Object -Unique)
        
        $statusLabel.Text = "Found $($uniqueIPs.Count) unique IPs. Starting ownership lookups..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Progress callback to update status bar
        $progressCallback = {
            param($message)
            $statusLabel.Text = $message
            [System.Windows.Forms.Application]::DoEvents()
        }
        
        # Perform bulk lookup
        $ownerResults = Get-BulkIPOwnerInfo -IPAddresses $uniqueIPs -ProgressCallback $progressCallback
        
        $statusLabel.Text = "Updating IP Owner grid..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Store results for export
        $script:IPOwnerResults = $ownerResults
        
        # Update the IP Owners tab grid
        Update-IPOwnerGrid -DataGridView $dgvIPOwners -OwnerData $ownerResults -IPSummaryData $script:Config.FilteredData -StatsTextBox $txtIPOwnerStats
        
        # Refresh Flow Log Details grid with owner columns
        $statusLabel.Text = "Refreshing Flow Log Details with owner data..."
        [System.Windows.Forms.Application]::DoEvents()
        Update-FlowLogGrid -DataGridView $dgvFlowLogs -Data $script:Config.FilteredData -IPOwnerCache $ownerResults
        
        # Refresh IP Summary grid with owner columns
        $statusLabel.Text = "Refreshing IP Summary with owner data..."
        [System.Windows.Forms.Application]::DoEvents()
        Update-IPSummaryGrid -DataGridView $dgvIPSummary -Data $script:Config.FilteredData -StatsTextBox $txtStats -IPOwnerCache $ownerResults
        
        $publicCount = @($ownerResults.Values | Where-Object { $_.Status -ne 'private' }).Count
        $statusLabel.Text = "IP owner lookup complete. $publicCount public IPs resolved out of $($uniqueIPs.Count) total."
    }
    catch {
        $errorMessage = $_.Exception.Message
        $statusLabel.Text = "IP owner lookup failed"
        [System.Windows.Forms.MessageBox]::Show("Error performing IP owner lookup:`n`n$errorMessage", "Lookup Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        $progressBar.Visible = $false
        $mainForm.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnLookupIPOwners.Enabled = $true
    }
})

# Clear IP Owner Cache button
$btnClearIPOwnerCache.Add_Click({
    Clear-IPOwnerCache
    $dgvIPOwners.Rows.Clear()
    $dgvIPOwners.Columns.Clear()
    $txtIPOwnerStats.Text = ""
    $script:IPOwnerResults = $null
    $statusLabel.Text = "IP owner cache cleared"
})

# Export IP Owners to CSV
$btnExportIPOwners.Add_Click({
    if ($null -eq $script:IPOwnerResults -or $script:IPOwnerResults.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No IP owner data to export. Run a lookup first.", "No Data", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    
    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    $saveDialog.DefaultExt = "csv"
    $saveDialog.FileName = "IPOwners_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    
    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:IPOwnerResults.Values | 
            Select-Object IP, Owner, ISP, Org, AS, Country, City, Status | 
            Export-Csv -Path $saveDialog.FileName -NoTypeInformation
        [System.Windows.Forms.MessageBox]::Show("IP owner data exported successfully.", "Export Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# Context menu - Copy IP from IP Owners grid
$copyIPOwnerMenuItem.Add_Click({
    if ($dgvIPOwners.SelectedRows.Count -gt 0) {
        $ips = ($dgvIPOwners.SelectedRows | ForEach-Object { $_.Cells["IPAddress"].Value }) -join "`r`n"
        [System.Windows.Forms.Clipboard]::SetText($ips)
    }
})

# Context menu - Copy Owner Info from IP Owners grid
$copyOwnerInfoMenuItem.Add_Click({
    if ($dgvIPOwners.SelectedRows.Count -gt 0) {
        $info = ($dgvIPOwners.SelectedRows | ForEach-Object { 
            "$($_.Cells["IPAddress"].Value) | $($_.Cells["Owner"].Value) | $($_.Cells["ISP"].Value) | $($_.Cells["Country"].Value)"
        }) -join "`r`n"
        [System.Windows.Forms.Clipboard]::SetText($info)
    }
})

# Form Load event - set splitter distance after form is sized
$mainForm.Add_Load({
    $mainSplitContainer.SplitterDistance = 115
})

# Form Closing event - clean up timer and job
$mainForm.Add_FormClosing({
    if ($script:LoadTimer) {
        $script:LoadTimer.Stop()
    }
    if ($script:LoadJob) {
        Stop-Job -Job $script:LoadJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:LoadJob -Force -ErrorAction SilentlyContinue
    }
})

# ============================================
# BUTTON TOOLTIPS
# ============================================
$toolTip.SetToolTip($btnLoadData, "Load flow log data from Azure for the selected date range")
$toolTip.SetToolTip($btnCancelLoad, "Cancel the current data loading operation")
$toolTip.SetToolTip($btnSearch, "Search for records matching IP address and/or port filters")
$toolTip.SetToolTip($btnClearSearch, "Clear all search filters and show all records")
$toolTip.SetToolTip($txtSearchIP, "Enter an IP address to search (partial match supported)")
$toolTip.SetToolTip($txtSrcPort, "Filter by source port number")
$toolTip.SetToolTip($txtDstPort, "Filter by destination port number")
$toolTip.SetToolTip($btnAddIP, "Add the entered IP address to the exclusion list")
$toolTip.SetToolTip($btnRemoveIP, "Remove selected IP address(es) from the exclusion list")
$toolTip.SetToolTip($btnAddRange, "Add the entered CIDR range (e.g., 10.0.0.0/8) to the exclusion list")
$toolTip.SetToolTip($btnRemoveRange, "Remove selected CIDR range(s) from the exclusion list")
$toolTip.SetToolTip($btnApplyExclusions, "Filter out all records matching the excluded IPs and CIDR ranges")
$toolTip.SetToolTip($btnSaveExclusions, "Save the current exclusion list to a JSON file")
$toolTip.SetToolTip($btnLoadExclusions, "Load a previously saved exclusion list from a JSON file")
$toolTip.SetToolTip($btnAddAzureRanges, "Download and add all Azure public IP ranges to the exclusion list")
$toolTip.SetToolTip($btnClearExclusions, "Remove all IP addresses and CIDR ranges from the exclusion lists")
$toolTip.SetToolTip($btnFilterByPort, "Filter the data to show only records with the specified port number")
$toolTip.SetToolTip($btnShowAllPorts, "Clear the port filter and show all port data")
$toolTip.SetToolTip($btnAzureSignIn, "Sign in to Azure using your Microsoft account")
$toolTip.SetToolTip($btnLookupIPOwners, "Look up ownership info for all public IPs using ip-api.com (free)")
$toolTip.SetToolTip($btnClearIPOwnerCache, "Clear the cached IP owner lookup results")
$toolTip.SetToolTip($btnExportIPOwners, "Export IP owner lookup results to a CSV file")

# Show the form
[void]$mainForm.ShowDialog()
