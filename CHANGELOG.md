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
- `BrainTrace.ps1 Test` for non-mutating end-to-end Worker/relay health and directional collection-access checks before Prepare or Collect.
- Explicitly confirmed `Test-Worker.ps1 -LiveStopStart` validation with real state verification and START recovery in `finally`; it never invokes CLEAN or collection.
- Manager-based `Deploy-BrainTrace.ps1` automation for updating a configured same-role DEV tier in one pass.
- Parameter-free DEV launcher and copy/paste command sheet for choosing the APP/WEB or TP deployment tier from the current server.
- Central read-only `BrainTrace.ps1 Diagnose` dashboard with configured node aliases, installation/task checks, queue counts, Worker heartbeats, and fatal startup errors.
- Relay-side diagnostic snapshots let the Controller inspect WEB Worker files, queues, heartbeats, and fatal errors without direct WEB access.
- Web1 operations portal with file-only Web1→App1→TP1 request relay and TP1→App1→Web1 result return for Diagnose, Test, Collect, and safely confirmed Prepare operations.
- Independent App1 relay and TP1 executor monitor tasks so global operations never block the Workers required to process node commands.

### Changed

- Standardized the BrainTrace installation, command, and staging root as `D:\FiservSoftware\PowerShell\BrainTrace`.
- Made `Worker.ps1` use its own script directory as its default operational root.
- Made Worker installation safe when the source repository and installation destination are the same directory.
- Excluded installed node configuration, queues, logs, staging, and generated ZIP files from Git when the repository doubles as the Worker directory.
- Organized repository runtime code under `src`, operational tooling under `scripts`, and operator notes under `docs`, while retaining the root deployment launcher and flat installed layout.
- Added live per-command wait, activity, elapsed-time, and result output so Controller operations no longer appear idle while Workers respond.
- Separated deployment management into TP1→TP, App1→APP, and Web1→WEB zones; cross-role Scheduler access is prohibited while explicitly requested same-role task installation is supported.

### Fixed

- Corrected the TP1 operations executor to use named parameter splatting, preventing `-Environment` from being treated as an invalid positional argument on Windows PowerShell 5.1.
- Replaced WEB and operations-relay administrative-share paths with consistent dedicated `FiservSoftware$` shares so the App1 and TP1 machine accounts can relay files without remote administrative access.
- Deferred `$PSScriptRoot`-based defaults until after parameter binding so Windows PowerShell 5.1 Scheduled Tasks can start Worker, monitor, portal, and smoke-test scripts instead of exiting with result code 1 before diagnostic logging begins.
- Persist fatal Worker startup/task-context errors to `Logs/Worker-Fatal.jsonl` so Scheduled Task failures can be diagnosed without an interactive session.
- Allowed an existing `NodeConfig.json` to be replaced during Worker reinstallation.
- Replaced the invalid Task Scheduler `TimeSpan.MaxValue` repetition duration with a finite ten-year duration accepted by task XML.
- Corrected UTC command-expiration and status-deadline comparisons on Windows PowerShell 5.1 in non-UTC local time zones.
- Made Controller-node installation include `BrainTrace.ps1` and the selected environment configuration instead of installing only Worker files.
- Corrected all DEV Mobiliti APP/WEB local and UNC log paths from `Program File` to the actual `Program Files` directory.

## Changelog maintenance

- Record user-visible behavior, configuration changes, safety changes, fixes, and operational requirements under `Unreleased` as they are introduced.
- Do not add entries for formatting-only or otherwise insignificant changes.
- Move `Unreleased` entries into a dated version section when a release is created.
