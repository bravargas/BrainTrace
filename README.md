# BrainTrace MVP

BrainTrace is a small Windows PowerShell 5.1 tool for preparing a troubleshooting environment and collecting its logs. It uses JSON files over SMB and supports direct command access or one explicit relay hop.

Notable changes are maintained in [`CHANGELOG.md`](CHANGELOG.md).

The initial real configuration is [`config/DEV.json`](config/DEV.json). It contains the supplied DEV nodes, Mobiliti service name, IIS flag, StandardBankingService App Pool, local cleanup paths, remote UNC collection paths, Controller, relay/collector, and Aggregator. The final ZIP destination is intentionally `null` because no real destination was provided.

## Safety model

- `Prepare` performs STOP on every configured physical node and waits for every result.
- CLEAN is never sent if any STOP fails or times out. START is attempted on all nodes instead.
- Worker commands contain no cleanup, service, App Pool, or arbitrary destination path.
- CLEAN uses only `LocalPath` from the trusted installed `NodeConfig.json`, never UNC, and deletes contents rather than the configured directory.
- Remote collection uses only the configured `UNCPath`; a collector resolves it from trusted configuration.
- `-DryRun` does not publish commands, touch services/IIS/App Pools/logs, invoke Robocopy, or create a ZIP.

The selected IIS method stops/starts the Windows `W3SVC` service through the isolated `Stop-BrainTraceIIS` and `Start-BrainTraceIIS` functions. Review this operational choice before the first non-DryRun use; it affects IIS web service scope on that physical server. App Pools use the Windows PowerShell 5.1 `WebAdministration` module.

## DEV DryRun

Run from the repository root on any workstation; it does not contact DEV:

```powershell
.\src\BrainTrace.ps1 Prepare -Environment DEV -DryRun
.\src\BrainTrace.ps1 Collect -Environment DEV -Name "Test" -DryRun
```

After every Worker is installed, run the non-mutating end-to-end preflight from the Controller:

```powershell
.\BrainTrace.ps1 Test -Environment DEV
```

`Test` publishes only `PING` and `CHECK_COLLECTION` commands. It verifies direct and one-hop Worker delivery plus source/staging reachability from each configured collector. It does not stop/start components, clean logs, invoke Robocopy, or create a ZIP.

For a read-only central dashboard that does not depend on Workers processing commands, run from the installed Controller:

```powershell
.\BrainTrace.ps1 Diagnose -Environment DEV
```

`Diagnose` shows the friendly DEV node alias, installed-file access, Scheduled Task state, last visible result, Worker heartbeat age, queued command count, and the latest fatal startup error. It does not publish commands or change tasks.

On TP1, the installed `Diagnose-DEV.cmd` launcher opens the same dashboard with no parameters and pauses so the results remain visible.

## Laptop LocalLab

`LocalLab.cmd` creates a six-node BrainTrace simulation entirely inside the repository's ignored `LocalLab` directory. It runs the real Worker, one-hop WEB relay, operations monitors, Controller CLI, and Web1 portal against isolated local folders. It does not create Scheduled Tasks, shares, services, App Pools, or IIS changes and does not contact DEV.

Double-click `LocalLab.cmd`, then use the menu:

```text
1  Initialize or reset the six-node lab
2  Diagnose simulated environment
3  Test Workers, relay, and collection access
4  Open Web1 Operations portal
5  Preview Prepare (DryRun)
6  Open LocalLab folder
```

Initialize once, then option 3 performs the fastest full health test. Option 4 exercises the same file-only `Web1 -> App1 -> TP1 -> App1 -> Web1` route used in DEV, normally completing in a few seconds. The portal can also test local-only collection and Prepare behavior; every configured log path remains under `LocalLab`.

The actions can also run without the menu:

```powershell
.\scripts\LocalLab.ps1 -Action Initialize
.\scripts\LocalLab.ps1 -Action Diagnose
.\scripts\LocalLab.ps1 -Action Test
.\scripts\LocalLab.ps1 -Action Portal
```

Reinitializing removes only the fixed repository `LocalLab` directory and recreates sample data. The simulation validates orchestration and file behavior but cannot prove domain machine-account, SMB, firewall, or real Task Scheduler permissions; those still require a short DEV smoke test.

## Web1 operations center

Web1 is the operator-facing hub while TP1 remains the safety-enforcing execution Controller. Cross-tier communication is file-only:

```text
Web1 request -> App1 relay -> TP1 executor
Web1 result  <- App1 relay <- TP1 executor
```

Run `Operations-DEV.cmd` locally on Web1 to open the menu for Diagnose, Test, Collect, Prepare DryRun, or explicitly confirmed live Prepare. Requests contain only allow-listed high-level operations, names, expiration, and confirmation fields; they cannot supply scripts, cleanup paths, or arbitrary destinations. App1 and TP1 use the separate `BrainTrace-Operations-Monitor` task to relay and execute requests. The ordinary `BrainTrace-Worker` task remains independent so TP1 can wait for Worker results without deadlocking itself.

Live Prepare still executes through `BrainTrace.ps1`, so CLEAN cannot be published unless every required STOP succeeds. A monitor or Worker that is not running cannot consume file requests and still requires local recovery.

The Prepare report lists all six real DEV servers, roles, components, local log paths, command access, collectors, and ordering. The Collect report names the executor, read endpoint, and write endpoint for every source. It shows the ZIP on `vsmobappdev03` and reports that final destination is not configured.

## Worker installation

Run locally on each server from a reviewed copy of this repository. For example:

```powershell
.\scripts\Install-Worker.ps1 -Environment DEV -Node vscorappdev01
.\scripts\Install-Worker.ps1 -Environment DEV -Node vsmobappdev03 -CreateScheduledTask
```

Use the physical server name corresponding to each installation. The default installs under `D:\FiservSoftware\PowerShell\BrainTrace`. `-WhatIf` previews installation. The optional task defaults to `SYSTEM`; use `-TaskUser` only with an already provisioned service identity. The installer never asks for or stores credentials.

### Faster DEV deployment

DEV installation and update uses three configured same-role management zones: TP1 manages TP1/TP2, App1 manages App1/App2, and Web1 manages Web1/Web2. Make the extracted release available to each manager, then run the launcher on those three servers.

For normal file updates, open Windows PowerShell as Administrator and run `.\Deploy-DEV.cmd`. For initial installation or explicit task recreation, run `.\Install-DEV.cmd`. Each launcher detects TP1, App1, or Web1, previews only that manager's tier, and requires `Y` to proceed. Exact commands are included in `docs\DEPLOY-DEV-COMMANDS.txt`.

The underlying manager-based commands are also available when explicit automation is preferred:

```powershell
.\scripts\Deploy-BrainTrace.ps1 -Environment DEV -Manager $env:COMPUTERNAME -WhatIf
.\scripts\Deploy-BrainTrace.ps1 -Environment DEV -Manager $env:COMPUTERNAME
```

Task creation is explicit and limited to the same configured tier:

```powershell
.\scripts\Deploy-BrainTrace.ps1 -Environment DEV -Manager $env:COMPUTERNAME -CreateScheduledTasks -WhatIf
.\scripts\Deploy-BrainTrace.ps1 -Environment DEV -Manager $env:COMPUTERNAME -CreateScheduledTasks
```

The deployment selection comes from each node's `DeploymentManager`. Cross-role deployment and Scheduler access are rejected by configuration validation. Normal updates remain file-only; `-CreateScheduledTasks` permits Scheduler creation only from TP1 to its TP tier, App1 to its APP tier, or Web1 to its WEB tier. A `-WhatIf` pass performs no operation.

Manual Worker execution:

```powershell
D:\FiservSoftware\PowerShell\BrainTrace\Worker.ps1
```

Safe local Worker smoke test (always invokes the isolated Worker with `-DryRun`):

```powershell
cd D:\FiservSoftware\PowerShell\BrainTrace
.\Test-Worker.ps1
```

The test creates a temporary queue, exercises the node's configured STOP plan without effects, verifies component state before/after, checks status/archive behavior, reports the Scheduled Task state, and removes its temporary files.

An explicitly confirmed live STOP/START test is also available during an approved outage window:

```powershell
.\Test-Worker.ps1 -LiveStopStart
```

This causes a real interruption. It verifies the stopped state and always issues START from `finally`. It never runs CLEAN or collection.

## Real workflows

After all Workers, shares, ACLs, and Scheduled Tasks are reviewed and installed:

```powershell
.\BrainTrace.ps1 Prepare -Environment DEV
.\BrainTrace.ps1 Collect -Environment DEV -Name "LoginFailure"
```

Do not run these non-DryRun commands until the operational prerequisites below are confirmed.

## Values still requiring owner confirmation

- final ZIP destination (`BundleDestination` is currently `null`);
- whether stopping/starting W3SVC is the approved DEV IIS behavior;
- STOP/START ordering in DEV;
- SMB and administrative-share permissions for Controller, relay/collector, and Aggregator identities;
- Scheduled Task identity on each server;
- whether `D:\FiservSoftware\PowerShell\BrainTrace` is deployed and reachable as represented by each `CommandRoot`;
- acceptable timeout and one-minute Worker polling interval.

## MVP limitations

One authoritative Controller, at most one relay hop, no automatic failover/discovery, no distributed cancellation, and manual intervention after unusual timeouts. `Compress-Archive` is used on the Aggregator. Robocopy treats exit codes 0–7 as nonfatal and 8+ as failure. This implementation deliberately favors understandable scripts over a general orchestration framework.

## Tests

Critical tests cover configuration, AIO deduplication, duplicate logs, STOP failure preventing CLEAN, DryRun no-write behavior, and Robocopy exit codes:

```powershell
Invoke-Pester .\tests
```
