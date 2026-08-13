# BrainTrace repository rules

## Scope and language

- The project name is **BrainTrace**.
- Technical documentation, code comments, identifiers, test descriptions, configuration keys, and code-related artifacts must be written in English.
- Target Windows PowerShell 5.1 unless a documented decision explicitly requires another runtime.
- Keep changes inside this repository. Never probe or modify real infrastructure during development unless the user explicitly authorizes a reviewed production phase.

## Architecture invariants

- Never assume a fixed number of TP, APP, WEB, AIO, or other nodes.
- A node represents one physical Windows machine and may have multiple logical roles. Never create fake nodes for roles on the same machine.
- Roles are classification metadata. Execution is driven by node-local `Components` and `LogSources`.
- Component identity must be unique per physical node. Node-level resources such as IIS must be operated at most once per action, regardless of role count.
- Log sources belong to physical nodes. Canonically equivalent paths must be cleaned and collected at most once per action.
- Connectivity, explicit routes, controller, aggregator, destinations, component ordering, paths, timeouts, and providers must be configuration-driven.
- Model command/message routes separately from directional collection copy routes. Every file-copy step must identify the physical node that executes it; never infer reverse SMB access.
- Do not make WinRM, PowerShell Remoting, CredSSP, Kerberos delegation, or a database required dependencies.
- Keep orchestration, filesystem transport, and Windows-specific system operations behind separate interfaces so tests can replace them with simulation adapters.

## Safety and security

- Treat command JSON as untrusted data, never executable code. Use a strict action allow-list.
- Never use `Invoke-Expression` or implement arbitrary remote command execution.
- Never store credentials, secrets, tokens, or production identities in the repository or operational logs.
- Destructive actions may use only node-local, preconfigured resources. A command must never supply a cleanup path or arbitrary destination.
- Reject drive roots, share roots, paths outside allowed roots, wildcards, unresolved paths, unexpected reparse points, and unsafe canonical aliases before cleanup.
- Maintain `DryRun` and local simulation support through every implementation phase.
- Do not implement or enable real service, IIS, App Pool, log deletion, remote access, or Scheduled Task behavior until its architecture, tests, and explicit production authorization exist.
- `CLEAN` is irreversible. Never claim that Prepare is transactional or that deleted logs can be rolled back.

## Reliability and observability

- Preserve and validate `EnvironmentId`, `RunId`, and `CommandId` correlation end to end.
- Bind every run and mutation phase to each Worker's deterministic canonical SHA-256 `ConfigHash`; a human-readable revision alone is insufficient.
- A Controller timeout does not cancel a mutation. Close and reconcile the phase on every possible recipient before declaring rollback or opening an incompatible phase.
- Never automatically replay a CLEAN command with an uncertain execution outcome.
- Publish commands and statuses atomically and claim commands with an atomic same-volume move.
- Detect duplicate `CommandId` values before executing an action; a duplicate must return the stored terminal result.
- Enforce the global STOP and CLEAN barriers. Never clean after an incomplete STOP barrier.
- Version 1 has one authoritative ControllerNode and uses a Controller-local environment lock. Do not introduce multi-controller/distributed locking without an approved architecture change.
- Capture component state before mutation and restore only state changed by the current run when rollback is possible.
- Bound every wait and retry. Do not busy-loop or silently ignore errors.
- Keep failed-run evidence and write structured operational logs separately from application logs.

## Development standards

- Prefer small PowerShell modules and functions over monolithic scripts or unnecessary class hierarchies.
- Use `Set-StrictMode`, explicit parameter validation, `try`/`catch`/`finally`, meaningful exit codes, and deterministic behavior.
- Validate all configuration before starting a mutating workflow.
- Use Pester tests that do not require IIS, Windows services, production paths, or network access.
- Preserve Windows PowerShell 5.1 and JSON compatibility. Do not rely on PowerShell 7-only syntax or APIs without an approved design change.
- Prefer Windows-native, replaceable dependencies and document their exact exit-code semantics.
