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

The Prepare report lists all six real DEV servers, roles, components, local log paths, command access, collectors, and ordering. The Collect report names the executor, read endpoint, and write endpoint for every source. It shows the ZIP on `vsmobappdev03` and reports that final destination is not configured.

## Worker installation

Run locally on each server from a reviewed copy of this repository. For example:

```powershell
.\scripts\Install-Worker.ps1 -Environment DEV -Node vscorappdev01
.\scripts\Install-Worker.ps1 -Environment DEV -Node vsmobappdev03 -CreateScheduledTask
```

Use the physical server name corresponding to each installation. The default installs under `D:\FiservSoftware\PowerShell\BrainTrace`. `-WhatIf` previews installation. The optional task defaults to `SYSTEM`; use `-TaskUser` only with an already provisioned service identity. The installer never asks for or stores credentials.

### Faster DEV deployment

Download, unblock, and extract the release only once on App1. From that source folder, install or update the APP and WEB tier in one pass:

For the shortest interactive workflow, open Windows PowerShell as Administrator and run `.\Deploy-DEV.cmd`. The same launcher detects App1 or TP1, previews the affected tier, and requires only `Y` to proceed. Exact copy/paste commands are included in `docs\DEPLOY-DEV-COMMANDS.txt`.

The underlying role-based commands are also available when explicit automation is preferred:

```powershell
.\scripts\Deploy-BrainTrace.ps1 -Environment DEV -Role APP,WEB -WhatIf
.\scripts\Deploy-BrainTrace.ps1 -Environment DEV -Role APP,WEB
```

Then sign in to TP1 and invoke the same script from the App1 source share to update both TP nodes:

```powershell
& '\\vsmobappdev03\d$\FiservSoftware\PowerShell\BrainTrace-approach-two\scripts\Deploy-BrainTrace.ps1' -Environment DEV -Role TP -WhatIf
& '\\vsmobappdev03\d$\FiservSoftware\PowerShell\BrainTrace-approach-two\scripts\Deploy-BrainTrace.ps1' -Environment DEV -Role TP
```

The deployment selection comes from the environment configuration. It copies the current Worker files, refreshes each trusted `NodeConfig.json`, and creates or replaces the one-minute `BrainTrace-Worker` task as `SYSTEM`. Remote deployment requires administrative-share and remote Task Scheduler access from the account running the command. A `-WhatIf` pass performs neither operation.

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
