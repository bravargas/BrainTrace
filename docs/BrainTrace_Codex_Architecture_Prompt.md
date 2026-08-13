# BrainTrace — Initial Codex Architecture Prompt

## Project name

**BrainTrace**

BrainTrace is a PowerShell-based Windows Server troubleshooting orchestration tool.

Its purpose is to coordinate a configurable set of Windows servers so that an operator can:

1. stop selected application components across an environment;
2. clear the relevant application logs only after all required components are safely stopped;
3. restart the environment so that fresh logs begin to be generated;
4. manually reproduce or troubleshoot an issue;
5. collect the resulting logs from all participating servers;
6. organize the collected logs by physical server and configured log source;
7. create a single ZIP bundle with a short descriptive name and timestamp;
8. copy the final bundle to a configured destination server for later analysis, email, or upload.

This tool will eventually operate against real Windows servers, IIS, IIS Application Pools, Windows services, and application log directories.

Because some operations are destructive, **safety, observability, predictable behavior, testability, configuration-driven behavior, and failure handling are critical requirements**.

---

# 1. Important instruction for this first task

**Do not implement the complete production solution yet.**

For the first iteration:

1. analyze all requirements in this document;
2. identify technical risks, ambiguities, and contradictions;
3. propose the final architecture;
4. define the configuration model;
5. define the command/status protocol;
6. define failure handling and rollback behavior;
7. define the repository structure;
8. define a safe local simulation and testing strategy;
9. create the initial architecture documentation;
10. create an `AGENTS.md` containing persistent development rules for this repository.

Do **not** implement real IIS shutdown, Application Pool shutdown, Windows service shutdown, log deletion, remote-server access, or production Scheduled Tasks yet.

Do not make changes outside this repository.

The primary deliverable for this first iteration is:

```text
docs/Architecture.md
```

You may also create:

```text
docs/Protocol.md
AGENTS.md
README.md
config/environment.example.json
config/node.example.json
```

if they help make the architecture concrete.

I will review the architecture before production behavior is implemented.

---

# 2. Core design principle: topology must be fully configurable

BrainTrace must **not assume a fixed server topology**.

It must not assume:

```text
2 TP servers
2 APP servers
2 WEB servers
6 total servers
```

Those counts describe only some existing environments.

BrainTrace must support an arbitrary number of physical Windows nodes.

Conceptually:

```text
Environment
    |
    +-- Nodes [1..N]
          |
          +-- Roles [1..N]
          +-- Components [0..N]
          +-- LogSources [0..N]
          +-- Connectivity / Routing metadata
```

The number of nodes, their logical roles, their controlled components, their log paths, and their connectivity must come from configuration.

---

# 3. Existing environment examples

The following are examples only.

They must be used to validate that the architecture is generic.

They are **not** hardcoded supported layouts.

## Example A — QA / DEV

Typical topology:

```text
2 TP
2 APP
2 WEB
```

Example:

```text
TP1
TP2
APP1
APP2
WEB1
WEB2
```

The Controller may initially run from one TP node.

That TP node can access the other TP and the APP servers over SMB/UNC.

One APP server can access the WEB servers over SMB/UNC.

Example logical connectivity:

```text
                 TP1
             [Controller]
              /    |    \
             /     |     \
           TP2    APP1   APP2
                   |
                   +-- WEB1
                   +-- WEB2
```

---

## Example B — Production

Production may have a different number of nodes.

For example:

```text
6 TP
N APP
N WEB
```

The architecture must work without code changes.

The node count must be entirely configuration-driven.

---

## Example C — PDX All-in-One environment

Some PDX environments contain:

```text
1 TP
1 All-in-One server
```

The All-in-One server performs both:

```text
APP
WEB
```

roles on the **same physical Windows server**.

For example:

```text
TP1
 |
 +-- AIO1
      Roles:
        APP
        WEB
```

The AIO server has:

- the APP Windows service;
- IIS;
- a single application log directory used by the combined APP/WEB workload.

There are **not separate APP logs and WEB logs** on the All-in-One server.

Because the node has the APP role, the application service must be stopped.

Because the node has APP and/or WEB functionality, IIS must be stopped.

However, IIS must be controlled **once per physical node**, not once per logical role.

Likewise, a single shared log directory must be cleaned and collected **once**, not once for APP and again for WEB.

---

## Example D — Possible future multi-role server

A future environment may contain a single physical server with all three roles:

```text
APP
WEB
TP
```

For example:

```text
AIO-FULL-1
Roles:
  APP
  WEB
  TP
```

In this situation:

- the APP role may require stopping the configured Windows service;
- APP and/or WEB require IIS to be stopped;
- the TP role may require stopping the configured IIS Application Pool;
- IIS must still be stopped only once per physical node;
- the TP log source may use a different directory from the APP/WEB log source;
- OR the TP role may use the same physical log directory as APP/WEB.

Therefore the implementation must not infer log directories directly from roles.

Log sources belong to the **physical node configuration**.

If two logical roles refer to the same canonical physical path, BrainTrace must treat that path as one log source for cleanup and collection purposes unless explicitly configured otherwise.

---

# 4. Physical nodes vs logical roles

This distinction is fundamental.

BrainTrace must model:

```text
Physical Node
    |
    +-- one or more Roles
```

Initial known roles:

```text
TP
APP
WEB
```

A physical node may have:

```text
Roles = ["APP", "WEB"]
```

or potentially:

```text
Roles = ["APP", "WEB", "TP"]
```

Do not model a multi-role physical server as multiple fake servers.

All state, locking, Worker execution, IIS state, filesystem paths, and result reporting should understand that it is one physical machine.

---

# 5. Components should be configured independently of log sources

Roles are useful for classification, display, defaults, and validation.

However, BrainTrace should primarily execute configured **components** on each node.

Known component types include:

```text
WindowsService
IIS
IISAppPool
```

For example, an APP+WEB All-in-One node might effectively contain:

```text
WindowsService: Mobiliti
IIS
```

not:

```text
APP-IIS
WEB-IIS
```

IIS is a node-level component and should be operated once.

A TP node might contain:

```text
IISAppPool: StandardBankingService
```

A future APP+WEB+TP node could contain:

```text
WindowsService: Mobiliti
IIS
IISAppPool: StandardBankingService
```

The architecture should prevent duplicate operations on the same physical component.

---

# 6. Log sources are physical resources, not role-owned resources

A node must have a configurable list of log sources.

Example conceptual configuration:

```json
{
  "LogSources": [
    {
      "Id": "Mobiliti",
      "Path": "D:\\Program File\\Fiserv\\Mobiliti\\MTS Platform\\Logs"
    }
  ]
}
```

A TP node may have:

```json
{
  "LogSources": [
    {
      "Id": "SBI",
      "Path": "D:\\Logfiles\\Mobile\\SBILogs\\4.5"
    }
  ]
}
```

A future APP+WEB+TP node could have separate paths:

```json
{
  "LogSources": [
    {
      "Id": "Mobiliti",
      "Path": "D:\\Program File\\Fiserv\\Mobiliti\\MTS Platform\\Logs"
    },
    {
      "Id": "SBI",
      "Path": "D:\\Logfiles\\Mobile\\SBILogs\\4.5"
    }
  ]
}
```

Or both logical workloads may point to the same physical path.

The architecture must handle shared paths safely.

Before cleanup or collection, log paths should be normalized/canonicalized and duplicate physical paths should be detected.

Do not execute duplicate cleanup or duplicate collection against the same canonical path merely because multiple roles reference it.

---

# 7. Known component behavior

These values must eventually be configurable.

They are examples from current environments.

## TP behavior

Known TP component:

```text
IIS Application Pool:
StandardBankingService
```

Known TP log directory:

```text
D:\Logfiles\Mobile\SBILogs\4.5
```

Prepare behavior:

```text
STOP:
    Stop StandardBankingService App Pool

CLEAN:
    Clear configured TP log source(s)

START:
    Start StandardBankingService App Pool
```

The App Pool name must not be hardcoded into orchestration logic.

---

## APP behavior

Known APP component:

```text
Windows Service:
Mobiliti
```

APP also requires IIS to be stopped during Prepare.

Known APP log directory:

```text
D:\Program File\Fiserv\Mobiliti\MTS Platform\Logs
```

Prepare behavior:

```text
STOP:
    Stop Mobiliti service
    Stop IIS

CLEAN:
    Clear configured log source(s)

START:
    Start Mobiliti service
    Start IIS
```

The final architecture should analyze and document the correct dependency-aware STOP and START order inside a node.

Do not assume the order shown above is necessarily final.

---

## WEB behavior

WEB requires IIS to be stopped.

Known WEB log directory:

```text
D:\Program File\Fiserv\Mobiliti\MTS Platform\Logs
```

Prepare behavior:

```text
STOP:
    Stop IIS

CLEAN:
    Clear configured log source(s)

START:
    Start IIS
```

---

## APP + WEB All-in-One behavior

A physical APP+WEB node must behave approximately as:

```text
STOP:
    Stop Mobiliti service
    Stop IIS

CLEAN:
    Clear the single configured APP/WEB log directory once

START:
    Start required components in the correct dependency-aware order
```

Do not execute IIS STOP twice.

Do not execute IIS START twice.

Do not clear the same log directory twice.

Do not collect the same log directory twice.

---

## APP + WEB + TP future behavior

A physical APP+WEB+TP node may require:

```text
STOP:
    Stop TP App Pool
    Stop Mobiliti service
    Stop IIS
```

or another dependency-aware sequence determined by architecture/configuration.

It may have:

```text
1 shared log path
```

or:

```text
2 or more distinct log paths
```

BrainTrace must determine unique operations from the configured physical resources, not from the raw number of roles.

---

# 8. Connectivity constraints

The known reliable connectivity is SMB/UNC filesystem access.

For example:

```text
\\server\d$\Some\Folder
```

Do not design BrainTrace around PowerShell Remoting.

Do not assume the following are available:

```text
WinRM
Invoke-Command
PowerShell Remoting
CredSSP
Kerberos delegation
Kerberos constrained delegation
```

Avoid creating a dependency on the Windows authentication "second hop" problem.

BrainTrace must work using existing SMB/UNC access paths.

Remote Scheduled Task triggering may be considered later as an optimization if permissions allow it, but must not be required for the base architecture.

---

# 9. Connectivity must also be configuration-driven

Do not hardcode:

```text
TP1 -> APP1 -> WEB1
```

as a universal architecture.

Different environments may have different connectivity.

The configuration must describe which nodes can reach which other nodes.

A simple explicit connection graph is acceptable.

Conceptually:

```json
{
  "Connections": [
    {
      "From": "TP1",
      "To": "TP2",
      "Protocol": "SMB"
    },
    {
      "From": "TP1",
      "To": "APP1",
      "Protocol": "SMB"
    },
    {
      "From": "APP1",
      "To": "WEB1",
      "Protocol": "SMB"
    }
  ]
}
```

Do not overengineer version 1 into a general network-routing engine.

It is acceptable for routes/relays to be explicit and deterministic.

The architecture should favor operational clarity over clever automatic routing.

---

# 10. Controller, Worker, Relay, Aggregator

BrainTrace should conceptually support these responsibilities:

```text
Controller
Worker
Relay / Gateway
Aggregator
```

They are responsibilities, not necessarily four different executables.

## Controller

The Controller:

- starts a BrainTrace workflow;
- loads environment configuration;
- validates topology/configuration;
- generates RunId and CommandIds;
- sends commands;
- waits for status;
- enforces phase barriers;
- coordinates rollback where possible;
- displays human-readable progress;
- records run-level state.

## Worker

Each physical node runs a local Worker.

The Worker performs privileged local actions.

Examples:

- inspect component state;
- stop/start a Windows service;
- stop/start IIS;
- stop/start an IIS Application Pool;
- validate component state;
- clean approved local log directories;
- collect/copy local files as required;
- write structured result/status data.

## Relay

A relay forwards messages/status between nodes when the Controller cannot directly reach a target.

Relay routing must be configuration-driven.

The relay must never allow arbitrary destinations supplied by untrusted command data.

## Aggregator

The Aggregator is the node or location where collected logs are assembled before compression.

The Aggregator must be configurable.

Do not assume a particular APP node is always the Aggregator.

---

# 11. Worker deployment model

Each participating Windows node should eventually have a local BrainTrace directory similar to:

```text
D:\BrainTrace\
    Worker.ps1
    Config.json

    Inbox\
    Processing\
    Status\
    Archive\
    Logs\
```

A node acting as relay or aggregator may additionally use:

```text
Relay\
Staging\
Bundles\
```

Exact paths must be configurable.

---

# 12. Scheduled Task Worker model

The Worker should eventually be launched by a Windows Scheduled Task.

Conceptual task name:

```text
BrainTrace-Worker
```

Initial model:

```text
Scheduled Task
    |
    +--> Worker.ps1
             |
             +--> Check Inbox
             +--> Validate command
             +--> Claim command
             +--> Execute supported action
             +--> Write structured status
             +--> Archive processed command
             +--> Exit
```

The Scheduled Task may initially run every minute.

Do not implement BrainTrace as a permanent custom network listener.

A future optimization may trigger the task immediately when supported, while scheduled polling remains a fallback.

---

# 13. Security boundary

Command files are data.

They are not scripts.

Do not permit command JSON to contain arbitrary PowerShell code.

Do not implement anything conceptually equivalent to:

```text
PowerShellCommand = "..."
```

Do not use:

```powershell
Invoke-Expression
```

Use a strict allow-list of supported actions.

Initial logical actions may include:

```text
STATE
STOP
CLEAN
START
STATUS
COLLECT
```

Internal relay/aggregation operations may be defined if necessary.

Unknown actions must be rejected.

---

# 14. Command identity

Every environment-wide workflow execution must have a unique:

```text
RunId
```

Every command must have a unique:

```text
CommandId
```

Example RunId:

```text
20260813_131500
```

A GUID is appropriate for CommandId.

The design must prevent a status file from an old run from satisfying a command in a new run.

---

# 15. Suggested command schema

Design and improve a JSON schema conceptually similar to:

```json
{
  "ProtocolVersion": 1,
  "RunId": "20260813_131500",
  "CommandId": "guid-here",
  "CreatedUtc": "2026-08-13T19:15:00Z",
  "ExpiresUtc": "2026-08-13T19:20:00Z",
  "SourceNode": "TP1",
  "TargetNode": "APP1",
  "Action": "STOP"
}
```

Evaluate:

- protocol versioning;
- timestamps;
- target validation;
- stale-command expiration;
- duplicate processing;
- replay protection;
- idempotency;
- routing metadata;
- correlation;
- relay metadata.

Keep the protocol human-readable and manually troubleshootable.

---

# 16. Suggested status schema

A Worker should produce structured status similar to:

```json
{
  "ProtocolVersion": 1,
  "RunId": "20260813_131500",
  "CommandId": "guid-here",
  "Node": "APP1",
  "Roles": ["APP"],
  "Action": "STOP",
  "Result": "SUCCESS",
  "StartedUtc": "2026-08-13T19:15:04Z",
  "CompletedUtc": "2026-08-13T19:15:08Z",
  "Message": "Configured components stopped successfully"
}
```

At minimum consider:

```text
SUCCESS
FAILED
TIMEOUT
SKIPPED
REJECTED
```

Avoid unnecessary status complexity.

---

# 17. Atomic filesystem messaging

Account for filesystem race conditions.

The Worker must not read a command while it is still being written.

Use an atomic publication strategy such as:

```text
write command.tmp
flush/close
rename command.tmp -> command.json
```

The Worker should only process finalized files.

Consider a lifecycle such as:

```text
Inbox
  -> Processing
  -> Archive
```

and:

```text
Status
```

Moving a command into Processing should act as the local claim operation.

Design this for deterministic behavior and crash recovery.

---

# 18. Idempotency and duplicate handling

BrainTrace should be reasonably idempotent.

Examples:

- STOP on an already stopped component should be handled safely;
- START on an already started component should be handled safely;
- a duplicate CommandId must not execute a destructive CLEAN twice;
- duplicate relay delivery must not duplicate the underlying operation;
- duplicate role membership must never cause duplicate physical operations.

Maintain a simple processed-command history.

Do not introduce a database unless strongly justified.

---

# 19. Workflow A — Prepare

The first major workflow is:

```text
Prepare
```

Conceptual CLI:

```powershell
.\BrainTrace.ps1 Prepare -Environment QA
```

The purpose is to establish a known point where relevant application logs are empty and all configured application components have been restored to the required running state.

The workflow must be globally coordinated.

---

# 20. Prepare Phase 0 — Validation and state capture

Before changing anything:

1. load environment configuration;
2. validate every node;
3. validate component definitions;
4. validate log-source definitions;
5. normalize/canonicalize all cleanup paths;
6. detect duplicate/shared log paths;
7. validate connectivity/routes required for the operation;
8. capture current component state on every node;
9. create a Run workspace;
10. acquire an environment-wide lock.

State must be associated with the current RunId.

Examples:

```text
APP1 Mobiliti = Running
APP1 IIS      = Running
TP1 AppPool   = Started
```

This state is required for diagnostics and rollback.

---

# 21. Prepare Phase 1 — STOP

The Controller requests STOP on every participating physical node.

Each Worker evaluates its configured components.

A node may have one role or multiple roles.

The Worker must derive a unique set of physical component operations.

Example:

```text
Roles = APP + WEB
```

must result in:

```text
Stop Mobiliti
Stop IIS
```

not:

```text
Stop Mobiliti
Stop IIS for APP
Stop IIS again for WEB
```

A future:

```text
Roles = APP + WEB + TP
```

may result in:

```text
Stop StandardBankingService App Pool
Stop Mobiliti
Stop IIS
```

with the exact dependency-aware order defined by configuration/architecture.

The Worker must verify final component states before returning SUCCESS.

---

# 22. Global STOP barrier

This is a critical safety rule.

BrainTrace must **not enter CLEAN until every required physical node has successfully completed STOP**.

Conceptually:

```text
STOP all participating nodes
        |
        v
WAIT FOR ALL
        |
        +---- all SUCCESS ---> CLEAN
        |
        +---- any failure ---> ABORT / ROLLBACK
```

Commands may be dispatched concurrently if appropriate.

The transition into CLEAN is globally synchronized.

---

# 23. STOP ordering

Analyze whether shutdown ordering should be:

```text
by tier
```

or:

```text
by explicit configured component groups
```

or another mechanism.

Do not hardcode:

```text
TP -> APP -> WEB
```

because multi-role nodes and future environments may make that invalid.

Prefer a configurable phase/order model if ordering is required.

Keep version 1 understandable and deterministic.

---

# 24. Prepare Phase 2 — CLEAN

Each Worker cleans its own configured local log sources.

The Controller should not directly perform destructive deletion through remote UNC paths unless there is a compelling architectural reason.

The Worker must operate on unique canonical log paths.

Examples:

APP+WEB AIO:

```text
Roles:
  APP
  WEB

LogSources:
  D:\Program File\Fiserv\Mobiliti\MTS Platform\Logs
```

must clean that directory once.

Future APP+WEB+TP with separate logs:

```text
Mobiliti:
  D:\Program File\Fiserv\Mobiliti\MTS Platform\Logs

SBI:
  D:\Logfiles\Mobile\SBILogs\4.5
```

must clean both unique directories.

Future APP+WEB+TP where TP uses the same physical path as APP/WEB must clean that physical path once.

Do not delete the log root directory unless explicitly required.

Prefer clearing the contents.

---

# 25. Destructive cleanup safety

CLEAN is the highest-risk operation.

A configuration mistake must never result in broad destructive deletion.

Design explicit safeguards.

At minimum evaluate:

- canonical/full-path normalization;
- rejection of drive roots;
- rejection of filesystem/share roots;
- minimum path depth;
- path existence checks;
- trusted `AllowedCleanupRoots`;
- optional safety-marker files;
- no user-supplied arbitrary paths in command messages;
- configuration-only cleanup paths;
- exact logging of the canonical target;
- DryRun;
- duplicate-path detection;
- protection against junctions/reparse points if relevant;
- careful handling of wildcards;
- bounded deletion behavior.

Do not implement destructive cleanup in this first iteration.

Document the safety contract first.

---

# 26. Global CLEAN barrier

CLEAN must also have a global barrier.

Conceptually:

```text
CLEAN all required unique log sources on all nodes
        |
        v
WAIT FOR ALL
        |
        +---- all SUCCESS ---> START
        |
        +---- any failure ---> failure handling
```

CLEAN is not perfectly reversible.

If logs are deleted successfully on five nodes and deletion fails on the sixth, the deleted logs cannot truly be restored.

Document the correct operational behavior honestly.

Do not describe CLEAN rollback as fully transactional.

---

# 27. Prepare Phase 3 — START

After CLEAN completes, BrainTrace starts only the components that should be restored.

The exact start behavior must account for the captured initial state and the desired operational end state.

A multi-role node must again deduplicate physical component operations.

Example APP+WEB AIO:

```text
Start IIS once
Start Mobiliti once
```

in the correct dependency-aware sequence.

Future APP+WEB+TP may require:

```text
Start IIS
Start Mobiliti
Start StandardBankingService App Pool
```

or another configured order.

The architecture must not hardcode a universal tier sequence.

---

# 28. Original-state preservation

Before STOP, BrainTrace records whether each component was originally running/stopped.

This matters during failure rollback.

Example:

```text
StandardBankingService was already stopped before BrainTrace began.
```

If BrainTrace aborts before CLEAN, rollback should not blindly start that App Pool.

Rollback should restore the state BrainTrace changed during the current RunId where reasonably possible.

Design state tracking at the physical-component level.

---

# 29. Prepare failure handling

Example:

```text
NodeA SUCCESS
NodeB SUCCESS
NodeC FAILED
NodeD SUCCESS
```

If STOP has not completed successfully everywhere:

1. do not enter CLEAN;
2. identify the failing node/component;
3. abort the forward workflow;
4. attempt to restore components changed by the current RunId;
5. report rollback status clearly;
6. preserve diagnostic state and logs.

Do not silently continue after critical failures.

---

# 30. Relay architecture

Some environments require relays because the Controller cannot directly reach every node.

Example:

```text
TP1 Controller
     |
     v
APP1 Relay
     |
     +--> WEB1
     +--> WEB2
```

But APP1 is not universally the relay.

Relay nodes and routes must be configured per environment.

A relay may:

1. receive a command intended for a downstream node;
2. validate the configured route;
3. atomically publish the command to the downstream node Inbox;
4. observe/retrieve the downstream status;
5. make the result available upstream.

Prevent:

- relay loops;
- arbitrary destinations;
- arbitrary UNC targets in command data;
- duplicate forwarding;
- stale command execution;
- replay.

Prefer explicit routing for version 1 over a complex automatic route-finding engine.

---

# 31. Workflow B — Collect

The second major workflow is:

```text
Collect
```

Conceptual CLI:

```powershell
.\BrainTrace.ps1 Collect -Environment QA -Name "LoginFailure"
```

The operator manually performs troubleshooting between:

```text
Prepare
```

and:

```text
Collect
```

BrainTrace does not need to automatically determine when the manual test is complete.

---

# 32. Collect must be non-destructive

Collect must never:

```text
delete
truncate
move
rename
modify
```

application logs on source servers.

It may only copy source logs.

Temporary BrainTrace staging data may be cleaned according to a defined safe retention policy after successful completion.

---

# 33. Bundle name

The resulting ZIP should use:

```text
<ShortDescription>_<Timestamp>.zip
```

Example:

```text
LoginFailure_20260813_134512.zip
```

Sanitize:

- invalid Windows filename characters;
- leading/trailing whitespace;
- trailing periods;
- excessive length;
- empty descriptions;
- reserved Windows names if relevant.

---

# 34. Bundle structure

Bundle organization must be based on physical nodes.

Do not assume fixed TP/APP/WEB folders.

Conceptually:

```text
LoginFailure_20260813_134512\
    NODE1\
    NODE2\
    NODE3\
```

If a physical node has one log source:

```text
AIO1\
    <logs>
```

may be sufficient.

If a physical node has multiple distinct configured log sources, preserve that distinction.

For example:

```text
AIO-FULL-1\
    Mobiliti\
    SBI\
```

The architecture should define when an extra log-source subdirectory is required.

Do not flatten files from distinct log roots if that can create collisions or lose provenance.

Shared canonical log paths should be collected once.

---

# 35. Collection topology

Collection must respect configured SMB connectivity.

A possible QA/DEV example:

```text
Controller TP1
 |
 | collect directly reachable nodes
 |
 v
APP1 Aggregator
 |
 | collect downstream WEB nodes
 |
 v
Complete staging tree
 |
 v
ZIP
 |
 v
Configured final bundle destination
```

This is an example, not a universal architecture.

The Aggregator must be configurable.

Different environments may use:

- a TP as Aggregator;
- an APP as Aggregator;
- an AIO node as Aggregator;
- another configured reachable node.

Analyze how to minimize unnecessary network copies while keeping behavior easy to troubleshoot.

---

# 36. Copy mechanism

Evaluate Windows-native:

```text
robocopy
```

for log collection.

Logs may be:

- numerous;
- large;
- nested;
- actively changing;
- partially inaccessible;
- temporarily locked.

Define:

- retry count;
- wait interval;
- recursive behavior;
- return-code interpretation;
- locked-file behavior;
- partial-copy semantics;
- metadata requirements;
- staging behavior.

Do not treat every non-zero Robocopy exit code as fatal.

Document the accepted success/warning/failure return-code policy.

---

# 37. Active log files

Some logs may still be actively written when Collect runs.

Analyze and document:

- what Robocopy or the selected copy mechanism does;
- whether partially changing files are acceptable;
- whether stabilization/retry is useful;
- whether BrainTrace should record skipped/failed files;
- whether collection should fail the whole bundle or complete with warnings.

Do not invent application-specific guarantees.

Make the policy configurable where appropriate.

---

# 38. Compression abstraction

Do not tightly couple orchestration to one compression engine.

Initial possible provider:

```text
Compress-Archive
```

Future optional provider:

```text
7-Zip
```

Logs may become large.

The workflow must allow the compression provider to change without redesigning Prepare/Collect orchestration.

Conceptual configuration:

```json
{
  "Compression": {
    "Provider": "CompressArchive"
  }
}
```

Improve as appropriate.

---

# 39. Final bundle destination

After successful compression, copy the ZIP to a configured destination.

Example concept:

```json
{
  "BundleDestination": {
    "Node": "WEB1",
    "Path": "D:\\LogBundles"
  }
}
```

The destination is not always WEB1.

Keep it configurable.

Verify at least:

- the destination file exists;
- expected file length matches.

Analyze whether SHA-256 verification provides enough value to justify the extra read/CPU/network cost.

---

# 40. BrainTrace operational logs

BrainTrace's own logs must be separate from application logs.

Example:

```text
D:\BrainTrace\Logs
```

Record useful fields such as:

```text
RunId
CommandId
Environment
Node
Roles
Action
Phase
Component
LogSource
Start
End
Duration
Result
Error
RetryCount
```

Do not log credentials, passwords, tokens, or authentication secrets.

---

# 41. Run workspace

Each workflow should have an inspectable Run workspace.

Conceptually:

```text
Runs\
    <RunId>\
        run.json
        state\
        commands\
        status\
        staging\
        logs\
```

Improve if appropriate.

A failed run must retain enough information to diagnose what happened.

---

# 42. Human-readable Controller output

The Controller should present concise output based on the configured nodes.

Example:

```text
BrainTrace Prepare
Environment: QA
Run: 20260813_131500

STOP
TP01        SUCCESS
TP02        SUCCESS
APP01       SUCCESS
APP02       SUCCESS
WEB01       SUCCESS
WEB02       SUCCESS

CLEAN
TP01        SUCCESS
TP02        SUCCESS
APP01       SUCCESS
APP02       SUCCESS
WEB01       SUCCESS
WEB02       SUCCESS

START
TP01        SUCCESS
TP02        SUCCESS
APP01       SUCCESS
APP02       SUCCESS
WEB01       SUCCESS
WEB02       SUCCESS

Environment prepared successfully.
```

For an AIO environment:

```text
STOP
TP01        SUCCESS
AIO01       SUCCESS

CLEAN
TP01        SUCCESS
AIO01       SUCCESS

START
TP01        SUCCESS
AIO01       SUCCESS
```

Do not print the same physical node twice simply because it has multiple roles.

Detailed component-level diagnostics belong in BrainTrace logs/status.

---

# 43. Timeouts

No BrainTrace operation may wait forever.

Design configurable timeouts for:

```text
Worker response
State capture
STOP
CLEAN
START
Relay
Collection
Compression
Bundle copy
```

Use bounded polling with a sensible polling interval.

Do not busy-loop.

---

# 44. Environment locking and concurrency

Initially support only one active environment-wide operation at a time.

Prevent simultaneous operations such as:

```text
Prepare A
Collect B
Prepare C
```

against the same environment.

Design a simple environment lock/lease.

Handle stale locks caused by crashes.

Do not require a database.

---

# 45. Configuration philosophy

Separate code from environment-specific configuration.

Do not hardcode:

```text
server names
node count
role count
UNC paths
local paths
service names
App Pool names
log paths
shared log-path behavior
timeouts
relay nodes
routes
aggregator
bundle destination
startup/shutdown ordering
compression provider
```

Consider at least:

```text
environment configuration
node-local configuration
```

or propose a cleaner model.

---

# 46. Example QA environment configuration

Design something conceptually similar to:

```json
{
  "EnvironmentName": "QA",
  "ControllerNode": "TP1",
  "AggregatorNode": "APP1",

  "BundleDestination": {
    "Node": "WEB1",
    "Path": "D:\\LogBundles"
  },

  "Nodes": [
    {
      "Name": "TP1",
      "Roles": ["TP"]
    },
    {
      "Name": "TP2",
      "Roles": ["TP"]
    },
    {
      "Name": "APP1",
      "Roles": ["APP"]
    },
    {
      "Name": "APP2",
      "Roles": ["APP"]
    },
    {
      "Name": "WEB1",
      "Roles": ["WEB"]
    },
    {
      "Name": "WEB2",
      "Roles": ["WEB"]
    }
  ],

  "Connections": [
    {
      "From": "TP1",
      "To": "TP2",
      "Protocol": "SMB"
    },
    {
      "From": "TP1",
      "To": "APP1",
      "Protocol": "SMB"
    },
    {
      "From": "TP1",
      "To": "APP2",
      "Protocol": "SMB"
    },
    {
      "From": "APP1",
      "To": "WEB1",
      "Protocol": "SMB"
    },
    {
      "From": "APP1",
      "To": "WEB2",
      "Protocol": "SMB"
    }
  ]
}
```

Improve this design where appropriate.

---

# 47. Example APP+WEB AIO node configuration

The exact schema should be designed by Codex, but it must be capable of representing something like:

```json
{
  "Name": "AIO1",
  "Roles": ["APP", "WEB"],

  "Components": [
    {
      "Id": "Mobiliti",
      "Type": "WindowsService",
      "ServiceName": "Mobiliti"
    },
    {
      "Id": "IIS",
      "Type": "IIS"
    }
  ],

  "LogSources": [
    {
      "Id": "MobilitiLogs",
      "Path": "D:\\Program File\\Fiserv\\Mobiliti\\MTS Platform\\Logs"
    }
  ]
}
```

The key behavior is:

```text
Mobiliti stopped once
IIS stopped once
one shared APP/WEB log path cleaned once
one shared APP/WEB log path collected once
```

---

# 48. Example future APP+WEB+TP node with separate TP logs

The configuration model must be able to express:

```json
{
  "Name": "FULLAIO1",
  "Roles": ["APP", "WEB", "TP"],

  "Components": [
    {
      "Id": "Mobiliti",
      "Type": "WindowsService",
      "ServiceName": "Mobiliti"
    },
    {
      "Id": "IIS",
      "Type": "IIS"
    },
    {
      "Id": "StandardBankingService",
      "Type": "IISAppPool",
      "Name": "StandardBankingService"
    }
  ],

  "LogSources": [
    {
      "Id": "MobilitiLogs",
      "Path": "D:\\Program File\\Fiserv\\Mobiliti\\MTS Platform\\Logs"
    },
    {
      "Id": "SBILogs",
      "Path": "D:\\Logfiles\\Mobile\\SBILogs\\4.5"
    }
  ]
}
```

---

# 49. Example future APP+WEB+TP node with a shared log path

The architecture must also support a configuration where multiple logical workloads ultimately use one physical path.

For example, if both TP and APP/WEB write into:

```text
D:\Program File\Fiserv\Mobiliti\MTS Platform\Logs
```

BrainTrace must normalize that as one physical log source and must not:

```text
clean it twice
collect it twice
```

The final configuration schema should make this explicit and unambiguous.

Prefer defining physical log sources once and optionally associating roles/workloads with those sources for metadata rather than duplicating identical path definitions.

---

# 50. Windows Service identity

Do not assume:

```text
Mobiliti
```

is definitely the stable Windows `ServiceName`.

It may currently be known by display name.

Design configuration so that the production implementation can specify the real ServiceName explicitly.

Document what must be confirmed before production deployment.

---

# 51. IIS control semantics

Be precise about what "Stop IIS" means.

Do not blindly assume:

```text
iisreset
```

is the correct production implementation.

For the architecture phase, document:

- which Windows/IIS services should eventually be controlled;
- dependencies;
- how IIS running/stopped state will be verified;
- how original state will be captured;
- how a multi-role node avoids duplicate IIS operations.

Likewise document the preferred PowerShell mechanism for Application Pool control.

Do not implement the real destructive/system-control operations yet.

---

# 52. Component dependency and ordering model

BrainTrace must support deterministic component ordering without assuming a universal fixed topology.

Evaluate a node-level concept such as:

```text
StopOrder
StartOrder
```

or dependency metadata between configured components.

For example:

```text
IISAppPool
WindowsService
IIS
```

may need one stop sequence and the reverse start sequence.

The final model should support current environments while remaining understandable.

Avoid building an unnecessarily complex generic dependency engine unless it provides clear value.

---

# 53. DryRun is mandatory

Eventually support:

```powershell
.\BrainTrace.ps1 Prepare -Environment QA -DryRun
```

and:

```powershell
.\BrainTrace.ps1 Collect -Environment QA -Name "LoginFailure" -DryRun
```

DryRun must:

- load configuration;
- validate nodes;
- validate paths;
- calculate unique physical component operations;
- calculate unique canonical log sources;
- calculate routes;
- show intended operations;
- exercise orchestration logic where possible;
- never stop services;
- never stop IIS;
- never stop App Pools;
- never delete logs;
- never modify production bundles.

DryRun must be designed from the beginning.

---

# 54. Local simulation mode

Design a local simulation that can represent arbitrary environment topologies.

Do not make the simulator assume six servers.

For example:

```text
tests\simulation\QA\
tests\simulation\PDX\
tests\simulation\PROD\
```

A simulated environment could contain node directories such as:

```text
TP1\
AIO1\
```

with:

```text
Inbox\
Processing\
Status\
Logs\
State\
```

This should allow protocol/orchestration testing on one workstation without touching real servers.

---

# 55. Testing

Design automated tests for at least:

```text
QA-like 2 TP / 2 APP / 2 WEB topology
production-like 6 TP topology
PDX 1 TP / 1 APP+WEB AIO topology
future APP+WEB+TP node
multi-role node with one shared log path
multi-role node with two distinct log paths
duplicate path definitions
duplicate component definitions
all nodes succeed
worker timeout
STOP failure
relay failure
downstream node unreachable
duplicate command
stale command
malformed JSON
unknown action
invalid cleanup path
drive-root cleanup rejection
CLEAN partial failure
START failure
rollback partial failure
Robocopy warning return code
Robocopy fatal return code
compression failure
bundle destination failure
stale environment lock
```

Use Pester if appropriate for the target PowerShell version.

Most tests must not require real IIS or real Mobiliti services.

Abstract Windows-specific operations sufficiently to mock them.

---

# 56. PowerShell compatibility

Primary target:

```text
Windows PowerShell 5.1
```

If any design choice requires PowerShell 7, explain exactly why.

Prefer standard Windows Server capabilities and minimal dependencies.

---

# 57. Coding standards for later implementation

Future implementation should favor:

```text
Set-StrictMode
explicit parameter validation
try/catch/finally
clear function boundaries
structured logging
meaningful exit codes
testable abstractions
```

Avoid monolithic scripts.

Avoid unnecessary class hierarchies or frameworks.

Prefer maintainable PowerShell.

---

# 58. Credentials

Do not store plaintext credentials.

Authentication for:

```text
SMB shares
Scheduled Tasks
service accounts
```

will be handled through Windows accounts and existing permissions.

Credential provisioning is outside the initial implementation.

Document permission requirements without inventing credentials.

---

# 59. Deployment concept

Eventually BrainTrace may have an installation/deployment helper such as:

```text
Install-BrainTraceWorker.ps1
```

It may eventually:

- create directories;
- deploy Worker files;
- validate node configuration;
- register Scheduled Tasks;
- configure local ACLs;
- validate prerequisites;
- test the Worker.

Do not implement production deployment in this first architecture phase.

---

# 60. Suggested repository structure

Evaluate a structure such as:

```text
BrainTrace\
│
├── BrainTrace.ps1
├── BrainTrace.psd1
├── BrainTrace.psm1
│
├── src\
│   ├── Controller\
│   ├── Worker\
│   ├── Relay\
│   ├── Collection\
│   ├── Compression\
│   └── Common\
│
├── config\
│   ├── environment.example.json
│   └── node.example.json
│
├── scripts\
│   └── Install-BrainTraceWorker.ps1
│
├── docs\
│   ├── Architecture.md
│   └── Protocol.md
│
├── tests\
│
├── AGENTS.md
└── README.md
```

This is only a candidate.

Use a simpler structure if more appropriate.

Explain the decision.

---

# 61. AGENTS.md

Create `AGENTS.md` with persistent repository rules.

At minimum include:

```text
Project name is BrainTrace.

Technical documentation, code comments, identifiers, test descriptions,
and code-related artifacts must be written in English.

Target Windows PowerShell 5.1 unless explicitly justified otherwise.

BrainTrace must not assume any fixed number of TP, APP, WEB, AIO, or other nodes.

A physical node may implement multiple logical roles.

Do not model a multi-role physical server as multiple fake nodes.

Roles do not own log paths. LogSources belong to physical nodes.

Shared canonical log paths must not be cleaned or collected more than once.

Node-level physical components such as IIS must not be operated more than once
because a node has multiple roles.

Do not introduce WinRM as a required dependency.

Do not introduce CredSSP or Kerberos delegation.

Do not store credentials in the repository.

Do not implement arbitrary remote command execution.

Treat command JSON as data, never executable code.

Do not use Invoke-Expression.

Do not perform destructive operations without strict path validation.

Maintain DryRun and simulation support.

Do not hardcode environment-specific server names, paths, node counts, or routes.

Keep orchestration separate from Windows-specific system operations so those
operations can be mocked in tests.

Do not silently ignore errors.

Preserve RunId and CommandId correlation.

Before implementing destructive behavior, ensure architecture and automated tests
cover that behavior.

Prefer simple Windows-native solutions over unnecessary dependencies.
```

Improve and organize these rules.

---

# 62. Documentation diagrams

Use Mermaid diagrams in `docs/Architecture.md`.

Include examples for:

## Generic node model

```text
Environment
  |
  +-- Node
       |
       +-- Roles[]
       +-- Components[]
       +-- LogSources[]
```

## QA/DEV topology example

```text
TP1
 ├─ TP2
 ├─ APP1
 │   ├─ WEB1
 │   └─ WEB2
 └─ APP2
```

## PDX AIO topology example

```text
TP1
 |
 +-- AIO1
      Roles:
        APP
        WEB
```

## Prepare sequence

```text
Validate
  |
Capture State
  |
STOP
  |
Global Barrier
  |
CLEAN unique LogSources
  |
Global Barrier
  |
START
  |
Validate
```

## Relay sequence

Use an example route but clearly state that routes are configuration-driven.

## Collect sequence

Show how configured log sources flow to the Aggregator and final bundle.

---

# 63. Architecture questions Codex must explicitly analyze

Do not merely restate this prompt.

Challenge the proposed design.

In `Architecture.md`, explicitly analyze:

1. Is filesystem messaging via SMB appropriate for BrainTrace?
2. Is a Scheduled Task Worker every minute reasonable?
3. Should one Worker invocation process one command or drain the queue?
4. What is the safest Inbox -> Processing -> Archive lifecycle?
5. How should atomic message publication work?
6. How should stale commands expire?
7. How should duplicate commands be detected?
8. How should a multi-role node deduplicate physical component operations?
9. How should duplicate/shared log paths be canonicalized and deduplicated?
10. How should reparse points/junctions affect cleanup validation?
11. Where should environment locks live?
12. Where should Run state live?
13. What is the simplest reliable relay pattern?
14. Should routing be explicit or automatically calculated?
15. How should the Aggregator be selected/configured?
16. How should BrainTrace handle active log files?
17. Should Robocopy be used?
18. Which Robocopy return codes represent success, warnings, and failure?
19. How should partially copied collections be reported?
20. What IIS control mechanism should eventually be used?
21. How should component STOP/START dependency ordering work on multi-role nodes?
22. How should original component state be preserved?
23. What rollback is realistically possible?
24. Which operations are inherently irreversible?
25. How should temporary staging cleanup work safely?
26. How should ZIP/bundle integrity be validated?
27. How should the architecture scale from 2 nodes to 10+ nodes?
28. How should a physical node with APP+WEB be represented without duplicate IIS/log operations?
29. How should APP+WEB+TP be represented when TP logs are separate?
30. How should APP+WEB+TP be represented when TP and APP/WEB share the same log path?
31. Is the proposed Components + LogSources separation sufficient, or is a better model preferable?
32. What configuration errors should be rejected before any workflow begins?

---

# 64. First-task safety boundary

For this first Codex task, do not write code that performs real:

```text
Stop-Service
Start-Service
Stop-WebAppPool
Start-WebAppPool
IIS shutdown/startup
application-log deletion
remote-server access
Scheduled Task registration
```

Do not access infrastructure.

Do not attempt infrastructure discovery.

Do not create credentials.

Do not change Windows configuration.

Stay inside the repository.

---

# 65. First-task deliverables

Create:

```text
docs/Architecture.md
docs/Protocol.md
AGENTS.md
README.md
config/environment.example.json
config/node.example.json
```

Examples must include enough configuration to demonstrate at least:

```text
QA/DEV-style environment
PDX APP+WEB All-in-One environment
future APP+WEB+TP node
```

No real production server names are required.

Use logical names such as:

```text
TP1
TP2
APP1
APP2
WEB1
WEB2
AIO1
FULLAIO1
```

---

# 66. Architecture.md expectations

`docs/Architecture.md` should include:

1. Purpose
2. Goals
3. Non-goals
4. Assumptions
5. Generic environment model
6. Physical node vs logical role model
7. Component model
8. LogSource model
9. Shared-path deduplication model
10. Connectivity model
11. Controller responsibilities
12. Worker responsibilities
13. Relay responsibilities
14. Aggregator responsibilities
15. Message lifecycle
16. Run lifecycle
17. Prepare workflow
18. State capture
19. STOP barrier
20. CLEAN barrier
21. START behavior
22. Multi-role node behavior
23. Failure handling
24. Rollback
25. Irreversible operations
26. Idempotency
27. Locking
28. Security
29. Cleanup safety
30. Logging
31. Timeouts
32. Collect workflow
33. Bundle structure
34. Compression abstraction
35. Testing strategy
36. Simulation strategy
37. Deployment concept
38. Future extensions
39. Open questions requiring confirmation before production implementation

---

# 67. Protocol.md expectations

`docs/Protocol.md` should define:

```text
ProtocolVersion
RunId
CommandId
Command schema
Status schema
Allowed actions
Result states
Queue lifecycle
Atomic publication
Relay behavior
Duplicate handling
Expiration handling
Filename conventions
Node identity
Physical-node semantics
```

Include JSON examples.

---

# 68. README expectations

The initial README should explain:

```text
What BrainTrace is
What problem it solves
Why topology is configuration-driven
How multi-role nodes work
High-level architecture
Current project status
Repository structure
Safety status
Next development phase
```

Clearly state that the initial version is architecture-only and not ready to operate against real servers.

---

# 69. Final response for this first Codex task

After creating the design files:

1. summarize the proposed architecture;
2. list files created;
3. identify where you changed or improved the proposed design;
4. list unresolved questions required before production implementation;
5. identify the highest-risk future implementation areas;
6. specifically confirm how the design handles:
   - variable node counts;
   - APP+WEB All-in-One;
   - future APP+WEB+TP;
   - separate TP logs on a multi-role server;
   - shared TP and APP/WEB log paths;
   - duplicate IIS operations;
   - duplicate cleanup/collection operations;
7. do not proceed into production implementation until explicitly requested.

The goal of this first iteration is to produce a design that can be reviewed before BrainTrace is allowed to control real Windows servers.
