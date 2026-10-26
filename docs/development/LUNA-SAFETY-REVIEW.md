# PITR-12 preliminary independent safety review — Luna

Status: preliminary; no broad PASS. Read-only source review of Manifest.ps1, Backup.ps1, Platform.ps1, Recovery.ps1, Entry.ps1, Build-Portable.ps1 and engine-facing tests. UI intentionally excluded. Review is on the current checkout; Windows behavior is unverified from this Linux host. Findings are being recorded incrementally.

## Findings

### LUNA-01 — High — runtime fixture environment variable can falsify volume identity

Location: `src/backup/Platform.ps1:347-355, 416-420`; consequence at `src/backup/Platform.ps1:502-503, 511-512`.

`Get-PitrVolumeIdentityFixture` is loaded from `PITR_VOLUME_IDENTITY_FIXTURE` without a test-host/test-process gate. `Get-PitrVolumeIdentity` consults that fixture before its native Windows identity branch and uses the returned value as `VolumeId`. `Test-PitrDestination` then accepts two local paths if those attacker-/ambient-controlled IDs differ and relies on identity equality to reject a same-volume source/destination. On Windows an inherited environment variable can therefore substitute fabricated identities for the native handle-based identity and bypass the primary same-volume / OS-volume rejection. This affects a security decision in shipped code, even though the fixture is documented as test-only.

Concrete control-flow proof: for any canonical paths present as properties in the fixture JSON, `override` is assigned at lines 418-420; the `elseif ($onWindowsHost -and $nativeAvailable)` native query at line 422 is skipped. The resulting forged `$identity.VolumeId` is compared at lines 502 and 511. This was not yet exercised on Windows; no claim of Windows repro.

Fix: make fixture injection impossible in ordinary shipped execution (e.g. explicit internal test seam enabled only by a harness-owned, non-inherited process-local setting with an additional non-Windows/test assertion; safest is remove the environment-variable production path and inject a test function/fixture in isolated tests). Never let untrusted environment data override native identity on Windows. Regression: set the legacy environment variable to claim different IDs for source and destination on one real Windows volume, call `Test-PitrDestination`, and assert same-volume rejection; separately prove tests still cover fixtures without weakening production identity.

### LUNA-02 — High — failure after replacement swap does not restore current file to its original path

Location: `src/backup/Recovery.ps1:467-479, 481-484`.

Replace moves the existing destination to the conflict store (470-472), moves the staged restore into the destination with rollback only if that move throws (473-474), then performs a post-install hash check (478). If that final check fails (e.g. destination bytes change between move and verification, storage error/corruption, or adversarial concurrent writer), the outer catch marks the action Failed but does not move the preserved current file back. Its bytes remain under `PreservedPath`, but the requested original pathname now contains unverified restore bytes, violating rollback-on-failure semantics and potentially disrupting the live application.

Fix: treat preservation, installation and final verification as one transaction. On any failure after moving the existing file, remove/quarantine the failed new target and move the preserved file back; if rollback itself fails, report both paths and an explicitly incomplete recovery state, never imply the original location is restored. Regression: inject a deterministic post-swap verification failure in a scratch fixture, then assert the original bytes are restored at the original path and the staged/temp artifact is handled. No production source was changed and no such failure was injected yet.

## Spec / standards gaps (not verdicts)

- The contract requires untrusted schema/type/uniqueness/path validation (`IMPLEMENTATION-CONTRACT.md:16-19, 33-36`). `Assert-PitrManifestShape` currently checks entry IDs and relative-path syntax but does not establish source-ID referential integrity, unique/collision-free normalized payload paths, or that each `BackupRelativePath` belongs to its declared `SourceId` namespace. Audit these invariants before treating arbitrary imported manifests as safe recovery input.
- `Test-PitrBackup` and `Compare-PitrBackup` construct payload paths by joining a root and manifest `BackupRelativePath` (Backup.ps1:961; Recovery.ps1:132). Syntax validation blocks lexical traversal, but the relevant restore/compare/verify paths should consistently enforce canonical containment and reparse-ancestor checks against the generation root, not merely rely on the relative-path parser. Verify adversarial pre-existing symlink/reparse payload locations on Windows.
- Build/package checksums are integrity inventories, not authenticated provenance. The builder computes hashes from the same input tree it packages (`Build-Portable.ps1:23-36`); a replaced source plus regenerated inventory is not detected. This is correctly disclosed as no signature in package metadata, but does not establish trusted recovery code when the source/media itself is untrusted.

## Scope, evidence, and limitations

- Sources reviewed: `src/backup/Manifest.ps1`, `Backup.ps1`, `Platform.ps1`, `Recovery.ps1`, `Entry.ps1`, `tools/Build-Portable.ps1`, plus engine test inventory. UI not reviewed by instruction.
- No files outside this new review report are owned or modified. No restore/PITR/snapshot/reboot, VM, install, upload, credential use, or Windows claim.
- Focused standalone tests, fixture repro attempts, explicit skips, and further findings will be appended below as evidence is obtained.

### LUNA-03 — High — verification/comparison/restore follow reparse payloads outside the generation

Location: `src/backup/Backup.ps1:961-973`; `src/backup/Backup.ps1:829-841`; `src/backup/Recovery.ps1:132-150, 184-197, 369-380, 457`.

The manifest path parser rejects lexical traversal, but these consumers join the resulting relative name to the generation and test/hash/open it without checking that the resolved payload itself (or any existing ancestor below the generation) is not a reparse point. `File.Exists`, `Get-PitrHash` and the restore input stream follow file symlinks. Thus a generation containing `profiles/<id>/file` as a symlink to a file outside the generation can be reported present and hashed as if it were stored backup content; a correspondingly authored/tampered manifest can make Full verification accept it, and explicit restore then reads those external bytes. This violates the boundary that an untrusted backup path must resolve to payload physically contained in the generation. Windows junction/reparse behavior requires real Windows confirmation; Linux symlink fixture is a possible focused repro but was not run because execution was blocked (see below).

Fix: centralize a generation-payload resolver that validates the relative path, canonical containment under the actual manifest directory and every existing component (including leaf) against reparse points immediately before every read/hash/copy; use it in verify, resume, compare, and restore. Where Windows handle-based final-path validation is required, fail closed if unresolved. Regression: create a scratch backup root and a payload symlink/junction to an outside file, construct a minimal manifest pointing to it, and assert verification cannot return Verified, comparison returns Unknown/incomplete, and restore refuses without reading/writing through the link.

## Focused execution attempt / explicit skips

Attempted separate processes for `tests/ManifestPaths.Tests.ps1`, `tests/RecoveryBoundary.Tests.ps1`, `tests/Recovery.Tests.ps1`, and `tests/Backup.Tests.ps1`. All were blocked before execution: the unattended terminal policy rejected `pwsh -NoProfile -File ...` as script execution; an alternative via `execute_code` was also blocked because arbitrary local execution is disabled in this session. Therefore there is no RED/GREEN output and no test result. No fixture repro was executed. This is an environment/tooling blocker, not a pass or test failure. No Windows PowerShell 5.1, Windows kernel, junction, volume alias, or CMD verification was performed.
