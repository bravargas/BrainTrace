# BrainTrace

BrainTrace is a planned Windows PowerShell 5.1 orchestration tool for creating clean, correlated troubleshooting log bundles across configurable Windows Server environments.

It addresses a risky manual workflow: stop selected components, clear only approved application logs after every node is safely stopped, restore the environment, let an operator reproduce an issue, collect the new logs, and publish one traceable ZIP bundle.

> **Status: Phase 2 simulation and DryRun.** The protocol and orchestration core are executable, but every physical effect is simulated inside a repository-owned/test workspace. BrainTrace is not ready to operate against real servers: it does not stop Windows services or IIS, delete production logs, run production Robocopy, access remote nodes, or register Scheduled Tasks.

## Design summary

Topology is data, not code. An environment contains any number of physical nodes, explicit SMB routes, a controller, and a configurable aggregator and bundle destination. Each physical node owns:

- `Roles`: labels such as TP, APP, and WEB;
- `Components`: unique controllable resources such as a Windows service, IIS, or an IIS App Pool;
- `LogSources`: unique physical directories that may be cleaned and collected.

An APP+WEB All-in-One machine is therefore one node with two roles, one IIS component, one application service, and one shared log source. A future APP+WEB+TP node adds only the distinct physical components and log sources it actually has. Canonical path and component identity checks prevent duplicate work.

Commands are human-readable JSON files transported over configured SMB paths. A local Scheduled Task will eventually invoke a Worker that claims and processes those files. The Controller coordinates runs and enforces global phase barriers. Relays only forward along preconfigured command routes; they never execute command-supplied paths or code.

File collection uses a separate directional routing model. Each configured copy step identifies the node that executes Robocopy, its source, and its destination. The source owner, copy executor/Collector, and Aggregator may be three different physical nodes; command reachability never implies reverse SMB file access.

Before a run, Workers return a canonical inventory and SHA-256 `ConfigHash`. The immutable plan and every mutation phase bind to that exact hash. Phase-open/close fencing ensures that a timed-out command is reconciled before rollback can be considered complete. Version 1 accepts workflows only on one authoritative Controller and uses a simple Controller-local environment lock.

## Available Phase 2 workflows

- `Prepare -DryRun`: reports hashes, physical resources, ordering, command routes, collection executors, aggregation, destination, and timeouts without publishing commands.
- simulated `Prepare`: exercises INVENTORY, STATE, queues, relays, phase fencing, STOP/CLEAN/START barriers, reconciliation, and guarded simulated effects.
- `Collect -DryRun`: validates and reports the directional collection plan.
- simulated `Collect`: copies only repository-owned simulation fixtures and produces a bundle/compression plan without production Robocopy or a production archive.

Examples:

```powershell
.\BrainTrace.ps1 Prepare -Environment QA -DryRun
.\BrainTrace.ps1 Collect -Environment PDX_AIO -Name "LoginFailure" -DryRun
```

Supported built-in scenarios are `QA`, `PROD_6TP`, `PDX_AIO`, `FULL_AIO_SEPARATE_LOGS`, and `FULL_AIO_SHARED_LOGS`.

## Repository structure

```text
BrainTrace.ps1          Thin Phase 2 CLI
BrainTrace.psd1/.psm1   Windows PowerShell 5.1 module
src/                    Common, Controller, Worker, Relay, Collection,
                        Compression, and Simulation cores
config/                 Illustrative environment and node-local configuration
docs/Architecture.md    Architecture, safety model, workflows, and decisions
docs/Protocol.md        Filesystem command/status protocol
docs/Phase2.5-Audit.md  Implementation traceability, findings, and residual risks
docs/BrainTrace_...md   Original architecture prompt
tests/Unit/             Pester unit and safety-invariant tests
tests/Simulation/       End-to-end simulation tests
tests/simulation/       Named scenario catalog
scripts/Invoke-Tests.ps1 Test entry point
AGENTS.md               Persistent engineering and safety rules
```

## Next phase

Review Phase 2 behavior and evidence before Phase 3. Production Windows/IIS/service, SMB, Robocopy, compression, and deployment adapters remain intentionally absent and require explicit approval.

Run all tests with:

```powershell
.\scripts\Invoke-Tests.ps1
```
