# Comparison and recovery evidence

## What was executed
- `pwsh -NoProfile -File tests/Recovery.Tests.ps1` -> `Recovery assertions passed.` (Linux, PowerShell 7.6.7).
- Full local suite for comparison, all on Linux pwsh:
  Cli, Entry, Launcher, MainIntegration, Manifest, Recovery, Performance, Platform (171 checks, 5 skipped, Windows-only) and Source: all PASS.
  `Backup.Tests.ps1` was still failing in the backup lane's own work at the time of this record; it is not this module's evidence and its failure was in progress there.

## What the recovery suite actually establishes
A real backup-shaped fixture (manifest plus `profiles/src-1/...` payload written by `Manifest.ps1`) is compared and recovered against a separate "current installation" tree:
- Classification: a file absent from the current installation is `Missing`; equal size and equal recorded timestamp is `LikelyIdentical` (explicitly not proof of identity); different bytes are `Different`; deep mode proves `Identical` by hash and records that content was verified; a file only on the current installation is `CurrentOnly` with no backup source.
- Mapping is mandatory: with no approved current location nothing is classified, `Complete` is false and a warning says so. A mapping for an unknown source id is ignored and reported.
- AppData content is flagged advanced, executables/scripts/startup names are flagged sensitive.
- Recovery refuses: an empty selection; no mapping and no alternate root; a non-existent alternate root; an entry that exists only on the current installation (`PreserveCurrentOnly`); an unclassified entry (`RefusedUnknown`); a backup copy whose bytes no longer match the manifest hash (`RefusedBackupChanged`, discovered by tampering with the payload after the backup finished); advanced content without explicit consent (`SkipAdvancedNotPermitted`); executable content inside a live profile (`RefusedSensitive`).
- Dry run writes nothing. Recovering a missing file produces bytes that hash-match the backup and is recorded as `FullVerified`. Nested relative structure is preserved.
- Conflicts default to keeping the existing file. `Alongside` writes the backup bytes next to it and leaves the current file untouched. `Replace` is only performed when explicitly chosen, preserves the previous bytes first, and restores them if the swap fails.
- Advanced and executable content can be recovered into an approved alternate root.
- A manifest whose entry path escapes upward is refused at read time.
- A cancelled comparison reports `Complete = false` and says it was cancelled.
- Reports: JSON keeps schema and counts; CSV has eight escaped columns and neutralises spreadsheet formula prefixes in file names; text report is written. No temporary report or restore files are left behind.

## Defects this suite found and fixed (all in reviewed code, not the tests)
1. `Get-PitrComparisonEntry` declared `[string]$CurrentSha=[string]$BackupSha` with no `BackupSha` parameter, so a caller's `-BackupSha` value was silently mis-bound and the row carried a wrong hash. Fixed by declaring the parameter.
2. `Alongside` recovery moved the existing file out of the way, so the user's current file disappeared. Fixed: only an explicit `Replace` preserves and swaps; `Alongside` leaves the current file exactly as it was.
3. Deep comparison compared the current file against the hash recorded in the manifest and never checked the backup copy itself, so a tampered payload still classified as `Identical`. Compare now detects the mismatch (`Unknown`, `Complete = false`), and restore independently verifies the backup copy before deciding anything.
4. A shallow comparison compared a JSON-round-tripped timestamp string to a formatted value; timestamps are now compared as instants.
5. `Write-PitrManifest` called `File.Replace(..., $null)` and PowerShell converts a null argument to an empty string, so the second write to an existing manifest threw. It now passes a real backup path and deletes it. The manifest suite gained the missing regression (rewrite an existing manifest, no `.bak`/`.tmp` left behind).

## Not verified (must not be claimed)
- Real Windows PowerShell 5.1 runtime behavior, real ACL-denied files, locked files, long paths, Unicode names, ADS, hardlinks, cloud placeholders, EFS.
- Actual PITR rollback and any post-restore comparison against a real reverted Windows installation.
- WPF recovery UI: the comparison/recovery engine has no GUI yet, so no interactive selection, filtering or mapping editor has been exercised.
- Large-scale comparison performance; only synthetic fixtures of a handful of files were measured.
