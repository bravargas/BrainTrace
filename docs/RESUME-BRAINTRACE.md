# BrainTrace resume point

Last updated: 2026-08-14

## Current status

Testing paused because the DEV servers entered maintenance.

While DEV is unavailable, a laptop-only `LocalLab.cmd` was added. It creates TP1, TP2, App1, App2, Web1, and Web2 as isolated local roots and runs the real Workers and operations monitors concurrently without Scheduled Tasks or SMB. Local Diagnose, Worker/collection Test, Web1 portal Diagnose, Collect with ZIP, and live sandbox-only Prepare have all completed successfully. Use menu option 1 to initialize and option 3 for the fastest full preflight.

The file-only operations route has been proven end to end:

```text
Web1 -> App1 -> TP1 -> App1 -> Web1
```

Web1 successfully received and displayed a `Diagnose` result executed by TP1. This confirms that request publication, both monitor tasks, TP1 execution, and result return are working.

Before the portal test, the normal TP1 diagnostic showed all six Worker installations as `OK`, with fresh heartbeats, empty queues, and no fatal errors. Task result `267009` means the task is currently running; it is not a failure.

## Problems fixed during validation

- Replaced WEB `d$` access with `FiservSoftware$` shares so App1 `SYSTEM` can reach Web1 and Web2 as the App1 machine account.
- Replaced the App1 operations-relay `d$` path with `FiservSoftware$` so TP1 can reach it as the TP1 machine account.
- Corrected inherited write permissions on App1's `OperationsRelay`; TP1 had failed while writing `Operations-Monitor.jsonl`.
- Fixed Windows PowerShell 5.1 parameter binding in `Operations-Monitor.ps1`. Array splatting had passed `-Environment` as a positional value; the executor now uses named hashtable splatting.
- Standardized configured operational shares as the hidden share name `FiservSoftware$`.

## Latest observed result

The latest Diagnose launched from the Web1 operations menu completed and returned to Web1, but only TP1 appeared as `OK`. TP2, App1, App2, Web1, and Web2 showed `NO ACCESS` in that returned report.

This is understood: the portal executes `BrainTrace.ps1 Diagnose` under `SYSTEM` on TP1. The configuration installed for that test still used administrative `d$` paths for TP2/App1/App2, which the TP1 machine account cannot use.

The repository configuration has since been changed to use `FiservSoftware$` for:

- TP2 `CommandRoot`;
- App1 `CommandRoot`;
- App2 `CommandRoot`;
- Web1 and Web2 `CommandRoot`;
- `StagingRootUNC` on App1;
- the Web1 operations hub and App1 operations relay.

These latest command/staging path changes were not deployed or tested before maintenance began.

## Shares and permissions

All shares below map to `D:\FiservSoftware` and are named `FiservSoftware$`.

### Confirmed working

- Web1 and Web2: grant `DOMAIN\vsmobappdev03$` Share `Read` + `Change` and NTFS `Modify`.
- App1 operations relay: grant `DOMAIN\vscorappdev01$` Share `Read` + `Change` and NTFS `Modify`, applying to the folder, subfolders, and files.

### Still to create or confirm

- TP2: `FiservSoftware$`, granting `DOMAIN\vscorappdev01$` Share `Read` + `Change` and NTFS `Modify`.
- App2: `FiservSoftware$`, granting `DOMAIN\vscorappdev01$` Share `Read` + `Change` and NTFS `Modify`.
- Confirm the same TP1 machine-account permissions remain effective on App1 for the entire BrainTrace tree, not only one file.

Use the real domain prefix in place of `DOMAIN`.

## Exact next steps after maintenance

1. Confirm/create the `FiservSoftware$` shares and permissions on TP2, App1, and App2 as listed above.
2. Put the latest BrainTrace version on TP1.
3. Run `Deploy-DEV.cmd` as Administrator on TP1 and confirm with `Y`. Do not reinstall Scheduled Tasks.
4. Wait one to two minutes.
5. On Web1, open `Operations-DEV.cmd` and select `1 - Diagnose environment`.
6. Expected result: all six nodes show `Files OK`, fresh file heartbeats, queue `0`, and no fatal errors.
7. If any node still shows `NO ACCESS`, inspect the corresponding share and NTFS permissions for `DOMAIN\vscorappdev01$`.

## Following test

After portal Diagnose succeeds, run option `2 - Test Workers and collection access`.

WEB log collection may still fail because the configured Mobiliti log paths are outside `D:\FiservSoftware` and currently use `d$`. If so, the next change is to create dedicated read-only log shares rather than grant administrative-share access.

## Repository checkpoint

- Last commit at pause: `a7d1dd2 Fix operations CLI parameter binding on PowerShell 5.1`
- Test status: 29 passed, 0 failed.
- Working tree was clean before adding this resume document.
