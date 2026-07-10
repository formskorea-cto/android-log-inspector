# Android Log Inspector

Portable Windows tool that bundles ADB, collects Android diagnostics, and groups known crash signatures into an actionable report.

## Current Release

`0.1.0` targets Windows x64. It provides:

- A self-contained `AndroidLogInspector.exe`; no .NET or Android Studio installation is required.
- Live collection progress with start/completion status for each ADB step.
- Collection of device properties, logcat, selected dumpsys output, permitted tombstones/ANR/pstore files, and an optional full bugreport.
- Deduplicated finding groups for kernel faults, ART boot-image mismatch, native heap corruption, native crashes, ANR, and display timeouts.
- Text, Markdown, and JSON analysis outputs.

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

The result UX roadmap is in [docs/UX-ROADMAP.md](docs/UX-ROADMAP.md). The next product iteration should make the post-analysis result easier to scan before adding additional detection rules.

## Third-Party Notices

Android Platform-Tools is distributed with the release package. See [docs/BUNDLED_ADB.md](docs/BUNDLED_ADB.md) and [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).
