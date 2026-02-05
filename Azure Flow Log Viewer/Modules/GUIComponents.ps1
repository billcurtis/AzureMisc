#Requires -Version 5.1
<#
.SYNOPSIS
    GUI Components Module
.DESCRIPTION
    Functions for updating and managing GUI components
#>

function Update-FlowLogGrid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.DataGridView]$DataGridView,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Data
    )
    
    # Suspend drawing for performance
    $DataGridView.SuspendLayout()
    $DataGridView.Visible = $false
    
    try {
        $DataGridView.Rows.Clear()
        $DataGridView.Columns.Clear()
        
        if ($null -eq $Data -or $Data.Count -eq 0) {
            return
        }
        
        # Add columns
        $columns = @(
            @{ Name = "Timestamp"; Header = "Timestamp"; Width = 140 }
            @{ Name = "SourceIP"; Header = "Source IP"; Width = 120 }
            @{ Name = "SourcePort"; Header = "Src Port"; Width = 70 }
            @{ Name = "DestinationIP"; Header = "Destination IP"; Width = 120 }
            @{ Name = "DestinationPort"; Header = "Dst Port"; Width = 70 }
            @{ Name = "Protocol"; Header = "Protocol"; Width = 70 }
            @{ Name = "DirectionFull"; Header = "Direction"; Width = 80 }
            @{ Name = "ActionFull"; Header = "Action"; Width = 70 }
            @{ Name = "FlowStateFull"; Header = "State"; Width = 80 }
            @{ Name = "TotalBytesDisplay"; Header = "Total MB"; Width = 100 }
            @{ Name = "TotalPackets"; Header = "Packets"; Width = 70 }
            @{ Name = "RuleName"; Header = "Rule"; Width = 200 }
        )
        
        foreach ($col in $columns) {
            $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
            $column.Name = $col.Name
            $column.HeaderText = $col.Header
            $column.Width = $col.Width
            # Set ValueType for numeric columns to enable proper sorting
            if ($col.Name -eq "TotalBytesDisplay") {
                $column.ValueType = [double]
            }
            elseif ($col.Name -in @("SourcePort", "DestinationPort", "TotalPackets")) {
                $column.ValueType = [int]
            }
            $DataGridView.Columns.Add($column) | Out-Null
        }
        
        # Pre-allocate rows for better performance
        $rowCount = $Data.Count
        $counter = 0
        
        # Add rows in batches
        foreach ($record in $Data) {
            $row = $DataGridView.Rows.Add()
            $DataGridView.Rows[$row].Cells["Timestamp"].Value = $record.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
            $DataGridView.Rows[$row].Cells["SourceIP"].Value = $record.SourceIP
            $DataGridView.Rows[$row].Cells["SourcePort"].Value = [int]($record.SourcePort ?? 0)
            $DataGridView.Rows[$row].Cells["DestinationIP"].Value = $record.DestinationIP
            $DataGridView.Rows[$row].Cells["DestinationPort"].Value = [int]($record.DestinationPort ?? 0)
            $DataGridView.Rows[$row].Cells["Protocol"].Value = $record.Protocol
            $DataGridView.Rows[$row].Cells["DirectionFull"].Value = $record.DirectionFull
            $DataGridView.Rows[$row].Cells["ActionFull"].Value = $record.ActionFull
            $DataGridView.Rows[$row].Cells["FlowStateFull"].Value = $record.FlowStateFull
            $DataGridView.Rows[$row].Cells["TotalBytesDisplay"].Value = [double]([math]::Round(($record.TotalBytes ?? 0) / 1MB, 2))
            $DataGridView.Rows[$row].Cells["TotalPackets"].Value = [int]($record.TotalPackets ?? 0)
            $DataGridView.Rows[$row].Cells["RuleName"].Value = $record.RuleName
            
            # Color code by action
            if ($record.Action -eq 'D') {
                $DataGridView.Rows[$row].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 200, 200)
            }
            
            # Process events every 500 rows to keep UI responsive
            $counter++
            if ($counter % 500 -eq 0) {
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    }
    finally {
        # Resume drawing
        $DataGridView.Visible = $true
        $DataGridView.ResumeLayout()
    }
}

function Update-IPSummaryGrid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.DataGridView]$DataGridView,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Data,
        
        [Parameter(Mandatory = $false)]
        [System.Windows.Forms.RichTextBox]$StatsTextBox = $null
    )
    
    $DataGridView.Rows.Clear()
    $DataGridView.Columns.Clear()
    
    if ($null -eq $Data -or $Data.Count -eq 0) {
        return
    }
    
    # Get IP summary
    $ipSummary = Get-IPSummary -Data $Data
    
    # Add columns
    $columns = @(
        @{ Name = "IPAddress"; Header = "IP Address"; Width = 130 }
        @{ Name = "TotalConnections"; Header = "Connections"; Width = 90 }
        @{ Name = "AsSource"; Header = "As Source"; Width = 80 }
        @{ Name = "AsDestination"; Header = "As Dest"; Width = 80 }
        @{ Name = "TotalBytesFormatted"; Header = "Total Data"; Width = 100 }
        @{ Name = "Megabytes"; Header = "Megabytes"; Width = 100 }
        @{ Name = "TotalPackets"; Header = "Packets"; Width = 80 }
        @{ Name = "FirstSeen"; Header = "First Seen"; Width = 140 }
        @{ Name = "LastSeen"; Header = "Last Seen"; Width = 140 }
    )
    
    foreach ($col in $columns) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $col.Name
        $column.HeaderText = $col.Header
        $column.Width = $col.Width
        $DataGridView.Columns.Add($column) | Out-Null
    }
    
    # Add rows
    foreach ($record in $ipSummary) {
        $row = $DataGridView.Rows.Add()
        $DataGridView.Rows[$row].Cells["IPAddress"].Value = $record.IPAddress
        $DataGridView.Rows[$row].Cells["TotalConnections"].Value = $record.TotalConnections
        $DataGridView.Rows[$row].Cells["AsSource"].Value = $record.AsSource
        $DataGridView.Rows[$row].Cells["AsDestination"].Value = $record.AsDestination
        $DataGridView.Rows[$row].Cells["TotalBytesFormatted"].Value = $record.TotalBytesFormatted
        $DataGridView.Rows[$row].Cells["Megabytes"].Value = [math]::Round($record.TotalBytes / 1MB, 2)
        $DataGridView.Rows[$row].Cells["TotalPackets"].Value = $record.TotalPackets
        $DataGridView.Rows[$row].Cells["FirstSeen"].Value = $record.FirstSeen.ToString("yyyy-MM-dd HH:mm:ss")
        $DataGridView.Rows[$row].Cells["LastSeen"].Value = $record.LastSeen.ToString("yyyy-MM-dd HH:mm:ss")
    }
    
    # Update statistics
    if ($null -ne $StatsTextBox) {
        $totalRecords = $Data.Count
        $uniqueSourceIPs = ($Data | Select-Object -ExpandProperty SourceIP -Unique).Count
        $uniqueDestIPs = ($Data | Select-Object -ExpandProperty DestinationIP -Unique).Count
        $totalBytes = ($Data | Measure-Object -Property TotalBytes -Sum).Sum
        $totalPackets = ($Data | Measure-Object -Property TotalPackets -Sum).Sum
        $allowedCount = ($Data | Where-Object { $_.Action -eq 'A' }).Count
        $deniedCount = ($Data | Where-Object { $_.Action -eq 'D' }).Count
        $inboundCount = ($Data | Where-Object { $_.Direction -eq 'I' }).Count
        $outboundCount = ($Data | Where-Object { $_.Direction -eq 'O' }).Count
        
        $topSourceIP = $ipSummary | Where-Object { $_.AsSource -gt 0 } | Sort-Object -Property TotalBytes -Descending | Select-Object -First 1
        $topDestIP = $ipSummary | Where-Object { $_.AsDestination -gt 0 } | Sort-Object -Property TotalBytes -Descending | Select-Object -First 1
        
        $stats = @"
FLOW LOG STATISTICS
==========================================

Total Flow Records:     $totalRecords
Unique Source IPs:      $uniqueSourceIPs
Unique Destination IPs: $uniqueDestIPs

DATA TRANSFER
------------------------------------------
Total Data Transferred: $(Format-ByteSize -Bytes $totalBytes)
Total Packets:          $totalPackets

TRAFFIC BREAKDOWN
------------------------------------------
Allowed:   $allowedCount ($([math]::Round(($allowedCount / $totalRecords) * 100, 1))%)
Denied:    $deniedCount ($([math]::Round(($deniedCount / $totalRecords) * 100, 1))%)
Inbound:   $inboundCount ($([math]::Round(($inboundCount / $totalRecords) * 100, 1))%)
Outbound:  $outboundCount ($([math]::Round(($outboundCount / $totalRecords) * 100, 1))%)

TOP TALKERS
------------------------------------------
Top Source IP:      $($topSourceIP.IPAddress)
                    $(Format-ByteSize -Bytes $topSourceIP.TotalBytes)

Top Destination IP: $($topDestIP.IPAddress)
                    $(Format-ByteSize -Bytes $topDestIP.TotalBytes)
"@
        
        $StatsTextBox.Text = $stats
    }
}

function Update-TimeSummaryGrid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.DataGridView]$DataGridView,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Data,
        
        [Parameter(Mandatory = $true)]
        [string]$GroupBy
    )
    
    $DataGridView.Rows.Clear()
    $DataGridView.Columns.Clear()
    
    if ($null -eq $Data -or $Data.Count -eq 0) {
        return
    }
    
    # Get time summary
    $timeSummary = Get-TimeSummary -Data $Data -GroupBy $GroupBy
    
    # Add columns
    $columns = @(
        @{ Name = "Period"; Header = "Period"; Width = 120 }
        @{ Name = "TotalConnections"; Header = "Connections"; Width = 90 }
        @{ Name = "TotalBytesFormatted"; Header = "Total Data"; Width = 100 }
        @{ Name = "TotalPackets"; Header = "Packets"; Width = 80 }
        @{ Name = "UniqueSourceIPs"; Header = "Src IPs"; Width = 70 }
        @{ Name = "UniqueDestIPs"; Header = "Dst IPs"; Width = 70 }
        @{ Name = "AllowedCount"; Header = "Allowed"; Width = 70 }
        @{ Name = "DeniedCount"; Header = "Denied"; Width = 70 }
        @{ Name = "InboundCount"; Header = "Inbound"; Width = 70 }
        @{ Name = "OutboundCount"; Header = "Outbound"; Width = 70 }
    )
    
    foreach ($col in $columns) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $col.Name
        $column.HeaderText = $col.Header
        $column.Width = $col.Width
        $DataGridView.Columns.Add($column) | Out-Null
    }
    
    # Add rows
    foreach ($record in $timeSummary) {
        $row = $DataGridView.Rows.Add()
        $DataGridView.Rows[$row].Cells["Period"].Value = $record.Period
        $DataGridView.Rows[$row].Cells["TotalConnections"].Value = $record.TotalConnections
        $DataGridView.Rows[$row].Cells["TotalBytesFormatted"].Value = $record.TotalBytesFormatted
        $DataGridView.Rows[$row].Cells["TotalPackets"].Value = $record.TotalPackets
        $DataGridView.Rows[$row].Cells["UniqueSourceIPs"].Value = $record.UniqueSourceIPs
        $DataGridView.Rows[$row].Cells["UniqueDestIPs"].Value = $record.UniqueDestIPs
        $DataGridView.Rows[$row].Cells["AllowedCount"].Value = $record.AllowedCount
        $DataGridView.Rows[$row].Cells["DeniedCount"].Value = $record.DeniedCount
        $DataGridView.Rows[$row].Cells["InboundCount"].Value = $record.InboundCount
        $DataGridView.Rows[$row].Cells["OutboundCount"].Value = $record.OutboundCount
    }
}

function Update-IPPerTimeGrid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.DataGridView]$DataGridView,
        
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Data
    )
    
    $DataGridView.Rows.Clear()
    $DataGridView.Columns.Clear()
    
    if ($null -eq $Data -or $Data.Count -eq 0) {
        return
    }
    
    # Add columns
    $columns = @(
        @{ Name = "IPAddress"; Header = "IP Address"; Width = 130 }
        @{ Name = "TotalConnections"; Header = "Connections"; Width = 90 }
        @{ Name = "TotalBytesFormatted"; Header = "Total Data"; Width = 100 }
        @{ Name = "TotalPackets"; Header = "Packets"; Width = 80 }
    )
    
    foreach ($col in $columns) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $col.Name
        $column.HeaderText = $col.Header
        $column.Width = $col.Width
        $DataGridView.Columns.Add($column) | Out-Null
    }
    
    # Add rows
    foreach ($record in $Data) {
        $row = $DataGridView.Rows.Add()
        $DataGridView.Rows[$row].Cells["IPAddress"].Value = $record.IPAddress
        $DataGridView.Rows[$row].Cells["TotalConnections"].Value = $record.TotalConnections
        $DataGridView.Rows[$row].Cells["TotalBytesFormatted"].Value = $record.TotalBytesFormatted
        $DataGridView.Rows[$row].Cells["TotalPackets"].Value = $record.TotalPackets
    }
}

function Show-ProgressForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        
        [Parameter(Mandatory = $false)]
        [string]$Message = "Please wait..."
    )
    
    $progressForm = New-Object System.Windows.Forms.Form
    $progressForm.Text = $Title
    $progressForm.Size = New-Object System.Drawing.Size(400, 150)
    $progressForm.StartPosition = "CenterScreen"
    $progressForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $progressForm.ControlBox = $false
    $progressForm.TopMost = $true
    
    $lblMessage = New-Object System.Windows.Forms.Label
    $lblMessage.Text = $Message
    $lblMessage.Location = New-Object System.Drawing.Point(20, 20)
    $lblMessage.AutoSize = $true
    
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(20, 50)
    $progressBar.Size = New-Object System.Drawing.Size(350, 30)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    
    $progressForm.Controls.AddRange(@($lblMessage, $progressBar))
    
    return $progressForm
}

function Show-InputDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        
        [Parameter(Mandatory = $false)]
        [string]$DefaultValue = ""
    )
    
    $inputForm = New-Object System.Windows.Forms.Form
    $inputForm.Text = $Title
    $inputForm.Size = New-Object System.Drawing.Size(400, 150)
    $inputForm.StartPosition = "CenterScreen"
    $inputForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $inputForm.MaximizeBox = $false
    $inputForm.MinimizeBox = $false
    
    $lblPrompt = New-Object System.Windows.Forms.Label
    $lblPrompt.Text = $Prompt
    $lblPrompt.Location = New-Object System.Drawing.Point(10, 15)
    $lblPrompt.AutoSize = $true
    
    $txtInput = New-Object System.Windows.Forms.TextBox
    $txtInput.Text = $DefaultValue
    $txtInput.Location = New-Object System.Drawing.Point(10, 40)
    $txtInput.Size = New-Object System.Drawing.Size(360, 23)
    
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Location = New-Object System.Drawing.Point(200, 75)
    $btnOK.Size = New-Object System.Drawing.Size(80, 25)
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(290, 75)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 25)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    
    $inputForm.AcceptButton = $btnOK
    $inputForm.CancelButton = $btnCancel
    $inputForm.Controls.AddRange(@($lblPrompt, $txtInput, $btnOK, $btnCancel))
    
    $result = $inputForm.ShowDialog()
    
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $txtInput.Text
    }
    return $null
}
