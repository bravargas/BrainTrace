# BrainTrace Phase 2.5 implementation audit

## Scope and result

This audit compares the Phase 2 implementation with `Architecture.md`, `Protocol.md`, and `AGENTS.md`. It strengthens only approved simulation, protocol, configuration, orchestration, and safety behavior. It adds no Windows service, IIS, deletion, production SMB/Robocopy, Scheduled Task, or other Phase 3 adapter.

Baseline before the audit: **72 passed, 0 failed, 0 skipped** on Windows PowerShell 5.1. The final count and exact runtime are recorded in the final verification section below after the last clean run.

## Defects found and fixes

1. **Canonical JSON did not preserve scalar arrays.** PowerShell scalar values were reflected as objects such as `{"Length":3}`, and singleton arrays could collapse. The converter now distinguishes supported scalars before `PSCustomObject`, and preserves JSON array shape.
2. **Canonical ordering used process-culture sorting.** Object keys and documented set-like collections now use `StringComparer.Ordinal` explicitly.
3. **Windows path case could change ConfigHash.** Hash-relevant Windows paths, including CollectionAssignment endpoint templates, now use absolute/dot/trailing-separator normalization and invariant uppercase.
4. **No frozen hash vector existed.** A repository fixture now has a literal expected SHA-256 value, plus culture, NFC, default/null, formatting, path-equivalence, assignment, ordering, and safety-policy tests.
5. **Stale `Processing` work was not recovered.** The Worker now checks Control first, then recovers existing Processing entries before claiming Inbox work.
6. **Receipt-boundary crash behavior was incomplete.** Durable transitions now cover `CLAIMED`, `AUTHORIZED`, `EXECUTING`, `EFFECT_APPLIED`, and `TERMINAL`; an applied effect stores its result before status publication. Terminal status and Archive recovery are idempotent.
7. **A simulated crash could continue in the same Worker invocation.** `CRASHED` and `INDETERMINATE` stop the bounded drain, making restart tests meaningful.
8. **Uncertain work could be replayed.** `EXECUTING` is now held as indeterminate. CLEAN is never automatically replayed. `EFFECT_APPLIED` is finalized from durable evidence rather than re-entering the adapter.
9. **Inbox suppression lacked a durable receipt.** PHASE_CLOSE now writes a terminal `NOT_EXECUTED` receipt before archiving suppressed work.
10. **Control filenames did not guarantee close priority.** Control claiming inspects messages and orders `PHASE_CLOSE` ahead of `PHASE_OPEN`, then ahead of ordinary Inbox work.
11. **A close crash boundary was weak.** The simulator can crash after the durable closed fence and before reconciliation; a duplicate close completes reconciliation without reopening.
12. **Simulation containment used unsafe string-prefix checks.** CLEAN and simulated copy now require strict descendant boundaries and reject reparse points. Node validation rejects drive/share-root cleanup targets.
13. **Collection route validation checked node continuity but not staging-path continuity or final endpoint kind.** It now checks ExecutorNode, endpoint kinds, full installed assignment equality, step path continuity, and final `AggregatorStaging` termination.
14. **Protocol JSON/schema validation was incomplete.** Duplicate JSON property names, invalid timestamp ordering/excessive lifetime, and parameters outside each action's closed schema now fail closed.
15. **Relay status-return failure was only reported by the relay unit.** Controller dispatch now treats it as `STATUS_LOST`, fails the barrier, and enters normal close/reconciliation.
16. **Time-sensitive tests depended on wall time.** Protocol time and simulated delay use an injectable UTC clock/scheduler; deterministic tests advance time without sleeping.

## Architecture-to-implementation traceability

| Architecture invariant | Implementation | Meaningful tests | Scenario/evidence |
|---|---|---|---|
| Physical-node identity | `Test-BTEnvironmentConfiguration`, `Get-BTControllerInputs`, `New-BTRunPlan` | Configuration topology and wrong-target tests | QA, PROD_6TP, PDX_AIO, both FULL_AIO scenarios |
| Multi-role component deduplication | `Get-BTComponentKey`, node uniqueness validation, canonical inventory | APP+WEB one-IIS tests and end-to-end AIO STOP details | PDX_AIO, FULL_AIO scenarios |
| Shared LogSource deduplication | `Get-BTLogSourceKey`, canonical-path uniqueness validation | shared/separate AIO tests; duplicate canonical path negative test | FULL_AIO_SHARED_LOGS and FULL_AIO_SEPARATE_LOGS |
| INVENTORY | `Get-BTNodeInventory`, `Invoke-BTInventoryPreflight` | wrong hash and role-inventory mismatch; end-to-end preflight | All scenarios |
| ConfigHash binding | canonical functions, preflight comparison, Worker claim/effect checks | frozen vector; drift before STOP/CLEAN/START; wrong expected hash | PDX_AIO and frozen fixture |
| STATE capture | `Get-BTObservedState`, STATE Worker action, `RunSnapshots` | initially-stopped rollback and workspace state evidence | PDX_AIO |
| CommandId replay protection | command hash plus durable receipts | identical duplicate and collision tests | PDX_AIO filesystem queues |
| Atomic publication | `Write-BTJsonAtomic`, `Publish-BTMessage`, `Publish-BTStatus` | finalized-file visibility/no `.tmp` test | Local queue fixture |
| Control queue priority | `Claim-BTMessage`, Worker drain order | close + delayed open + waiting STOP; state and phase record assertions | PDX_AIO |
| PHASE_OPEN | `Open-BTPhase`, Worker control action | token/epoch, higher-then-stale-lower, delayed open after close | PDX_AIO |
| PHASE_CLOSE | `Close-BTPhase`, durable phase record | Inbox/Processing/executing/status-lost, duplicate close, crash-after-fence | PDX_AIO |
| Late-command suppression | closed phase validation and NOT_EXECUTED receipt | late STOP/START after restart; delayed mutation | PDX_AIO |
| Reconciliation | receipt states, observed component state, close payload | timeout, status loss, crash, indeterminate CLEAN | PDX_AIO |
| STOP barrier | `Assert-BTBarrierSuccess`, Prepare STOP/close flow | success, timeout rollback, relay status loss | PDX_AIO |
| CLEAN barrier | STOP-fence prerequisite and Prepare CLEAN close | CLEAN-before-STOP negative test; ConfigHash drift; indeterminate receipt | PDX_AIO |
| Rollback before CLEAN | Prepare STOP failure branch and `ROLLBACK_START` snapshot restore | STOP timeout; initially-stopped component restored | PDX_AIO |
| Recovery after CLEAN | `RECOVERY_START` selection after CLEAN failure | indeterminate CLEAN/no replay is tested at Worker boundary | PDX_AIO; Controller multi-process timing remains future work |
| `RECOVERY_REQUIRED` | missing close acknowledgement and failed recovery result | unreachable required Worker | PDX_AIO relay-unavailable sentinel |
| Directional collection routing | environment route validator and `Get-BTCollectionPlan` | wrong/reversed/gapped/disconnected/final-kind/duplicate routes | QA and PDX_AIO |
| SourceNode vs ExecutorNode | authoritative source lookup plus installed assignment match | SourceNode != ExecutorNode; wrong ExecutorNode/source/LogSource | QA WEB routes |
| Environment locking | named mutex + diagnostic file and authority check | same environment, Prepare/Collect overlap, different environments, live-vs-stale file | local workstation |
| DryRun safety | DryRun branches and no-write report | QA DryRun verifies no archived commands | QA |

## Test-quality assessment

The pre-audit suite had useful topology and happy-path coverage, but several fencing tests constructed internal receipt objects and asserted only a disposition. Those tests were retained where they express a protocol classification, then supplemented with observable state, durable receipt/phase files, Status publication, Archive movement, and restart behavior. The frozen ConfigHash vector replaces self-comparison as the compatibility oracle.

## Limits of the synchronous simulator

The following invariants cannot yet be proven convincingly by one synchronous PowerShell process:

- a second Worker process observing PHASE_CLOSE while the first process is inside a real blocking adapter call;
- OS mutex/abandoned-mutex behavior across forced process termination at each filesystem flush boundary;
- SMB server/client cache visibility and atomic rename semantics across machines;
- relay control overtaking when separate relay processes and real network outages are involved;
- actual service/IIS state reconciliation after a process or OS crash;
- actual ACL identity and directional share reachability.

These require a disposable, multi-process Windows integration harness and later reviewed infrastructure fixtures. They do not justify adding production adapters in Phase 2.5.

## Safety and compatibility verification

- PowerShell parser validation covers every `.ps1`, `.psm1`, and `.psd1` file.
- Clean `powershell.exe -NoProfile` module import is required and records the actual Desktop/5.1 version.
- An AST command scan covers executable module/script files for forbidden production commands. Text references to Robocopy in policy names/tests are not invocations.
- Simulation cleanup tests operate only under Pester `TestDrive` and injected scenario roots. Outside sentinels are asserted unchanged.
- No production-capable adapter is present.
