[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PlatformToolsPath,
    [ValidateSet('win-x64')]
    [string]$Runtime = 'win-x64',
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot 'src\AndroidLogInspectorLauncher\AndroidLogInspectorLauncher.csproj'
$platformToolsPath = (Resolve-Path -LiteralPath $PlatformToolsPath -ErrorAction Stop).Path
$adbPath = Join-Path $platformToolsPath 'adb.exe'
if (-not (Test-Path -LiteralPath $adbPath -PathType Leaf)) {
    throw "adb.exe was not found in PlatformToolsPath: $platformToolsPath"
}

[xml]$projectXml = Get-Content -LiteralPath $projectPath -Raw
$version = [string]$projectXml.Project.PropertyGroup.Version
if ([string]::IsNullOrWhiteSpace($version)) {
    throw 'The launcher project does not define a Version property.'
}

$artifactsRoot = Join-Path $repositoryRoot 'artifacts'
$releaseName = "AndroidLogInspectorPortable-$version-$Runtime"
$releaseRoot = Join-Path $artifactsRoot $releaseName
$publishRoot = Join-Path $releaseRoot 'publish'
$packageRoot = Join-Path $releaseRoot 'AndroidLogInspectorPortable'
$zipPath = Join-Path $artifactsRoot "$releaseName.zip"

if (Test-Path -LiteralPath $releaseRoot) {
    Remove-Item -LiteralPath $releaseRoot -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
& dotnet publish $projectPath -c $Configuration -r $Runtime --self-contained true -o $publishRoot
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $publishRoot 'AndroidLogInspector.exe') -Destination (Join-Path $packageRoot 'AndroidLogInspector.exe') -ErrorAction Stop
Copy-Item -LiteralPath $platformToolsPath -Destination (Join-Path $packageRoot 'platform-tools') -Recurse -ErrorAction Stop
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'README.md') -Destination (Join-Path $packageRoot 'README.md') -ErrorAction Stop
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'docs\BUNDLED_ADB.md') -Destination (Join-Path $packageRoot 'BUNDLED_ADB.md') -ErrorAction Stop
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'docs\THIRD_PARTY_NOTICES.md') -Destination (Join-Path $packageRoot 'THIRD_PARTY_NOTICES.md') -ErrorAction Stop

Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal
Get-Item -LiteralPath $zipPath | Select-Object FullName, Length, LastWriteTime
