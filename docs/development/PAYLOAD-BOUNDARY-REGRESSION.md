# LUNA-03 payload-boundary regression

Status: regression-first artifact written; execution blocked before PowerShell started. No RED/GREEN claim. Production files were not edited.

## Scope and fixture

Standalone test: `tests/BackupPayloadBoundary.Tests.ps1`. It dot-sources the actual Platform, Manifest, Backup and Recovery functions; creates manifest-backed generation fixtures plus an external file and approved restore destination only under `/root/.hermes/cache/scratch`; then exercises full verification, deep comparison, executed selected restore and resume. The manifest hash is computed from the outside file and therefore intentionally matches the linked payload bytes. It covers a linked payload leaf and a linked parent directory. Resume's destination-volume gate alone is stubbed so the real resume and payload handling can be exercised without triggering unrelated platform volume policy; no payload reads/writes are stubbed. Link fixture setup failures emit explicit SKIP lines. Real Windows link behavior is explicitly SKIP pending a link-capable Windows fixture. Assertions accumulate and throw on failure.

Expected protected behavior asserted:

- Full verification does not reach `Verified`.
- Deep comparison marks the payload `Unknown` and the report incomplete.
- Selected executed restore explicitly refuses (not merely skips as identical) and does not alter the approved destination or outside bytes.
- Resume refuses or records the linked payload damaged rather than adopting it based on a matching outside hash, and does not alter outside bytes.

The supplied manifest hash exactly matches the external target. That is intentional: matching hash proves the bytes currently reachable through the link, not that they are stored inside the generation.

## Execution evidence

Attempted exactly:

`pwsh -NoProfile -File tests/BackupPayloadBoundary.Tests.ps1`

Result: blocked before execution by unattended terminal policy: `BLOCKED: Command flagged as dangerous (script execution via -e/-c flag) but single-query mode (-q) runs without a user present to approve it.` No test assertion ran; no fixture was created; no deterministic RED or GREEN output exists. Do not bypass policy. Parent should run the focused script under approved PowerShell execution and inspect the actual result.

The earlier safety review also records the same unattended-script restriction for the other suites. This report does not claim any suite passed or failed at runtime.

## Minimal proposed production change (report only)

Add one shared helper, preferably in `Manifest.ps1` (loaded before Backup and Recovery):

`Resolve-PitrPayloadPath -BackupRoot <actual generation directory> -RelativePath <manifest BackupRelativePath>`

It should validate the manifest-relative syntax using the existing safe-relative parser; canonicalize the actual generation root and candidate; require strict containment with a path-component boundary; reject a reparse root; inspect every existing path component below the root, including the leaf, and reject any reparse point; fail closed on inaccessible, dangling, unresolved or otherwise ambiguous components. It should return the canonical child path only after checks. For TOCTOU-sensitive reads, revalidate immediately before opening; ideally open the payload with handle semantics that prevent a swapped link/reparse target between check and open. Do not accept a missing component as safe when the operation needs it to exist. Parent creation for writes must similarly validate the destination root and each existing/new parent before creating directories or the payload file.

Consumers needing this helper include:

- `Backup.ps1` resume revalidation: path join, `File.Exists`/`Directory.Exists`, `FileInfo.Length` and `Get-PitrHash` around lines 829-846. Resume's later `Invoke-PitrBackupEntry` must not hash/adopt an existing linked destination (around 368-382); destination and partial-file creation/rename paths must validate ancestors before writing (around 384-428).
- `Backup.ps1` full/quick verification: payload join, existence, `FileInfo` and hash around lines 961-985.
- `Recovery.ps1` comparison: payload join and missing-file test around lines 132-150; deep backup hash around lines 184-197. Invalid payload should produce `Unknown`, an error/warning, and `ScanComplete/Complete = false`; do not classify from the external bytes.
- `Recovery.ps1` selected restore: backup hash around lines 367-380 and the backup input stream around line 457. Resolve/validate before either hash/open, then revalidate at open. A boundary failure must take a refusal path before creating destination directories or temporary files.

Restore's destination-side path checks (`Assert-PitrRecoveryPath`) protect writes into the approved current/alternate root; they do not validate the independent backup payload path. Keep those destination checks and apply the payload resolver to backup reads. Do not silently change unrelated status/log/recovery-package file behavior in this focused patch.

## Files

- `tests/BackupPayloadBoundary.Tests.ps1` — new standalone regression suite.
- `docs/development/PAYLOAD-BOUNDARY-REGRESSION.md` — this evidence and proposed patch note.

No production source, existing WIP, or other lane files were modified. No restore was performed against live data; the test itself only targets GUID-named scratch fixtures if actually run.
