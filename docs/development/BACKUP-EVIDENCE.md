# Backup engine verification checkpoint

Status: implementation checkpoint, not release acceptance.

Actual Linux pwsh execution: `pwsh -NoProfile -File tests/Backup.Tests.ps1` => 137 assertions passed, 9 explicit Windows-dependent skips. `tests/BackupCli.Tests.ps1` => real child-process backup, full verification, tampering detection, restored verification, deep comparison, recovery dry-run, real selected file recovery, listing and help passed. All 12 standalone suites exited 0 in isolated Linux pwsh processes; raw capture `/root/.hermes/cache/scratch/pitr-suite-results.json`.

## Fixed by running tests

- Complete scope duplicated the same profile tree. Personal scope included whole profiles. Complete now has one root per profile; Personal uses existing conventional personal folders with explicit redirected-folder limitation.
- Verification on Verified generations previously returned without reading payloads. It now rechecks and can degrade status.
- Advanced/sensitive flags were not forwarded into manifest entries; shared classification now used by backup and recovery.
- Interrupted resume only iterated previously inventoried entries, omitting files never reached before cancellation. It now walks all selected source trees again. The regression test asserts all six selected files, not just previously recorded entries.
- Resume refused an existing corrupted destination, preventing repair. A new unique payload filename now receives repaired bytes while previous bytes remain available for inspection. Verified generations still refuse resume.
- Resume swallowed destination validation failure and continued. It now fails closed.
- Recovery package flat module layout did not match Entry/UI application-relative loading. It now retains recovery/src/backup; launcher enters GUI using Windows PowerShell STA and authoritative ../manifest.json.

## Test corrections, not implementation proofs

The unfinished worker suite contained contradictory assertions: timestamp generation directly under PITR-Backups AND under computer directory, AppData flag expected without AppData input, copy-failure count used for hash verification failures, repairing a generation after it was already Verified, corruption applied to one generation while rechecking another, and an unused destination.json presumed to prove native same-volume safety. Fixtures/assertions now distinguish these cases. No production guard was removed to turn a test green.

## Remaining limits

Only small synthetic local data was tested. Native Windows behavior, actual PowerShell 5.1, locked active databases, EFS/cloud/ADS/sparse/long-path/ACL cases, NAS disconnects and real PITR remain unverified. Windows CI is required next. No writer-aware VSS requester is implemented; source view is live, not application-consistent. Full backup completion does not by itself establish restore readiness. Exclusive cross-process locks, interruption durability within a large single source, untrusted-manifest defenses across all write paths, and large-data scaling need independent review before release.

Personal folder discovery currently uses conventional subdirectories, not all redirected known-folder registry values. Users must explicitly review Custom paths. Runtime fixture hooks remain a security review gate before release.

## Continuation safety pass (parent-executed)

Both Step-5 Preview reviewers failed with HTTP 429 before any recorded tool calls. No independent safety or spec coverage was delivered.

Parent reproduced and fixed two further defects with RED/GREEN regressions:

- `ManifestPaths.Tests.ps1`: loading accepted `BackupRelativePath=../outside.txt`. Manifest shape now validates provided payload paths, and rooted/UNC relative names are rejected rather than silently stripped. Minimal legacy records without this optional field remain accepted; full schema strictness remains a review gap.
- `RecoveryBoundary.Tests.ps1`: a real directory symlink under the approved root redirected a selected recovery write into a separate outside tree. Recovery now checks every existing destination ancestor before directory creation and before the final swap. The regression confirms refusal/incomplete and no outside write. Windows skips explicitly if its token cannot create the symlink. This does not prove immunity to hostile concurrent filesystem swaps; no handle-based no-follow write primitive is implemented.

The UI backup click also now invokes full verification after CopyCompleted; its production handler is exercised through AST extraction with engine-boundary stubs in `UiBackupFlow.Tests.ps1`. Interrupted copies remain interrupted. Actual WPF event dispatch and rendering remain Windows-gated.

