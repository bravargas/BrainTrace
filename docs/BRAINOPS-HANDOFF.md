# BrainOps project handoff

Copy the prompt below into a new Codex conversation opened in the new BrainOps repository.

---

I want to create a new repository named **BrainOps**. Build it as a small, understandable Windows PowerShell 5.1 operations and update platform shared by these tools:

- BrainTrace
- BrainTools
- BrainPad
- future tools registered through configuration

Do not modify the BrainTrace repository during the initial BrainOps work unless I explicitly authorize it. The current BrainTrace repository is available for reference at:

`D:\users\Brainer\gitHub\BrainTrace`

## Existing network topology

Web1 must be the operator-facing operations hub because it can download and upload files to the internet. Cross-role communication is file-based only; do not assume WinRM, CIM, WMI, remote PowerShell, or cross-role Scheduler access.

The confirmed route is:

```text
Web1 request -> App1 relay -> TP1 executor
Web1 result  <- App1 relay <- TP1 executor
```

Connectivity constraints:

- TP1 can read and write the BrainTrace folders on APP servers.
- TP1 cannot see WEB servers.
- App1 can monitor and exchange files with Web1.
- Scheduled Task installation/management is allowed only within the same role/tier:
  - TP1 manages TP1 and TP2.
  - App1 manages App1 and App2.
  - Web1 manages Web1 and Web2.
- A dead agent or Scheduled Task cannot repair itself through dropped files; local recovery must remain possible through a one-click launcher.

Use configuration-driven physical server names and friendly aliases. Do not hardcode cleanup, installation, staging, or arbitrary command-supplied paths.

## BrainOps responsibilities

BrainOps should own the generic capabilities shared by all tools:

- Web1 operations portal.
- Atomic JSON request/result queues.
- Web1 -> App1 -> TP1 relay and reverse result flow.
- Tier-manager monitoring and heartbeats.
- Tool/version inventory.
- Release inbox on Web1.
- Package manifest validation.
- SHA-256 verification and optional Authenticode/provenance verification.
- Approval before deployment.
- Same-tier distribution through configured managers.
- Installed-version reporting.
- Rollback to the previous known-good version.
- Audit logs and visible progress in the UI.
- Expiration, deduplication, exact request IDs, and safe retry behavior.

BrainOps must not execute arbitrary PowerShell supplied by a request or package. A request may identify only an allow-listed `ToolId`, operation, version, and other schema-defined values. Trusted local configuration maps each `ToolId` to approved installation roots, tiers, files, entry points, and task definitions.

Each tool repository should publish a package and manifest. Start with a schema conceptually like:

```json
{
  "ToolId": "BrainTrace",
  "Version": "0.2.0",
  "MinimumBrainOpsVersion": "0.1.0",
  "Files": [
    {
      "Path": "Worker.ps1",
      "SHA256": "..."
    }
  ]
}
```

The package manifest must not control its final installation path or introduce unrestricted pre/post-install scripts. Those decisions belong to the trusted BrainOps tool catalog.

## Boundary with BrainTrace

BrainTrace remains responsible for its domain operations and safety rules:

- STOP, CLEAN, START, COLLECT, and BUNDLE.
- CLEAN must never begin unless every required STOP succeeds.
- Cleanup paths come only from trusted installed node configuration.
- DryRun publishes no commands and causes no physical effects.

BrainOps may transport or display BrainTrace requests and results, but it must not reimplement or weaken those rules.

BrainTrace currently contains a prototype worth inspecting:

- `src/Operations-Monitor.ps1`
- `src/Operations-Portal.ps1`
- `Operations-DEV.cmd`
- the `Operations` and `DeploymentManager` sections in `config/DEV.json`

Treat that code as prototype/reference. Design the generic boundary first instead of blindly copying BrainTrace-specific behavior.

Also note that BrainTrace recently fixed a Windows PowerShell 5.1 startup issue: do not use `$PSScriptRoot` to build dependent defaults inside `param(...)`. Assign `$Root = $PSScriptRoot` and derived paths after parameter binding.

## Initial BrainOps deliverable

First inspect the empty/new repository and the referenced BrainTrace prototype. Then propose and implement the smallest coherent MVP containing:

1. Repository structure and configuration model.
2. Tool catalog and package-manifest schema.
3. Atomic file relay with expiration and deduplication.
4. Web1 release import and SHA-256 verification.
5. Approval workflow.
6. Same-tier update planning and DryRun.
7. Version/status result return to Web1.
8. Previous-version rollback design and implementation where safely testable.
9. Pester tests on Windows PowerShell 5.1.
10. Operator documentation and one-click launchers.

Lead with a concise implementation plan. Keep the MVP configuration-driven, avoid credentials in files, preserve existing user changes, and do not perform real server deployment during development or tests.

---

Before starting BrainOps, create a BrainTrace checkpoint commit so its current Worker startup fix, Web1 relay prototype, deployment topology, documentation, and tests remain recoverable.
