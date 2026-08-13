# Changelog

All notable changes to BrainTrace are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). BrainTrace uses semantic versioning when releases are tagged.

## [Unreleased]

### Added

- Small Windows PowerShell 5.1 BrainTrace MVP with `Prepare`, `Collect`, and `DryRun` workflows.
- Real six-node DEV configuration using `vscorappdev01` as Controller and `vsmobappdev03` as relay, collector, and Aggregator for the WEB tier.
- Worker actions for STOP, CLEAN, START, COLLECT, and BUNDLE using trusted installed configuration.
- One-hop command relay, directional collection planning, Robocopy result handling, ZIP creation, and optional Scheduled Task installation.
- Critical Pester coverage for configuration, DryRun safety, STOP-to-CLEAN policy, installer re-execution, and Scheduled Task trigger formatting.
- `Test-Worker.ps1` for a one-command, isolated local Worker smoke test that verifies DryRun state preservation and queue/status/archive behavior.

### Changed

- Standardized the BrainTrace installation, command, and staging root as `D:\FiservSoftware\PowerShell\BrainTrace`.
- Made `Worker.ps1` use its own script directory as its default operational root.
- Made Worker installation safe when the source repository and installation destination are the same directory.
- Excluded installed node configuration, queues, logs, staging, and generated ZIP files from Git when the repository doubles as the Worker directory.

### Fixed

- Allowed an existing `NodeConfig.json` to be replaced during Worker reinstallation.
- Replaced the invalid Task Scheduler `TimeSpan.MaxValue` repetition duration with a finite ten-year duration accepted by task XML.
- Corrected UTC command-expiration and status-deadline comparisons on Windows PowerShell 5.1 in non-UTC local time zones.

## Changelog maintenance

- Record user-visible behavior, configuration changes, safety changes, fixes, and operational requirements under `Unreleased` as they are introduced.
- Do not add entries for formatting-only or otherwise insignificant changes.
- Move `Unreleased` entries into a dated version section when a release is created.
