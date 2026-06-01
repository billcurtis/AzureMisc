<#
.SYNOPSIS
    *** SAMPLE SCRIPT - USE AT YOUR OWN RISK ***

    Checks the installed Azure Virtual Desktop (AVD) agent components on the local
    session host and updates them to the latest stable versions published by Microsoft
    if they are out of date.

.DISCLAIMER
    THIS SCRIPT IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED. It is a SAMPLE intended to serve as a BLUEPRINT only. You should
    review, adapt, and TEST it thoroughly in a non-production environment before
    using any portion of it against production AVD session hosts. The author
    accepts no responsibility for any damage, downtime, data loss, or other
    impact resulting from its use. Treat this script as reference material for
    building your own supported, validated upgrade tooling.

.DESCRIPTION
    AVD session hosts run two core MSI-installed components:
        * Remote Desktop Services Infrastructure Agent ("RDInfra.RDAgent")
        * Remote Desktop Agent Boot Loader            ("Microsoft.RDInfra.RDAgentBootLoader")

    Microsoft publishes the latest stable installers at fixed redirect URIs. This
    script downloads the current MSIs, extracts their ProductVersion, compares
    them against what is installed locally (queried via the registry uninstall
    keys), and silently reinstalls any component whose published version is
    newer than the installed one.

    The script must be run elevated, directly on the AVD session host VM.

    Optional components such as FSLogix, the Multimedia Redirection extension,
    Geneva Monitoring agent, and the Side-by-Side stack are intentionally NOT
    handled here - those have separate installers and lifecycles.

.PARAMETER WorkingDirectory
    Folder used to stage downloaded MSIs and install logs. Created if missing.

.PARAMETER Force
    Reinstall components even when the published version is not newer than the
    installed version.

.PARAMETER MaxCacheAge
    How long to trust the cached "latest version" sidecar before re-checking
    the Microsoft download URI. Default is 24 hours. Set to [TimeSpan]::Zero
    to always re-check.

.PARAMETER LogPath
    Path to the run log file. If not supplied, the script writes a timestamped
    log into the hardcoded $DefaultLogDirectory at the top of the script
    (falling back to <WorkingDirectory>\Logs if that variable is empty).
    Pass an empty string to disable file logging. A matching *.transcript.log
    file is produced alongside it.

.EXAMPLE
    .\Update-AVDAgentComponents.ps1

.EXAMPLE
    .\Update-AVDAgentComponents.ps1 -Force -Verbose

.EXAMPLE
    .\Update-AVDAgentComponents.ps1 -LogPath 'C:\Logs\avd-upgrade.log'

.NOTES
    The RDAgentBootLoader service is responsible for self-updating the RDAgent
    in normal operation. Use this script when that mechanism has failed or when
    a controlled, immediate upgrade is required (e.g. troubleshooting, image
    refresh validation, addressing a Health Check failure).
#>

[CmdletBinding()]
param(
    # Folder used to stage downloaded MSIs and install logs.
    [string]$WorkingDirectory = (Join-Path $env:ProgramData 'AVDAgentUpgrade'),

    # If supplied, reinstall the MSIs even when the installed version is already current.
    [switch]$Force,

    # How long to trust the cached "latest version" sidecar before re-checking
    # the Microsoft download URI. Default 24 hours. Set to [TimeSpan]::Zero to
    # always re-check.
    [TimeSpan]$MaxCacheAge = ([TimeSpan]::FromHours(24)),

    # Path to the run log file. Defaults to a timestamped file under the
    # $DefaultLogDirectory defined near the top of the script.
    [string]$LogPath
)

# Fail fast on any unhandled error so a partial upgrade does not silently continue.
$ErrorActionPreference = 'Stop'

# ###########################################################################
# USER-EDITABLE DEFAULTS
# ---------------------------------------------------------------------------
# Hardcode your preferred log directory here. The -LogPath parameter, if
# supplied at invocation, ALWAYS wins. Otherwise the run log and transcript
# are written under this folder with a timestamped, host-stamped filename.
# Use $null or '' to fall back to "<WorkingDirectory>\Logs".
# ###########################################################################
$DefaultLogDirectory = 'C:\ProgramData\AVDAgentUpgrade\Logs'
# ###########################################################################

# ---------------------------------------------------------------------------
# Component catalog
# ---------------------------------------------------------------------------
# Each entry describes one MSI-installed AVD component:
#   DisplayNameLike : substring used to locate it in the registry uninstall keys
#   FileName        : local filename to save the downloaded MSI as
#   Uri             : Microsoft "evergreen" download link (always redirects to
#                     the current stable build)
#   ServiceName     : Windows service that must be stopped during the upgrade
#                     so the MSI can replace locked binaries cleanly
# ---------------------------------------------------------------------------
$Components = @(
    [pscustomobject]@{
        Name           = 'Remote Desktop Services Infrastructure Agent'
        DisplayNameLike = 'Remote Desktop Services Infrastructure Agent'
        FileName       = 'AVDAgent.msi'
        Uri            = 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv'
        ServiceName    = 'RDAgent'
    },
    [pscustomobject]@{
        Name           = 'Remote Desktop Agent Boot Loader'
        DisplayNameLike = 'Remote Desktop Agent Boot Loader'
        FileName       = 'AVDBootLoader.msi'
        Uri            = 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH'
        ServiceName    = 'RDAgentBootLoader'
    }
)

# Returns $true when the current process is running with administrator rights.
# MSI install/uninstall and stopping the RDAgent services both require elevation.
function Test-IsAdministrator {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Cheap sanity check that we are on an AVD session host. The boot loader service
# is installed as part of every session host and is not present on stock Windows.
function Test-IsSessionHost {
    [bool](Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue)
}

# Reads the currently installed version of a component from the Windows
# uninstall registry keys (both 64-bit and 32-bit hives are checked). Returns
# $null when the component is not installed at all.
function Get-InstalledMsiVersion {
    param([Parameter(Mandatory)][string]$DisplayNameLike)

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*$DisplayNameLike*" } |
        Sort-Object -Property DisplayVersion -Descending |
        Select-Object -First 1 -ExpandProperty DisplayVersion
}

# Extracts the ProductVersion property out of an MSI file WITHOUT installing it,
# by opening the MSI as a database through the WindowsInstaller COM API and
# running a SQL query against its Property table. This is how we know what
# version the freshly downloaded MSI represents so we can compare it against
# what is already installed.
function Get-MsiProductVersion {
    param([Parameter(Mandatory)][string]$Path)

    $installer = New-Object -ComObject WindowsInstaller.Installer
    try {
        $db = $installer.GetType().InvokeMember(
            'OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember(
            'OpenView', 'InvokeMethod', $null, $db,
            @("SELECT Value FROM Property WHERE Property = 'ProductVersion'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        $version = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1)
        return $version
    }
    finally {
        # COM objects from WindowsInstaller must be released explicitly,
        # otherwise the MSI file stays locked and the install step later fails.
        if ($view)      { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view) }
        if ($db)        { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db) }
        if ($installer) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}

# Numeric version compare. Returns >0 when Candidate (downloaded MSI) is newer
# than Installed, 0 when equal, <0 when older. If nothing is installed yet we
# return 1 so the component is treated as needing installation.
function Compare-Version {
    param([string]$Installed, [string]$Candidate)

    $iv = $null; $cv = $null
    if (-not [version]::TryParse($Installed,  [ref]$iv)) { return 1 }
    if (-not [version]::TryParse($Candidate, [ref]$cv))  { return 0 }
    return $cv.CompareTo($iv)
}

# Resolves the Microsoft "evergreen" download URI to its final blob URL using
# a HEAD request that follows redirects, then extracts the version from the
# resolved filename (or Content-Disposition). The CMS redirect always lands
# on a file named like "Microsoft.RDInfra.RDAgent.Installer-x64-1.0.14114.100.msi"
# so we can determine the latest published ProductVersion WITHOUT downloading
# the MSI body. Returns $null if the version cannot be parsed.
function Get-LatestPublishedVersion {
    param([Parameter(Mandatory)][string]$Uri)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Use HttpClient so we get reliable access to the final RequestUri after
    # all redirects, regardless of PowerShell edition.
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage('Head', $Uri)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { return $null }

        # Candidate strings that may contain the version: the final URL path
        # and the Content-Disposition filename (if the server provides one).
        $candidates = @()
        if ($resp.RequestMessage -and $resp.RequestMessage.RequestUri) {
            $candidates += [System.IO.Path]::GetFileName($resp.RequestMessage.RequestUri.AbsolutePath)
            $candidates += $resp.RequestMessage.RequestUri.AbsoluteUri
        }
        if ($resp.Content -and $resp.Content.Headers.ContentDisposition -and $resp.Content.Headers.ContentDisposition.FileName) {
            $candidates += $resp.Content.Headers.ContentDisposition.FileName.Trim('"')
        }

        # Match a 3- or 4-part version (e.g. 1.0.14114.100). Take the longest
        # such match across all candidates to prefer the most specific one.
        $best = $null
        foreach ($s in $candidates) {
            if (-not $s) { continue }
            foreach ($m in [regex]::Matches($s, '\d+\.\d+\.\d+(?:\.\d+)?')) {
                if (-not $best -or $m.Value.Length -gt $best.Length) { $best = $m.Value }
            }
        }
        return $best
    }
    catch { return $null }
    finally {
        if ($client)  { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

# Sidecar cache helpers. After we successfully determine the latest published
# ProductVersion for a component (by downloading the MSI and reading it), we
# persist {ProductVersion, CheckedAtUtc} to a small JSON file next to the MSI.
# On the next run, if the cache is still fresh AND the installed version
# already meets or exceeds the cached version, we skip the network call
# entirely. This is what makes repeat runs cheap.
function Read-CachedLatestVersion {
    param([Parameter(Mandatory)][string]$CachePath)

    if (-not (Test-Path -LiteralPath $CachePath)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
        [pscustomobject]@{
            ProductVersion = [string]$obj.ProductVersion
            CheckedAtUtc   = [datetime]$obj.CheckedAtUtc
        }
    }
    catch { $null }
}

function Write-CachedLatestVersion {
    param(
        [Parameter(Mandatory)][string]$CachePath,
        [Parameter(Mandatory)][string]$ProductVersion
    )

    [pscustomobject]@{
        ProductVersion = $ProductVersion
        CheckedAtUtc   = [DateTime]::UtcNow
    } | ConvertTo-Json | Set-Content -LiteralPath $CachePath -Encoding UTF8
}

# ===========================================================================
# Pre-flight checks
# ---------------------------------------------------------------------------
# Refuse to run anywhere we cannot do the job correctly: non-elevated shell,
# or a machine that is not actually an AVD session host.
# ===========================================================================
if (-not (Test-IsAdministrator)) {
    throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
}
if (-not (Test-IsSessionHost)) {
    throw 'RDAgentBootLoader service not found. This script must be run on an AVD session host.'
}

if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
    New-Item -Path $WorkingDirectory -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
# Two log streams:
#   * Transcript  - captures everything written to the host (Write-Host,
#                   Write-Warning, Write-Error, native command output).
#                   Useful for "what did the run look like end-to-end".
#   * Run log     - explicit timestamped, severity-tagged lines written via
#                   Write-Log. Easier to parse / grep after the fact and is
#                   what gets streamed to the console.
# ---------------------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('LogPath')) {
    # Pick the log directory: explicit hardcoded default first, otherwise a
    # Logs subfolder under the working directory.
    $logDir = if ($DefaultLogDirectory) { $DefaultLogDirectory } else { Join-Path $WorkingDirectory 'Logs' }
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    $stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $LogPath = Join-Path $logDir ("Update-AVDAgentComponents_{0}_{1}.log" -f $env:COMPUTERNAME, $stamp)
}

$script:LogPath      = $LogPath
$script:TranscriptOn = $false
if ($LogPath) {
    # Transcript path mirrors the run log but with a .transcript.log suffix.
    $transcriptPath = [IO.Path]::ChangeExtension($LogPath, '.transcript.log')
    try {
        Start-Transcript -Path $transcriptPath -Append -Force | Out-Null
        $script:TranscriptOn = $true
    }
    catch {
        Write-Warning ("Failed to start transcript at {0}: {1}" -f $transcriptPath, $_.Exception.Message)
    }
}

# Emits a timestamped, severity-tagged line to both the host and the run log.
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')]
        [string]$Level = 'INFO'
    )

    $line = "{0} [{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message

    $color = switch ($Level) {
        'INFO'    { 'Gray' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        'DEBUG'   { 'DarkGray' }
    }
    Write-Host $line -ForegroundColor $color

    if ($script:LogPath) {
        try   { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 }
        catch { } # never let logging failures break the run
    }
}

Write-Log ("AVD agent component upgrade check starting on {0}" -f $env:COMPUTERNAME) 'INFO'
Write-Log ("Working dir: {0}" -f $WorkingDirectory) 'INFO'
if ($LogPath) { Write-Log ("Run log    : {0}" -f $LogPath) 'INFO' }
Write-Log ("Force={0}  MaxCacheAge={1}" -f $Force.IsPresent, $MaxCacheAge) 'DEBUG'
Write-Log ('-' * 70) 'INFO'

# Collector for per-component outcomes; printed as a summary table at the end
# and also used to derive the script's exit code.
$results = New-Object System.Collections.Generic.List[object]

try {

# ===========================================================================
# Main loop - process each component independently
# ===========================================================================
foreach ($c in $Components) {
    Write-Log ("[{0}]" -f $c.Name) 'INFO'

    # 1) What version, if any, is installed right now?
    $installedVersion = Get-InstalledMsiVersion -DisplayNameLike $c.DisplayNameLike
    if ($installedVersion) {
        Write-Log ("  Installed version : {0}" -f $installedVersion) 'INFO'
    } else {
        Write-Log '  Installed version : <not installed>' 'WARN'
    }

    # 2) Determine the latest published version WITHOUT downloading the MSI.
    #    The Microsoft CMS evergreen URI redirects to a blob whose filename
    #    embeds the version, so a single HEAD request is enough to know what
    #    version is currently published. If that lookup fails (or returns an
    #    unparseable filename), we fall back to a fresh sidecar cache, and
    #    finally to the slow path of actually downloading the MSI.
    $msiPath   = Join-Path $WorkingDirectory $c.FileName
    $cachePath = "$msiPath.version.json"

    $latestVersion = Get-LatestPublishedVersion -Uri $c.Uri
    if ($latestVersion) {
        Write-Log ("  Latest version    : {0} (resolved via HEAD)" -f $latestVersion) 'INFO'
        Write-CachedLatestVersion -CachePath $cachePath -ProductVersion $latestVersion
    }
    else {
        $cached = Read-CachedLatestVersion -CachePath $cachePath
        if ($cached -and $MaxCacheAge -gt [TimeSpan]::Zero -and
            ([DateTime]::UtcNow - $cached.CheckedAtUtc) -lt $MaxCacheAge) {
            $latestVersion = $cached.ProductVersion
            Write-Log ("  Latest version    : {0} (from cache, HEAD lookup unavailable)" -f $latestVersion) 'WARN'
        }
        else {
            Write-Log '  Latest version    : <unknown - HEAD lookup failed, will download to inspect>' 'WARN'
        }
    }

    # 3) If we know the latest version and the installed version already
    #    satisfies it (and -Force was not used), we are done - no download,
    #    no install.
    if ($latestVersion -and -not $Force.IsPresent -and $installedVersion -and
        (Compare-Version -Installed $installedVersion -Candidate $latestVersion) -le 0) {
        Write-Log '  Status            : Up to date - no action required.' 'SUCCESS'
        $results.Add([pscustomobject]@{
            Component = $c.Name; Installed = $installedVersion; Latest = $latestVersion
            Action = 'None'; Result = 'UpToDate'
        })
        continue
    }

    # 4) Slow path: we either could not determine the latest version, or an
    #    upgrade is required. Download the MSI from Microsoft's evergreen URI.
    #    TLS 1.2 is forced because older PowerShell/.NET defaults can negotiate
    #    SSL3/TLS1.0 which Microsoft endpoints reject.
    Write-Log ("  Downloading       : {0}" -f $c.Uri) 'INFO'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $c.Uri -OutFile $msiPath -UseBasicParsing
    }
    catch {
        Write-Log ("  Failed to download {0}: {1}" -f $c.Name, $_.Exception.Message) 'ERROR'
        $results.Add([pscustomobject]@{
            Component = $c.Name; Installed = $installedVersion; Latest = $latestVersion
            Action = 'DownloadFailed'; Result = $_.Exception.Message
        })
        continue
    }

    # 5) Confirm the downloaded MSI's ProductVersion (authoritative source)
    #    and refresh the sidecar cache for future runs.
    $msiVersion = Get-MsiProductVersion -Path $msiPath
    if ($msiVersion) {
        $latestVersion = $msiVersion
        Write-Log ("  Latest version    : {0} (confirmed from MSI)" -f $latestVersion) 'INFO'
        Write-CachedLatestVersion -CachePath $cachePath -ProductVersion $latestVersion
    }

    # Re-check after downloading: if the installed version turns out to
    # already satisfy what is in the MSI (e.g. HEAD lookup failed but we
    # are actually current), skip the install.
    $cmp = Compare-Version -Installed $installedVersion -Candidate $latestVersion
    if (-not $Force.IsPresent -and $cmp -le 0) {
        Write-Log '  Status            : Up to date - no action required.' 'SUCCESS'
        $results.Add([pscustomobject]@{
            Component = $c.Name; Installed = $installedVersion; Latest = $latestVersion
            Action = 'None'; Result = 'UpToDate'
        })
        continue
    }

    Write-Log '  Status            : Upgrade required.' 'WARN'

    # 6) Stop the associated Windows service so the MSI is not blocked by
    #    locked files (msiexec would otherwise require a reboot to finish).
    $svc = Get-Service -Name $c.ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Log ("  Stopping service  : {0}" -f $c.ServiceName) 'INFO'
        Stop-Service -Name $c.ServiceName -Force -ErrorAction SilentlyContinue
    }

    # 7) Run msiexec silently with full verbose logging in case we need to
    #    troubleshoot a failure after the fact.
    $logFile = Join-Path $WorkingDirectory ("{0}.install.log" -f [IO.Path]::GetFileNameWithoutExtension($c.FileName))
    $msiArgs = @(
        '/i', "`"$msiPath`"",
        '/quiet', '/qn', '/norestart',
        '/l*v', "`"$logFile`""
    )
    Write-Log ("  Installing        : msiexec {0}" -f ($msiArgs -join ' ')) 'INFO'
    Write-Log ("  MSI install log   : {0}" -f $logFile) 'DEBUG'
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru

    # MSI exit codes: 0 = success, 3010 = success but a reboot is needed to
    # complete the operation. Anything else is treated as a failure.
    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Log ("  Install exit code : {0} (success)" -f $proc.ExitCode) 'SUCCESS'
        $newVersion = Get-InstalledMsiVersion -DisplayNameLike $c.DisplayNameLike
        $results.Add([pscustomobject]@{
            Component = $c.Name; Installed = $newVersion; Latest = $latestVersion
            Action = 'Upgraded'; Result = "ExitCode=$($proc.ExitCode)"
        })
    } else {
        Write-Log ("  Install exit code : {0} (failed). See log: {1}" -f $proc.ExitCode, $logFile) 'ERROR'
        $results.Add([pscustomobject]@{
            Component = $c.Name; Installed = $installedVersion; Latest = $latestVersion
            Action = 'UpgradeFailed'; Result = "ExitCode=$($proc.ExitCode); Log=$logFile"
        })
    }

    # 8) Bring the service back online. The new MSI may have reconfigured it,
    #    so we only attempt a start - we do not force a particular state.
    if ($svc) {
        Write-Log ("  Starting service  : {0}" -f $c.ServiceName) 'INFO'
        Start-Service -Name $c.ServiceName -ErrorAction SilentlyContinue
    }
}

# ===========================================================================
# Report
# ===========================================================================
Write-Log ('-' * 70) 'INFO'
Write-Log 'Summary:' 'INFO'
$results | Format-Table -AutoSize | Out-String -Stream | ForEach-Object {
    if ($_.Trim()) { Write-Log $_ 'INFO' }
}

# Non-zero exit if anything failed, so the script is safe to invoke from
# Azure Run Command, Intune, or any other automation that checks exit codes.
$failedCount = $results.Where({ $_.Action -like '*Failed' }).Count
$exitCode = if ($failedCount -gt 0) { 1 } else { 0 }
$exitLevel = if ($exitCode -eq 0) { 'SUCCESS' } else { 'ERROR' }
Write-Log ("Run complete. Failures={0}. ExitCode={1}" -f $failedCount, $exitCode) $exitLevel

}
finally {
    if ($script:TranscriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

exit $exitCode
