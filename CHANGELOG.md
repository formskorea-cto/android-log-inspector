# Changelog

All notable changes are recorded here. Versions follow semantic versioning.

## 0.3.5 - 2026-07-13

- Fixed Korean text corruption in the launcher progress log when it runs Windows PowerShell.
- Read UTF-8 analysis summaries explicitly before adding them to the progress log.

## 0.3.4 - 2026-07-10

- Added a restart button so collection and analysis can be run again from the same launcher window.
- Added stage status buttons for ADB connection, log collection, log analysis, and report generation.
- Added live collected-data tracking and partial status reports so disconnect failures show the failed stage and files collected so far.

## 0.3.3 - 2026-07-10

- Stopped collection before capture when bundled ADB, device discovery, or per-device authorization checks fail.
- Stopped the active device collection when an ADB transport disconnect is detected during a capture step.
- Localized the collection progress, failure messages, and launcher controls to Korean while retaining raw ADB output in command logs.

## 0.3.2 - 2026-07-10

- Added buttons to open the collected-log folder, the selected finding source, and the selected collection-step log.

## 0.3.1 - 2026-07-10

- Replaced the indeterminate collection marquee with completed/total task progress.
- Included analysis and report generation in the displayed work total.

## 0.3.0 - 2026-07-10

- Added a result dashboard with decision status, severity totals, cause groups, evidence copying, and source-file navigation.
- Added `collection-status.json` to distinguish collected, permission-limited, and failed ADB data sources.
- Added collection-quality results in the desktop UI.
- Added privacy-preserving support-bundle export that excludes raw logs and bugreports.

## 0.1.0 - 2026-07-10

- Added a self-contained Windows x64 EXE launcher with bundled ADB support.
- Added live collection progress, completion status, and cancellation controls.
- Added grouped crash analysis with Markdown, text, and JSON reports.
- Added reproducible versioned portable-release build tooling.
