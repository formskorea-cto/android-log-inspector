[CmdletBinding()]
param(
    [string]$Serial,
    [string]$InputPath,
    [string]$OutputRoot,
    [string]$ToolRoot,
    [switch]$SkipBugreport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Findings = [System.Collections.Generic.List[object]]::new()
$script:FindingKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:SourcesScanned = [System.Collections.Generic.List[string]]::new()
$script:CollectionSteps = [System.Collections.Generic.List[object]]::new()
$script:WorkCompleted = 0
$script:WorkTotal = 0

function Write-Status {
    param([string]$Message)
    Write-Host "[Android Log Inspector] $Message"
}

function Write-WorkProgress {
    param([string]$Message)

    if ($script:WorkTotal -gt 0) {
        Write-Status "Progress: $($script:WorkCompleted)/$($script:WorkTotal) $Message"
    }
}

function Get-SafeName {
    param([string]$Value)
    return ($Value -replace '[\\/:*?"<>|]', '_')
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-QuotedCommand {
    param(
        [string]$Executable,
        [string[]]$CommandArguments
    )

    $allParts = @($Executable) + $CommandArguments
    return (($allParts | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\\"') + '"' } else { $_ }
    }) -join ' ')
}

function Write-CollectionStatusReport {
    param(
        [string]$CollectionDirectory,
        [string]$DeviceSerial
    )

    $report = [pscustomobject]@{
        SchemaVersion = 1
        DeviceSerial  = $DeviceSerial
        Created       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')
        Steps         = @($script:CollectionSteps)
    }
    Write-Utf8File -Path (Join-Path $CollectionDirectory 'collection-status.json') -Content ($report | ConvertTo-Json -Depth 5)
}

function Invoke-AdbCapture {
    param(
        [string]$AdbPath,
        [string[]]$DeviceArguments,
        [string[]]$CommandArguments,
        [string]$Destination,
        [string]$StatusLabel,
        [bool]$PermissionLimited = $false
    )

    if ([string]::IsNullOrWhiteSpace($StatusLabel)) {
        $StatusLabel = $CommandArguments -join ' '
    }
    Write-Status "Collecting: $StatusLabel"

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('### ' + (Get-QuotedCommand -Executable $AdbPath -CommandArguments ($DeviceArguments + $CommandArguments)))

    try {
        $commandOutput = & $AdbPath @DeviceArguments @CommandArguments 2>&1
        foreach ($outputItem in @($commandOutput)) {
            $lines.Add([string]$outputItem)
        }
        $exitCode = $LASTEXITCODE
    } catch {
        $lines.Add('PowerShell error: ' + $_.Exception.Message)
        $exitCode = -1
    }

    $lines.Add('exit_code=' + $exitCode)
    Write-Utf8File -Path $Destination -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    $collectionStatus = if ($exitCode -eq 0) {
        'Collected'
    } elseif ($PermissionLimited) {
        'NotAvailable'
    } else {
        'Failed'
    }
    $collectionDetail = if ($exitCode -eq 0) {
        'Collected successfully.'
    } elseif ($PermissionLimited) {
        'Android permissions or device policy prevented collection. Analysis continues with the available sources.'
    } else {
        'The ADB command did not complete successfully. Review the matching command output file.'
    }
    $script:CollectionSteps.Add([pscustomobject]@{
        Status     = $collectionStatus
        Label      = $StatusLabel
        ExitCode   = $exitCode
        Detail     = $collectionDetail
        OutputFile = Split-Path -Leaf $Destination
    })
    Write-Status "Completed: $StatusLabel (exit code $exitCode)"
    if ($script:WorkTotal -gt 0) {
        $script:WorkCompleted++
        Write-WorkProgress -Message $StatusLabel
    }
    return $exitCode
}

function Invoke-AdbPull {
    param(
        [string]$AdbPath,
        [string[]]$DeviceArguments,
        [string]$RemotePath,
        [string]$DestinationPath,
        [string]$LogPath,
        [string]$StatusLabel,
        [bool]$PermissionLimited = $false
    )

    $destinationParent = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
    return Invoke-AdbCapture -AdbPath $AdbPath -DeviceArguments $DeviceArguments -CommandArguments @('pull', $RemotePath, $DestinationPath) -Destination $LogPath -StatusLabel $StatusLabel -PermissionLimited $PermissionLimited
}

function Get-ConnectedDevices {
    param([string]$AdbPath)

    $deviceOutput = & $AdbPath devices 2>&1
    $deviceList = [System.Collections.Generic.List[string]]::new()
    foreach ($deviceLine in $deviceOutput) {
        $deviceMatch = [regex]::Match([string]$deviceLine, '^(\S+)\s+device$')
        if ($deviceMatch.Success) {
            $deviceList.Add($deviceMatch.Groups[1].Value)
        }
    }
    return @($deviceList)
}

function Get-SeverityRank {
    param([string]$Severity)

    switch ($Severity) {
        'CRITICAL' { return 0 }
        'HIGH' { return 1 }
        'MEDIUM' { return 2 }
        'LOW' { return 3 }
        default { return 4 }
    }
}

function Add-Finding {
    param(
        [string]$Rule,
        [string]$Severity,
        [string]$Title,
        [string]$Source,
        [int]$LineNumber,
        [string]$Evidence,
        [string]$Meaning,
        [string]$RecommendedAction
    )

    $normalizedEvidence = ($Evidence -replace '\s+', ' ').Trim()
    # A single Android event is commonly duplicated in logcat, DropBox, and bugreport.
    $dedupeKey = "$Rule|$normalizedEvidence"
    if (-not $script:FindingKeys.Add($dedupeKey)) {
        return
    }

    $script:Findings.Add([pscustomobject]@{
        Rule              = $Rule
        Severity          = $Severity
        Title             = $Title
        Source            = $Source
        LineNumber        = $LineNumber
        Evidence          = $Evidence.Trim()
        Meaning           = $Meaning
        RecommendedAction = $RecommendedAction
    })
}

function Test-LineForFinding {
    param(
        [string]$Source,
        [int]$LineNumber,
        [string]$LogLine,
        [string]$CurrentProcess
    )

    $evidence = $LogLine.Trim()
    if ([string]::IsNullOrWhiteSpace($evidence)) {
        return
    }

    if ($evidence -match '(?i)Kernel panic - not syncing') {
        Add-Finding -Rule 'kernel-panic' -Severity 'CRITICAL' -Title 'Kernel panic detected' -Source $Source -LineNumber $LineNumber -Evidence $evidence -Meaning 'The entire device kernel stopped and rebooted. This is not an application-level crash.' -RecommendedAction 'Preserve this report, update or reflash the exact device firmware, and escalate the full last-kmsg/sysdump to the device vendor.'
    }

    if ($evidence -match '(?i)Internal error: Oops:|Unable to handle kernel') {
        Add-Finding -Rule 'kernel-oops' -Severity 'CRITICAL' -Title 'Kernel Oops detected' -Source $Source -LineNumber $LineNumber -Evidence $evidence -Meaning 'A kernel memory or driver fault occurred. It can directly cause a reboot or device instability.' -RecommendedAction 'Use the surrounding call trace to identify the vendor driver. Firmware repair is required before app-level debugging.'
    }

    if ($evidence -match '(?i)sprd-sysdump: reason:') {
        Add-Finding -Rule 'sprd-sysdump' -Severity 'CRITICAL' -Title 'Unisoc sysdump recorded' -Source $Source -LineNumber $LineNumber -Evidence $evidence -Meaning 'The Unisoc platform recorded a system-level fatal event.' -RecommendedAction 'Collect the vendor sysdump where available and provide it with the exact firmware build to the hardware vendor.'
    }

    if ($evidence -match '(?i)decompressed_size\s*==\s*image_size_|decompressed_size=.*image_size_') {
        Add-Finding -Rule 'art-image-mismatch' -Severity 'HIGH' -Title 'Android Runtime boot image mismatch' -Source $Source -LineNumber $LineNumber -Evidence $evidence -Meaning 'ART rejected a boot image because the expected and decompressed sizes differ. dex2oat and app_process can abort as a result.' -RecommendedAction 'Back up data. Reinstall the exact full firmware or perform a factory reset if the failure is limited to /data ART cache. Recheck after reboot.'
    }

    if ($evidence -match '(?i)Scudo ERROR: corrupted chunk header|Scudo ERROR:') {
        $processSuffix = if ($CurrentProcess) { " Process: $CurrentProcess." } else { '' }
        Add-Finding -Rule 'native-heap-corruption' -Severity 'HIGH' -Title 'Native heap corruption detected' -Source $Source -LineNumber $LineNumber -Evidence ($evidence + $processSuffix) -Meaning 'Scudo detected corrupted native heap metadata. This normally indicates a memory safety defect in native or vendor code.' -RecommendedAction 'Identify the owning native library from the tombstone backtrace. Update or replace the responsible vendor component.'
    }

    if ($evidence -match '(?i)Fatal signal\s+\d+') {
        $fatalProcess = [regex]::Match($evidence, 'in tid\s+\d+\s+\(([^)]+)\),\s+pid')
        $processName = if ($fatalProcess.Success) { $fatalProcess.Groups[1].Value } else { $CurrentProcess }
        $processSuffix = if ($processName) { " Process: $processName." } else { '' }
        Add-Finding -Rule 'native-fatal-signal' -Severity 'HIGH' -Title 'Native process crash detected' -Source $Source -LineNumber $LineNumber -Evidence ($evidence + $processSuffix) -Meaning 'A native process was terminated by a fatal signal. The corresponding tombstone is required for root cause analysis.' -RecommendedAction 'Preserve matching tombstones and correlate the signal with the process name and backtrace.'
    }

    if ($evidence -cmatch 'FATAL EXCEPTION' -or $evidence -cmatch 'AndroidRuntime:.*FATAL EXCEPTION') {
        Add-Finding -Rule 'java-fatal-exception' -Severity 'HIGH' -Title 'Java/Kotlin application crash detected' -Source $Source -LineNumber $LineNumber -Evidence $evidence -Meaning 'An Android Runtime exception terminated an application process.' -RecommendedAction 'Locate the following stack trace and fix the first application-owned frame.'
    }

    if ($evidence -match '(?i)ANR in\s+') {
        Add-Finding -Rule 'application-anr' -Severity 'HIGH' -Title 'Application not responding (ANR)' -Source $Source -LineNumber $LineNumber -Evidence $evidence -Meaning 'The system detected that an application did not respond in time.' -RecommendedAction 'Inspect the matching traces, main-thread state, binder waits, and CPU pressure at the same timestamp.'
    }

    if ($evidence -match '(?i)OutOfMemoryError|low memory killer|lmkd.*(kill|killed)') {
        Add-Finding -Rule 'memory-pressure' -Severity 'MEDIUM' -Title 'Memory pressure signal detected' -Source $Source -LineNumber $LineNumber -Evidence $evidence -Meaning 'The system reported an out-of-memory condition or low-memory process termination.' -RecommendedAction 'Check meminfo, process RSS, and background process policy around this timestamp.'
    }

    if ($evidence -match '(?i)\[drm\].*dpu.*time out|dpu wait for .* time out') {
        Add-Finding -Rule 'display-timeout' -Severity 'MEDIUM' -Title 'Display pipeline timeout detected' -Source $Source -LineNumber $LineNumber -Evidence $evidence -Meaning 'The display processing unit did not acknowledge an update within the expected interval.' -RecommendedAction 'Treat this as a firmware/driver signal. Correlate it with kernel Oops or display freezes before assigning causality.'
    }
}

function Scan-Reader {
    param(
        [string]$Source,
        [System.IO.StreamReader]$Reader
    )

    $script:SourcesScanned.Add($Source)
    $lineNumber = 0
    $currentProcess = ''
    while (-not $Reader.EndOfStream) {
        $logLine = $Reader.ReadLine()
        $lineNumber++

        $tombstoneProcess = [regex]::Match($logLine, 'pid:\s*\d+.*>>>\s*(.+?)\s*<<<')
        if ($tombstoneProcess.Success) {
            $currentProcess = $tombstoneProcess.Groups[1].Value.Trim()
        }

        $commandProcess = [regex]::Match($logLine, '^Cmd line:\s*(.+)$')
        if ($commandProcess.Success) {
            $currentProcess = $commandProcess.Groups[1].Value.Trim()
        }

        Test-LineForFinding -Source $Source -LineNumber $lineNumber -LogLine $logLine -CurrentProcess $currentProcess
    }
}

function Scan-TextFile {
    param([System.IO.FileInfo]$File)

    $reader = [System.IO.StreamReader]::new($File.FullName, $true)
    try {
        Scan-Reader -Source $File.FullName -Reader $reader
    } finally {
        $reader.Dispose()
    }
}

function Scan-BugreportArchive {
    param([System.IO.FileInfo]$ArchiveFile)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchiveFile.FullName)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notmatch '(?i)(^|/)(bugreport.*\.txt|dumpstate_log\.txt|tombstone[^/]*|last_kmsg[^/]*|console-ramoops[^/]*)$') {
                continue
            }
            if ($entry.Length -eq 0) {
                continue
            }

            $reader = [System.IO.StreamReader]::new($entry.Open(), $true)
            try {
                Scan-Reader -Source ($ArchiveFile.FullName + '!' + $entry.FullName) -Reader $reader
            } finally {
                $reader.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Analyze-LogPath {
    param([string]$Path)

    $resolvedItem = Get-Item -LiteralPath $Path
    $filesToScan = @()
    if ($resolvedItem.PSIsContainer) {
        $filesToScan = @(Get-ChildItem -LiteralPath $resolvedItem.FullName -File -Recurse)
    } else {
        $filesToScan = @($resolvedItem)
    }

    foreach ($candidateFile in $filesToScan) {
        if ($candidateFile.Name -in @('analysis-report.md', 'analysis-summary.txt', 'analysis.json')) {
            continue
        }

        if ($candidateFile.Extension -ieq '.zip' -and $candidateFile.Name -match '(?i)bugreport') {
            Scan-BugreportArchive -ArchiveFile $candidateFile
            continue
        }

        if ($candidateFile.Name -match '(?i)(tombstone|logcat|last_kmsg|ramoops)' -or $candidateFile.Extension -match '(?i)^\.(txt|log|kmsg)$') {
            Scan-TextFile -File $candidateFile
        }
    }
}

function New-AnalysisReport {
    param(
        [string]$AnalysisInput,
        [string]$ReportDirectory
    )

    $orderedFindings = @($script:Findings | Sort-Object @{ Expression = { Get-SeverityRank $_.Severity } }, Source, LineNumber)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'
    $criticalCount = @($orderedFindings | Where-Object Severity -eq 'CRITICAL').Count
    $highCount = @($orderedFindings | Where-Object Severity -eq 'HIGH').Count
    $mediumCount = @($orderedFindings | Where-Object Severity -eq 'MEDIUM').Count
    $findingGroups = @($orderedFindings | Group-Object Rule | ForEach-Object {
        $sample = $_.Group[0]
        [pscustomobject]@{
            Rule              = $sample.Rule
            Severity          = $sample.Severity
            Title             = $sample.Title
            Occurrences       = $_.Count
            Source            = $sample.Source
            LineNumber        = $sample.LineNumber
            Evidence          = $sample.Evidence
            Meaning           = $sample.Meaning
            RecommendedAction = $sample.RecommendedAction
        }
    } | Sort-Object @{ Expression = { Get-SeverityRank $_.Severity } }, Title)

    $markdown = [System.Collections.Generic.List[string]]::new()
    $markdown.Add('# Android Log Inspector report')
    $markdown.Add('')
    $markdown.Add("- Created: $timestamp")
    $markdown.Add('- Input: `' + $AnalysisInput + '`')
    $markdown.Add("- Sources scanned: $($script:SourcesScanned.Count)")
    $markdown.Add("- Findings: CRITICAL $criticalCount, HIGH $highCount, MEDIUM $mediumCount, total $($orderedFindings.Count)")
    $markdown.Add('')

    if ($orderedFindings.Count -eq 0) {
        $markdown.Add('No known crash, ANR, kernel panic, or memory-corruption signature was found in the scanned sources.')
    } else {
        $markdown.Add('## Issue groups')
        $markdown.Add('')
        foreach ($findingGroup in $findingGroups) {
            $markdown.Add("- **[$($findingGroup.Severity) x$($findingGroup.Occurrences)] $($findingGroup.Title)**")
            $markdown.Add("  - Meaning: $($findingGroup.Meaning)")
            $markdown.Add("  - Recommended action: $($findingGroup.RecommendedAction)")
        }
        $markdown.Add('')

        foreach ($severity in @('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')) {
            $severityFindings = @($orderedFindings | Where-Object Severity -eq $severity)
            if ($severityFindings.Count -eq 0) {
                continue
            }
            $markdown.Add("## $severity")
            $markdown.Add('')
            foreach ($finding in $severityFindings) {
                $safeEvidence = $finding.Evidence -replace '`', "'"
                $markdown.Add("### $($finding.Title)")
                $markdown.Add('- Source: `' + $finding.Source + ':' + $finding.LineNumber + '`')
                $markdown.Add('- Evidence: `' + $safeEvidence + '`')
                $markdown.Add("- Meaning: $($finding.Meaning)")
                $markdown.Add("- Recommended action: $($finding.RecommendedAction)")
                $markdown.Add('')
            }
        }
    }

    $summary = [System.Collections.Generic.List[string]]::new()
    $summary.Add('Android Log Inspector summary')
    $summary.Add("Input: $AnalysisInput")
    $summary.Add("Critical: $criticalCount | High: $highCount | Medium: $mediumCount | Total: $($orderedFindings.Count)")
    $summary.Add('')
    $summary.Add('Issue groups:')
    foreach ($findingGroup in $findingGroups) {
        $summary.Add("[$($findingGroup.Severity) x$($findingGroup.Occurrences)] $($findingGroup.Title)")
        $summary.Add("  $($findingGroup.Meaning)")
        $summary.Add("  First evidence: $($findingGroup.Source):$($findingGroup.LineNumber)")
    }

    $reportPath = Join-Path $ReportDirectory 'analysis-report.md'
    $summaryPath = Join-Path $ReportDirectory 'analysis-summary.txt'
    $jsonPath = Join-Path $ReportDirectory 'analysis.json'
    Write-Utf8File -Path $reportPath -Content (($markdown -join [Environment]::NewLine) + [Environment]::NewLine)
    Write-Utf8File -Path $summaryPath -Content (($summary -join [Environment]::NewLine) + [Environment]::NewLine)
    Write-Utf8File -Path $jsonPath -Content ($orderedFindings | ConvertTo-Json -Depth 5)
    return [pscustomobject]@{ ReportPath = $reportPath; SummaryPath = $summaryPath; JsonPath = $jsonPath; Findings = $orderedFindings }
}

function Collect-DeviceLogs {
    param(
        [string]$AdbPath,
        [string]$DeviceSerial,
        [string]$CollectionDirectory,
        [bool]$IncludeBugreport
    )

    $deviceArguments = @('-s', $DeviceSerial)
    New-Item -ItemType Directory -Force -Path $CollectionDirectory | Out-Null
    # Two preflight calls, thirteen capture specs, three pulls, optional bugreport, analysis, and report generation.
    $script:WorkCompleted = 0
    $script:WorkTotal = 20 + [int]$IncludeBugreport
    Write-WorkProgress -Message 'Preparing device collection'
    Invoke-AdbCapture -AdbPath $AdbPath -DeviceArguments @() -CommandArguments @('version') -Destination (Join-Path $CollectionDirectory 'adb_version.txt') -StatusLabel 'Checking bundled ADB version' | Out-Null
    Invoke-AdbCapture -AdbPath $AdbPath -DeviceArguments $deviceArguments -CommandArguments @('get-state') -Destination (Join-Path $CollectionDirectory 'device_state.txt') -StatusLabel 'Checking device authorization state' | Out-Null

    $captureSpecs = @(
        @{ Name = 'getprop.txt'; StatusLabel = 'Reading Android system properties'; CommandArguments = @('shell', 'getprop') },
        @{ Name = 'logcat_all_threadtime.txt'; StatusLabel = 'Exporting all logcat buffers'; CommandArguments = @('logcat', '-b', 'all', '-v', 'threadtime', '-d') },
        @{ Name = 'logcat_last_boot.txt'; StatusLabel = 'Exporting previous boot logcat buffers'; CommandArguments = @('logcat', '-L', '-b', 'all', '-v', 'threadtime', '-d') },
        @{ Name = 'logcat_crash.txt'; StatusLabel = 'Exporting crash logcat buffer'; CommandArguments = @('logcat', '-b', 'crash', '-v', 'threadtime', '-d') },
        @{ Name = 'dumpsys_dropbox.txt'; StatusLabel = 'Collecting DropBox crash records'; CommandArguments = @('shell', 'dumpsys', 'dropbox', '--print') },
        @{ Name = 'dumpsys_meminfo.txt'; StatusLabel = 'Collecting memory diagnostics'; CommandArguments = @('shell', 'dumpsys', 'meminfo') },
        @{ Name = 'dumpsys_cpuinfo.txt'; StatusLabel = 'Collecting CPU diagnostics'; CommandArguments = @('shell', 'dumpsys', 'cpuinfo') },
        @{ Name = 'dumpsys_activity.txt'; StatusLabel = 'Collecting activity process diagnostics'; CommandArguments = @('shell', 'dumpsys', 'activity', 'processes') },
        @{ Name = 'dumpsys_surfaceflinger.txt'; StatusLabel = 'Collecting display pipeline diagnostics'; CommandArguments = @('shell', 'dumpsys', 'SurfaceFlinger') },
        @{ Name = 'dmesg.txt'; StatusLabel = 'Collecting kernel messages'; PermissionLimited = $true; CommandArguments = @('shell', 'dmesg') },
        @{ Name = 'tombstones_listing.txt'; StatusLabel = 'Listing native crash tombstones'; PermissionLimited = $true; CommandArguments = @('shell', 'ls', '-la', '/data/tombstones') },
        @{ Name = 'anr_listing.txt'; StatusLabel = 'Listing ANR traces'; PermissionLimited = $true; CommandArguments = @('shell', 'ls', '-la', '/data/anr') },
        @{ Name = 'pstore_listing.txt'; StatusLabel = 'Listing persistent kernel logs'; PermissionLimited = $true; CommandArguments = @('shell', 'ls', '-la', '/sys/fs/pstore') }
    )

    foreach ($captureSpec in $captureSpecs) {
        $permissionLimited = $captureSpec.ContainsKey('PermissionLimited') -and [bool]$captureSpec.PermissionLimited
        Invoke-AdbCapture -AdbPath $AdbPath -DeviceArguments $deviceArguments -CommandArguments $captureSpec.CommandArguments -Destination (Join-Path $CollectionDirectory $captureSpec.Name) -StatusLabel $captureSpec.StatusLabel -PermissionLimited $permissionLimited | Out-Null
    }

    $pulledDirectory = Join-Path $CollectionDirectory 'pulled'
    Invoke-AdbPull -AdbPath $AdbPath -DeviceArguments $deviceArguments -RemotePath '/data/tombstones' -DestinationPath (Join-Path $pulledDirectory 'tombstones') -LogPath (Join-Path $CollectionDirectory 'pull_tombstones.txt') -StatusLabel 'Pulling native tombstones (permission may be denied)' -PermissionLimited $true | Out-Null
    Invoke-AdbPull -AdbPath $AdbPath -DeviceArguments $deviceArguments -RemotePath '/data/anr' -DestinationPath (Join-Path $pulledDirectory 'anr') -LogPath (Join-Path $CollectionDirectory 'pull_anr.txt') -StatusLabel 'Pulling ANR traces (permission may be denied)' -PermissionLimited $true | Out-Null
    Invoke-AdbPull -AdbPath $AdbPath -DeviceArguments $deviceArguments -RemotePath '/sys/fs/pstore' -DestinationPath (Join-Path $pulledDirectory 'pstore') -LogPath (Join-Path $CollectionDirectory 'pull_pstore.txt') -StatusLabel 'Pulling persistent kernel logs (permission may be denied)' -PermissionLimited $true | Out-Null

    if ($IncludeBugreport) {
        $bugreportDirectory = Join-Path $CollectionDirectory 'bugreport'
        New-Item -ItemType Directory -Force -Path $bugreportDirectory | Out-Null
        Invoke-AdbCapture -AdbPath $AdbPath -DeviceArguments $deviceArguments -CommandArguments @('bugreport', $bugreportDirectory) -Destination (Join-Path $CollectionDirectory 'bugreport_command.txt') -StatusLabel 'Collecting full bugreport (this can take several minutes)' | Out-Null
    }
}

try {
    $runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
        $toolBaseDirectory = $PSScriptRoot
    } else {
        $toolBaseDirectory = (Resolve-Path -LiteralPath $ToolRoot -ErrorAction Stop).Path
    }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path $toolBaseDirectory 'reports'
    }
    if (-not [System.IO.Path]::IsPathRooted($OutputRoot)) {
        $OutputRoot = Join-Path (Get-Location) $OutputRoot
    }
    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

    if ($InputPath) {
        $analysisName = Get-SafeName ((Get-Item -LiteralPath $InputPath).BaseName)
        $reportDirectory = Join-Path $OutputRoot ("analysis-$runStamp-$analysisName")
        $script:WorkCompleted = 0
        $script:WorkTotal = 2
        Write-WorkProgress -Message 'Preparing existing log analysis'
        Write-Status "Analyzing existing logs: $InputPath"
        Analyze-LogPath -Path $InputPath
        $script:WorkCompleted++
        Write-WorkProgress -Message 'Generating analysis report'
        $report = New-AnalysisReport -AnalysisInput $InputPath -ReportDirectory $reportDirectory
        $script:WorkCompleted++
        Write-WorkProgress -Message 'Analysis report ready'
        Write-Status "Report created: $($report.ReportPath)"
        Get-Content -LiteralPath $report.SummaryPath
        exit 0
    }

    $adbPath = Join-Path $toolBaseDirectory 'platform-tools\adb.exe'
    if (-not (Test-Path -LiteralPath $adbPath -PathType Leaf)) {
        throw "Bundled adb.exe not found: $adbPath"
    }

    $rootCollectionDirectory = Join-Path $OutputRoot ("collection-$runStamp")
    New-Item -ItemType Directory -Force -Path $rootCollectionDirectory | Out-Null
    Invoke-AdbCapture -AdbPath $adbPath -DeviceArguments @() -CommandArguments @('devices', '-l') -Destination (Join-Path $rootCollectionDirectory 'adb_devices_l.txt') -StatusLabel 'Checking connected Android devices' | Out-Null
    $connectedDevices = @(Get-ConnectedDevices -AdbPath $adbPath)
    if ($Serial) {
        if ($connectedDevices -notcontains $Serial) {
            throw "Requested serial '$Serial' is not connected or authorized. See adb_devices_l.txt."
        }
        $connectedDevices = @($Serial)
    }
    if ($connectedDevices.Count -eq 0) {
        throw 'No connected and authorized Android device. Enable USB debugging and accept the RSA authorization prompt.'
    }

    foreach ($deviceSerial in $connectedDevices) {
        $deviceDirectory = Join-Path $rootCollectionDirectory (Get-SafeName $deviceSerial)
        $script:CollectionSteps.Clear()
        Write-Status "Collecting logs from $deviceSerial"
        Collect-DeviceLogs -AdbPath $adbPath -DeviceSerial $deviceSerial -CollectionDirectory $deviceDirectory -IncludeBugreport (-not $SkipBugreport)
        Write-CollectionStatusReport -CollectionDirectory $deviceDirectory -DeviceSerial $deviceSerial

        $script:Findings.Clear()
        $script:FindingKeys.Clear()
        $script:SourcesScanned.Clear()
        Write-Status "Analyzing collected logs from $deviceSerial"
        Analyze-LogPath -Path $deviceDirectory
        $script:WorkCompleted++
        Write-WorkProgress -Message 'Generating analysis report'
        $reportDirectory = Join-Path $deviceDirectory 'analysis'
        $report = New-AnalysisReport -AnalysisInput $deviceDirectory -ReportDirectory $reportDirectory
        $script:WorkCompleted++
        Write-WorkProgress -Message 'Analysis report ready'
        Write-Status "Analysis complete for ${deviceSerial}: $($report.ReportPath)"
        Get-Content -LiteralPath $report.SummaryPath
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
