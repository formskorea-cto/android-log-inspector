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

# The launcher reads redirected PowerShell output as UTF-8. Windows PowerShell
# otherwise uses the active console code page, which corrupts Korean log text.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$script:Findings = [System.Collections.Generic.List[object]]::new()
$script:FindingKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:SourcesScanned = [System.Collections.Generic.List[string]]::new()
$script:CollectionSteps = [System.Collections.Generic.List[object]]::new()
$script:WorkCompleted = 0
$script:WorkTotal = 0
$script:CurrentStage = ''
$script:CurrentStageDetail = ''
$script:RunDirectory = ''
$script:CurrentCollectionDirectory = ''

function Write-Status {
    param([string]$Message)
    Write-Host "[Android Log Inspector] $Message"
}

function ConvertTo-EventField {
    param([string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return (($Value -replace '[\r\n|]', ' ').Trim())
}

function Write-StageEvent {
    param(
        [ValidateSet('Running', 'Completed', 'Failed')]
        [string]$State,
        [string]$Stage,
        [string]$Message
    )

    if ($State -eq 'Running' -or $State -eq 'Failed') {
        $script:CurrentStage = $Stage
        $script:CurrentStageDetail = $Message
    }

    Write-Status ("Stage: {0}|{1}|{2}" -f $State, (ConvertTo-EventField $Stage), (ConvertTo-EventField $Message))
}

function Write-ArtifactEvent {
    param(
        [ValidateSet('Directory', 'File')]
        [string]$Kind,
        [string]$Status,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    Write-Status ("Artifact: {0}|{1}|{2}" -f $Kind, (ConvertTo-EventField $Status), (ConvertTo-EventField $Path))
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

function Get-RelativePathSafe {
    param(
        [string]$BasePath,
        [string]$Path
    )

    try {
        $resolvedBase = (Resolve-Path -LiteralPath $BasePath -ErrorAction Stop).Path.TrimEnd([char[]]'\/')
        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        $baseUri = [System.Uri]::new($resolvedBase + [System.IO.Path]::DirectorySeparatorChar)
        $pathUri = [System.Uri]::new($resolvedPath)
        return ([System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString())).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    } catch {
        return (Split-Path -Leaf $Path)
    }
}

function Get-CollectedFiles {
    param([string]$RootDirectory)

    if ([string]::IsNullOrWhiteSpace($RootDirectory) -or -not (Test-Path -LiteralPath $RootDirectory)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $RootDirectory -File -Recurse | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{
            RelativePath = Get-RelativePathSafe -BasePath $RootDirectory -Path $_.FullName
            SizeBytes    = $_.Length
            Modified     = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss K')
        }
    })
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
        [string]$DeviceSerial,
        [string]$OverallStatus = 'Completed',
        [string]$CurrentStage = $script:CurrentStage,
        [string]$FailureMessage = ''
    )

    $report = [pscustomobject]@{
        SchemaVersion = 2
        DeviceSerial  = $DeviceSerial
        Created       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')
        OverallStatus = $OverallStatus
        CurrentStage  = $CurrentStage
        CurrentStep   = $script:CurrentStageDetail
        FailureMessage = $FailureMessage
        CompletedWork = $script:WorkCompleted
        TotalWork     = $script:WorkTotal
        Steps         = @($script:CollectionSteps)
        CollectedFiles = @(Get-CollectedFiles -RootDirectory $CollectionDirectory)
    }
    Write-Utf8File -Path (Join-Path $CollectionDirectory 'collection-status.json') -Content ($report | ConvertTo-Json -Depth 5)
    Write-ArtifactEvent -Kind 'File' -Status '수집 상태' -Path (Join-Path $CollectionDirectory 'collection-status.json')
}

function Write-RunStatusReport {
    param(
        [string]$RunDirectory,
        [string]$OverallStatus,
        [string]$CurrentStage = $script:CurrentStage,
        [string]$FailureMessage = ''
    )

    if ([string]::IsNullOrWhiteSpace($RunDirectory) -or -not (Test-Path -LiteralPath $RunDirectory)) {
        return
    }

    $statusPath = Join-Path $RunDirectory 'run-status.json'
    $report = [pscustomobject]@{
        SchemaVersion = 1
        Created       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')
        OverallStatus = $OverallStatus
        CurrentStage  = $CurrentStage
        CurrentStep   = $script:CurrentStageDetail
        FailureMessage = $FailureMessage
        CollectedFiles = @(Get-CollectedFiles -RootDirectory $RunDirectory)
    }
    Write-Utf8File -Path $statusPath -Content ($report | ConvertTo-Json -Depth 5)
    Write-ArtifactEvent -Kind 'File' -Status '실행 상태' -Path $statusPath
}

function Invoke-AdbCapture {
    param(
        [string]$AdbPath,
        [string[]]$DeviceArguments,
        [string[]]$CommandArguments,
        [string]$Destination,
        [string]$StatusLabel,
        [bool]$PermissionLimited = $false,
        [bool]$RecordCollectionStep = $true
    )

    if ([string]::IsNullOrWhiteSpace($StatusLabel)) {
        $StatusLabel = $CommandArguments -join ' '
    }
    $script:CurrentStageDetail = $StatusLabel
    Write-Status "수집 시작: $StatusLabel"

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('### 실행 명령: ' + (Get-QuotedCommand -Executable $AdbPath -CommandArguments ($DeviceArguments + $CommandArguments)))
    $commandOutput = @()

    try {
        $commandOutput = & $AdbPath @DeviceArguments @CommandArguments 2>&1
        foreach ($outputItem in @($commandOutput)) {
            $lines.Add([string]$outputItem)
        }
        $exitCode = $LASTEXITCODE
    } catch {
        $lines.Add('PowerShell 오류: ' + $_.Exception.Message)
        $exitCode = -1
    }

    $lines.Add('exit_code=' + $exitCode)
    Write-Utf8File -Path $Destination -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    $artifactStatus = if ($exitCode -eq 0) {
        '수집 완료'
    } elseif ($PermissionLimited) {
        '권한 제한 로그'
    } else {
        '오류 로그'
    }
    Write-ArtifactEvent -Kind 'File' -Status $artifactStatus -Path $Destination
    if ($RecordCollectionStep) {
        $collectionStatus = if ($exitCode -eq 0) {
            'Collected'
        } elseif ($PermissionLimited) {
            'NotAvailable'
        } else {
            'Failed'
        }
        $collectionDetail = if ($exitCode -eq 0) {
            '수집 완료'
        } elseif ($PermissionLimited) {
            'Android 권한 또는 기기 정책으로 수집하지 못했습니다. 사용 가능한 로그만 계속 분석합니다.'
        } else {
            'ADB 명령이 정상 완료되지 않았습니다. 해당 명령 로그 파일을 확인하세요.'
        }
        $script:CollectionSteps.Add([pscustomobject]@{
            Status     = $collectionStatus
            Label      = $StatusLabel
            ExitCode   = $exitCode
            Detail     = $collectionDetail
            OutputFile = Split-Path -Leaf $Destination
        })
    }
    Write-Status "수집 완료: $StatusLabel (종료 코드 $exitCode)"
    if ($RecordCollectionStep -and $script:WorkTotal -gt 0) {
        $script:WorkCompleted++
        Write-WorkProgress -Message $StatusLabel
    }
    if (@($DeviceArguments).Count -gt 0 -and $exitCode -ne 0 -and (Test-AdbTransportFailure -Output $commandOutput)) {
        throw "ADB 연결이 끊겼거나 기기가 준비되지 않았습니다. '$StatusLabel' 단계에서 수집을 중단합니다. 상세 로그: $Destination"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($commandOutput | ForEach-Object { [string]$_ })
    }
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

function Test-AdbTransportFailure {
    param([object[]]$Output)

    $combinedOutput = (@($Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    return $combinedOutput -match '(?i)(device\s+(offline|unauthorized)|device .* not found|no devices?/emulators? found|no device|cannot connect|connection.*(closed|reset)|protocol fault|transport|more than one device)'
}

function Get-AdbStateDescription {
    param([string]$State)

    switch ($State) {
        'device' { return '사용 가능' }
        'unauthorized' { return 'USB 디버깅 인증 대기' }
        'offline' { return '오프라인' }
        'no permissions' { return 'PC ADB 권한 없음' }
        default { return "알 수 없는 상태($State)" }
    }
}

function Get-AdbDeviceInventory {
    param(
        [string]$AdbPath,
        [string]$Destination
    )

    Write-Status '연결된 Android 기기 상태를 확인하는 중'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('### 실행 명령: ' + (Get-QuotedCommand -Executable $AdbPath -CommandArguments @('devices', '-l')))
    $deviceOutput = @()
    try {
        $deviceOutput = & $AdbPath devices -l 2>&1
        foreach ($outputItem in @($deviceOutput)) {
            $lines.Add([string]$outputItem)
        }
        $exitCode = $LASTEXITCODE
    } catch {
        $lines.Add('PowerShell 오류: ' + $_.Exception.Message)
        $exitCode = -1
    }
    $lines.Add('exit_code=' + $exitCode)
    Write-Utf8File -Path $Destination -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    Write-ArtifactEvent -Kind 'File' -Status 'ADB 기기 목록' -Path $Destination
    if ($exitCode -ne 0) {
        throw "ADB 서버에 연결하지 못했습니다. USB 연결, Windows 드라이버, adb server 상태를 확인하세요. 상세 로그: $Destination"
    }

    $devices = [System.Collections.Generic.List[object]]::new()
    foreach ($deviceLine in @($deviceOutput)) {
        $line = ([string]$deviceLine).Trim()
        $deviceMatch = [regex]::Match($line, '^(?<serial>\S+)\s+(?<state>device|offline|unauthorized)(?:\s+(?<details>.*))?$')
        if (-not $deviceMatch.Success) {
            $deviceMatch = [regex]::Match($line, '^(?<serial>\S+)\s+(?<state>no permissions)(?:\s+(?<details>.*))?$')
        }
        if ($deviceMatch.Success) {
            $devices.Add([pscustomobject]@{
                Serial  = $deviceMatch.Groups['serial'].Value
                State   = $deviceMatch.Groups['state'].Value
                Details = $deviceMatch.Groups['details'].Value.Trim()
            })
        }
    }

    $summary = if ($devices.Count -eq 0) {
        '검색된 기기가 없습니다.'
    } else {
        ($devices | ForEach-Object { "$($_.Serial): $(Get-AdbStateDescription -State $_.State)" }) -join ', '
    }
    Write-Status "ADB 기기 상태: $summary"
    return [pscustomobject]@{ Devices = $devices.ToArray() }
}

function Assert-AdbDeviceReady {
    param(
        [string]$AdbPath,
        [string]$DeviceSerial,
        [string]$Destination
    )

    $result = Invoke-AdbCapture -AdbPath $AdbPath -DeviceArguments @('-s', $DeviceSerial) -CommandArguments @('get-state') -Destination $Destination -StatusLabel '기기 연결 및 USB 디버깅 인증 확인'
    $reportedState = (($result.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ').Trim()
    if ($result.ExitCode -ne 0 -or $reportedState -ne 'device') {
        throw "기기 '$DeviceSerial'이(가) 수집 준비 상태가 아닙니다. USB 디버깅 승인, 케이블 연결, 기기 상태를 확인하세요. 상세 로그: $Destination"
    }
}

function Test-AdbRuntime {
    param(
        [string]$AdbPath,
        [string]$Destination
    )

    $result = Invoke-AdbCapture -AdbPath $AdbPath -DeviceArguments @() -CommandArguments @('version') -Destination $Destination -StatusLabel '번들 ADB 실행 상태 확인' -RecordCollectionStep $false
    if ($result.ExitCode -ne 0) {
        throw "번들 ADB를 실행할 수 없습니다. 배포 파일을 다시 압축 해제하고 보안 프로그램 차단 여부를 확인하세요. 상세 로그: $Destination"
    }
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
    $script:CurrentCollectionDirectory = $CollectionDirectory
    Write-ArtifactEvent -Kind 'Directory' -Status '기기 수집 폴더' -Path $CollectionDirectory
    # One per-device connection check, thirteen capture specs, three pulls, optional bugreport, analysis, and report generation.
    $script:WorkCompleted = 0
    $script:WorkTotal = 19 + [int]$IncludeBugreport
    Write-WorkProgress -Message '기기 로그 수집 준비'

    try {
        Assert-AdbDeviceReady -AdbPath $AdbPath -DeviceSerial $DeviceSerial -Destination (Join-Path $CollectionDirectory 'device_state.txt')

        $captureSpecs = @(
            @{ Name = 'getprop.txt'; StatusLabel = 'Android 시스템 속성 읽기'; CommandArguments = @('shell', 'getprop') },
            @{ Name = 'logcat_all_threadtime.txt'; StatusLabel = '전체 logcat 버퍼 내보내기'; CommandArguments = @('logcat', '-b', 'all', '-v', 'threadtime', '-d') },
            @{ Name = 'logcat_last_boot.txt'; StatusLabel = '이전 부팅 logcat 버퍼 내보내기'; CommandArguments = @('logcat', '-L', '-b', 'all', '-v', 'threadtime', '-d') },
            @{ Name = 'logcat_crash.txt'; StatusLabel = '크래시 logcat 버퍼 내보내기'; CommandArguments = @('logcat', '-b', 'crash', '-v', 'threadtime', '-d') },
            @{ Name = 'dumpsys_dropbox.txt'; StatusLabel = 'DropBox 크래시 기록 수집'; CommandArguments = @('shell', 'dumpsys', 'dropbox', '--print') },
            @{ Name = 'dumpsys_meminfo.txt'; StatusLabel = '메모리 진단 정보 수집'; CommandArguments = @('shell', 'dumpsys', 'meminfo') },
            @{ Name = 'dumpsys_cpuinfo.txt'; StatusLabel = 'CPU 진단 정보 수집'; CommandArguments = @('shell', 'dumpsys', 'cpuinfo') },
            @{ Name = 'dumpsys_activity.txt'; StatusLabel = '앱 프로세스 진단 정보 수집'; CommandArguments = @('shell', 'dumpsys', 'activity', 'processes') },
            @{ Name = 'dumpsys_surfaceflinger.txt'; StatusLabel = '디스플레이 파이프라인 진단 정보 수집'; CommandArguments = @('shell', 'dumpsys', 'SurfaceFlinger') },
            @{ Name = 'dmesg.txt'; StatusLabel = '커널 메시지 수집'; PermissionLimited = $true; CommandArguments = @('shell', 'dmesg') },
            @{ Name = 'tombstones_listing.txt'; StatusLabel = '네이티브 크래시 tombstone 목록 수집'; PermissionLimited = $true; CommandArguments = @('shell', 'ls', '-la', '/data/tombstones') },
            @{ Name = 'anr_listing.txt'; StatusLabel = 'ANR trace 목록 수집'; PermissionLimited = $true; CommandArguments = @('shell', 'ls', '-la', '/data/anr') },
            @{ Name = 'pstore_listing.txt'; StatusLabel = '영구 커널 로그 목록 수집'; PermissionLimited = $true; CommandArguments = @('shell', 'ls', '-la', '/sys/fs/pstore') }
        )

        foreach ($captureSpec in $captureSpecs) {
            $permissionLimited = $captureSpec.ContainsKey('PermissionLimited') -and [bool]$captureSpec.PermissionLimited
            Invoke-AdbCapture -AdbPath $AdbPath -DeviceArguments $deviceArguments -CommandArguments $captureSpec.CommandArguments -Destination (Join-Path $CollectionDirectory $captureSpec.Name) -StatusLabel $captureSpec.StatusLabel -PermissionLimited $permissionLimited | Out-Null
        }

        $pulledDirectory = Join-Path $CollectionDirectory 'pulled'
        Invoke-AdbPull -AdbPath $AdbPath -DeviceArguments $deviceArguments -RemotePath '/data/tombstones' -DestinationPath (Join-Path $pulledDirectory 'tombstones') -LogPath (Join-Path $CollectionDirectory 'pull_tombstones.txt') -StatusLabel '네이티브 tombstone 가져오기 (권한 제한 가능)' -PermissionLimited $true | Out-Null
        Invoke-AdbPull -AdbPath $AdbPath -DeviceArguments $deviceArguments -RemotePath '/data/anr' -DestinationPath (Join-Path $pulledDirectory 'anr') -LogPath (Join-Path $CollectionDirectory 'pull_anr.txt') -StatusLabel 'ANR trace 가져오기 (권한 제한 가능)' -PermissionLimited $true | Out-Null
        Invoke-AdbPull -AdbPath $AdbPath -DeviceArguments $deviceArguments -RemotePath '/sys/fs/pstore' -DestinationPath (Join-Path $pulledDirectory 'pstore') -LogPath (Join-Path $CollectionDirectory 'pull_pstore.txt') -StatusLabel '영구 커널 로그 가져오기 (권한 제한 가능)' -PermissionLimited $true | Out-Null

        if ($IncludeBugreport) {
            $bugreportDirectory = Join-Path $CollectionDirectory 'bugreport'
            New-Item -ItemType Directory -Force -Path $bugreportDirectory | Out-Null
            Invoke-AdbCapture -AdbPath $AdbPath -DeviceArguments $deviceArguments -CommandArguments @('bugreport', $bugreportDirectory) -Destination (Join-Path $CollectionDirectory 'bugreport_command.txt') -StatusLabel '전체 bugreport 수집 (수 분 소요 가능)' | Out-Null
        }

        Write-CollectionStatusReport -CollectionDirectory $CollectionDirectory -DeviceSerial $DeviceSerial -OverallStatus 'Collected' -CurrentStage '로그 수집'
    } catch {
        Write-CollectionStatusReport -CollectionDirectory $CollectionDirectory -DeviceSerial $DeviceSerial -OverallStatus 'Interrupted' -CurrentStage $script:CurrentStage -FailureMessage $_.Exception.Message
        throw
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
        if (-not (Test-Path -LiteralPath $InputPath)) {
            throw "입력 로그 경로를 찾을 수 없습니다: $InputPath"
        }
        $analysisName = Get-SafeName ((Get-Item -LiteralPath $InputPath).BaseName)
        $reportDirectory = Join-Path $OutputRoot ("analysis-$runStamp-$analysisName")
        $script:WorkCompleted = 0
        $script:WorkTotal = 2
        Write-StageEvent -State 'Running' -Stage '로그 분석' -Message '기존 로그 분석 준비'
        Write-ArtifactEvent -Kind 'Directory' -Status '분석 결과 폴더' -Path $reportDirectory
        Write-WorkProgress -Message '기존 로그 분석 준비'
        Write-Status "기존 로그 분석 시작: $InputPath"
        Analyze-LogPath -Path $InputPath
        Write-StageEvent -State 'Completed' -Stage '로그 분석' -Message '기존 로그 분석 완료'
        $script:WorkCompleted++
        Write-StageEvent -State 'Running' -Stage '보고서 생성' -Message '분석 보고서 생성'
        Write-WorkProgress -Message '분석 보고서 생성'
        $report = New-AnalysisReport -AnalysisInput $InputPath -ReportDirectory $reportDirectory
        Write-ArtifactEvent -Kind 'File' -Status '분석 보고서' -Path $report.ReportPath
        Write-ArtifactEvent -Kind 'File' -Status '분석 요약' -Path $report.SummaryPath
        Write-ArtifactEvent -Kind 'File' -Status '분석 JSON' -Path $report.JsonPath
        $script:WorkCompleted++
        Write-StageEvent -State 'Completed' -Stage '보고서 생성' -Message '분석 보고서 생성 완료'
        Write-WorkProgress -Message '분석 보고서 생성 완료'
        Write-Status "보고서 생성 완료: $($report.ReportPath)"
        Get-Content -LiteralPath $report.SummaryPath -Encoding UTF8
        exit 0
    }

    $rootCollectionDirectory = Join-Path $OutputRoot ("collection-$runStamp")
    New-Item -ItemType Directory -Force -Path $rootCollectionDirectory | Out-Null
    $script:RunDirectory = $rootCollectionDirectory
    Write-ArtifactEvent -Kind 'Directory' -Status '수집 루트' -Path $rootCollectionDirectory
    Write-StageEvent -State 'Running' -Stage 'ADB 연결 확인' -Message '번들 ADB와 연결 기기 상태 확인'

    $adbPath = Join-Path $toolBaseDirectory 'platform-tools\adb.exe'
    if (-not (Test-Path -LiteralPath $adbPath -PathType Leaf)) {
        throw "번들 adb.exe를 찾을 수 없습니다. AndroidLogInspector.exe와 platform-tools 폴더가 같은 위치에 있어야 합니다: $adbPath"
    }

    Test-AdbRuntime -AdbPath $adbPath -Destination (Join-Path $rootCollectionDirectory 'adb_version.txt')
    $inventory = Get-AdbDeviceInventory -AdbPath $adbPath -Destination (Join-Path $rootCollectionDirectory 'adb_devices_l.txt')
    $availableDevices = @($inventory.Devices | Where-Object { $_.State -eq 'device' })
    $inventorySummary = if ($inventory.Devices.Count -eq 0) {
        '검색된 기기가 없습니다.'
    } else {
        ($inventory.Devices | ForEach-Object { "$($_.Serial): $(Get-AdbStateDescription -State $_.State)" }) -join ', '
    }
    if ($Serial) {
        $requestedDevice = @($inventory.Devices | Where-Object { $_.Serial -eq $Serial }) | Select-Object -First 1
        if ($null -eq $requestedDevice) {
            throw "요청한 기기 '$Serial'을(를) 찾을 수 없습니다. ADB 기기 상태: $inventorySummary 상세 로그: $(Join-Path $rootCollectionDirectory 'adb_devices_l.txt')"
        }
        if ($requestedDevice.State -ne 'device') {
            throw "요청한 기기 '$Serial'은(는) 수집 준비 상태가 아닙니다: $(Get-AdbStateDescription -State $requestedDevice.State). 기기에서 USB 디버깅을 승인하거나 케이블을 다시 연결하세요. 상세 로그: $(Join-Path $rootCollectionDirectory 'adb_devices_l.txt')"
        }
        $connectedDevices = @($requestedDevice.Serial)
    } else {
        $connectedDevices = @($availableDevices | ForEach-Object { $_.Serial })
    }
    if ($connectedDevices.Count -eq 0) {
        if ($inventory.Devices.Count -eq 0) {
            throw "연결된 Android 기기가 없습니다. USB 케이블을 연결하고 USB 디버깅을 켠 뒤 RSA 인증 팝업을 허용하세요. 상세 로그: $(Join-Path $rootCollectionDirectory 'adb_devices_l.txt')"
        }
        throw "연결된 기기가 수집 준비 상태가 아닙니다. ADB 기기 상태: $inventorySummary USB 디버깅 승인 또는 케이블 연결 상태를 확인하세요. 상세 로그: $(Join-Path $rootCollectionDirectory 'adb_devices_l.txt')"
    }
    Write-StageEvent -State 'Completed' -Stage 'ADB 연결 확인' -Message '수집 대상 기기 확인 완료'
    Write-Status "수집 대상 기기: $($connectedDevices -join ', ')"

    foreach ($deviceSerial in $connectedDevices) {
        $deviceDirectory = Join-Path $rootCollectionDirectory (Get-SafeName $deviceSerial)
        $script:CollectionSteps.Clear()
        Write-StageEvent -State 'Running' -Stage '로그 수집' -Message "$deviceSerial 기기 로그 수집 시작"
        Write-Status "$deviceSerial 기기 로그 수집 시작"
        Collect-DeviceLogs -AdbPath $adbPath -DeviceSerial $deviceSerial -CollectionDirectory $deviceDirectory -IncludeBugreport (-not $SkipBugreport)
        Write-StageEvent -State 'Completed' -Stage '로그 수집' -Message "$deviceSerial 기기 로그 수집 완료"

        $script:Findings.Clear()
        $script:FindingKeys.Clear()
        $script:SourcesScanned.Clear()
        Write-StageEvent -State 'Running' -Stage '로그 분석' -Message "$deviceSerial 수집 로그 분석 시작"
        Write-Status "$deviceSerial 수집 로그 분석 시작"
        Analyze-LogPath -Path $deviceDirectory
        Write-StageEvent -State 'Completed' -Stage '로그 분석' -Message "$deviceSerial 수집 로그 분석 완료"
        $script:WorkCompleted++
        Write-StageEvent -State 'Running' -Stage '보고서 생성' -Message "$deviceSerial 분석 보고서 생성"
        Write-WorkProgress -Message '분석 보고서 생성'
        $reportDirectory = Join-Path $deviceDirectory 'analysis'
        Write-ArtifactEvent -Kind 'Directory' -Status '분석 결과 폴더' -Path $reportDirectory
        $report = New-AnalysisReport -AnalysisInput $deviceDirectory -ReportDirectory $reportDirectory
        Write-ArtifactEvent -Kind 'File' -Status '분석 보고서' -Path $report.ReportPath
        Write-ArtifactEvent -Kind 'File' -Status '분석 요약' -Path $report.SummaryPath
        Write-ArtifactEvent -Kind 'File' -Status '분석 JSON' -Path $report.JsonPath
        $script:WorkCompleted++
        Write-StageEvent -State 'Completed' -Stage '보고서 생성' -Message "$deviceSerial 분석 보고서 생성 완료"
        Write-WorkProgress -Message '분석 보고서 생성 완료'
        Write-Status "보고서 생성 완료: $($report.ReportPath)"
        Write-Status "$deviceSerial 분석 완료"
        Get-Content -LiteralPath $report.SummaryPath -Encoding UTF8
    }
    Write-RunStatusReport -RunDirectory $rootCollectionDirectory -OverallStatus 'Completed' -CurrentStage '완료'
} catch {
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentStage)) {
        Write-StageEvent -State 'Failed' -Stage $script:CurrentStage -Message $_.Exception.Message
    }
    if (-not [string]::IsNullOrWhiteSpace($script:RunDirectory)) {
        Write-RunStatusReport -RunDirectory $script:RunDirectory -OverallStatus 'Failed' -CurrentStage $script:CurrentStage -FailureMessage $_.Exception.Message
    }
    Write-Status "작업 중단: $($_.Exception.Message)"
    exit 1
}
