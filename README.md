# Android Log Inspector

Portable Windows tool that bundles ADB, collects Android diagnostics, and groups known crash signatures into an actionable report.

## Current Release

`0.3.5` targets Windows x64. It provides:

- A self-contained `AndroidLogInspector.exe`; no .NET or Android Studio installation is required.
- Determinate live progress with completed/total work steps for collection, analysis, and report generation.
- Korean collection progress and failure messages that distinguish missing, unauthorized, offline, and unavailable ADB devices.
- Immediate cancellation of collection when ADB device verification fails or the ADB transport disconnects during collection.
- Restartable collection from the launcher without reopening the EXE.
- Stage buttons for ADB connection, log collection, analysis, and report generation with pending, running, completed, and failed states.
- Live collected-data tracking so a disconnected device still leaves the failed stage, partial files, and status JSON visible.
- Collection of device properties, logcat, selected dumpsys output, permitted tombstones/ANR/pstore files, and an optional full bugreport.
- Deduplicated finding groups for kernel faults, ART boot-image mismatch, native heap corruption, native crashes, ANR, and display timeouts.
- Text, Markdown, and JSON analysis outputs.
- A post-analysis result dashboard with severity counts, priority action, grouped causes, evidence copying, and one-click access to collected and selected source logs.
- Collection-quality states that distinguish permission-limited data from an actual ADB collection failure.
- A support-bundle export containing reports and collection status without raw device logs or bugreports.

Keep `AndroidLogInspector.exe` and the adjacent `platform-tools` directory together when distributing a release.

## Build A Portable Release

1. Obtain the official Android SDK Platform-Tools for Windows.
2. Run the following from PowerShell:

```powershell
.\build\Build-Release.ps1 -PlatformToolsPath "C:\path\to\platform-tools"
```

The version is read from the single `<Version>` property in `src/AndroidLogInspectorLauncher/AndroidLogInspectorLauncher.csproj`. The generated ZIP is written under `artifacts`.

## Versioning And Release Process

1. Update `<Version>` in the launcher project using semantic versioning.
2. Add an entry to `CHANGELOG.md`.
3. Build and smoke-test the portable ZIP.
4. Commit the versioned changes, tag the commit as `vX.Y.Z`, then push `main` and the tag.

The launcher title and Windows executable metadata are produced from the same project version.

## UX Direction

The implemented result UX and future refinements are documented in [docs/UX-ROADMAP.md](docs/UX-ROADMAP.md).

## Third-Party Notices

Android Platform-Tools is distributed with the release package. See [docs/BUNDLED_ADB.md](docs/BUNDLED_ADB.md) and [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).
