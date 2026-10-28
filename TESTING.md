# Windows PITR backup/recovery testing build

This is a testing build, not a claim that every possible bug or live recovery scenario has been proven safe. Do not start with your only copy of important data. Keep an independent, tested backup. The new file-backup/recovery subsystem does not start a system/image restore or reboot; the original main window retains its separate confirmed Restart to recovery action.

## Start here

1. Extract the entire ZIP to a normal local folder. Keep **START-HERE.cmd** and its `src` folder together.
2. **START HERE: double-click START-HERE.cmd** to open the backup/restore window. The old `pitr-backup.cmd` launcher still works. This entry does not self-elevate. If your account cannot read another profile, use a separately authorized elevated console; never bypass ACLs.
3. First test with a small disposable Custom folder. Choose a backup destination on a different volume from Windows and your selected source, preferably independent external storage. Same-volume destinations are intentionally refused. Review all skips and errors; success must include full verification, not just copied bytes.
4. In a disposable copy of your current-data folder, change/delete test files. Select the generated manifest, approve the explicit SourceId mapping, and run deep comparison. Preview selected recovery before Execute. Existing files are kept by default. Replace is explicit and preserves the current version; recovery reports must be inspected.
5. Test the backup generation's `recovery/Start-Recovery.cmd` after moving the generation to accessible media. Keep its entire generation directory intact. Ordinary files remain readable in Explorer even without this tool.

See **docs/BACKUP-RECOVERY-GUIDE.md** for detailed scope, commands, limitations and manual recovery.

## If the window does not open

Double-click **START-HERE.cmd** without arguments to open Backup and Recovery. `--help` deliberately prints command help instead. Keep the entire extracted `src` folder beside the launcher; running the CMD file alone or directly inside the ZIP is unsupported. A failed no-argument startup now keeps its console open until you press a key, so the actual error can be read. Explicit CLI commands never pause. Copy the visible error text when reporting a startup failure; do not send private backup manifests or filenames unless needed.

## Warnings are deliberate

- Skipping Backup Before Restore can lose current files/newer changes during rollback. Merely opening the backup window does not prove that a verified backup exists. The main window repeats a warning before Restart to recovery; No opens backup, Cancel stays, and Yes reaches a separate restart confirmation.
- Rollback can remove or revert apps, drivers and updates. You may need to repair/reinstall apps; a file backup does not reinstall applications. This warning is shown each run, without a remembered dismissal.
- Save work and close apps before backup. This is a live file copy, not a VSS/application-consistent capture. Databases and active profiles may be inconsistent even when copied bytes pass hashes.
- Reports contain private filenames and paths. Keep them local and review before sharing. No credentials are saved or uploads performed by the backup/recovery subsystem.

## Limits that remain owner-test gates

Current Windows runner results and the exact source SHA are supplied with the ZIP in the external verification report. A Windows Server CI pass is not live Windows 11 PITR proof. Real rollback, full WPF interactions, live app/locked files, redirected/cloud/EFS/ADS data, NAS disconnects and large data volumes remain separate acceptance tests. Narrative UI/warning text is not yet translated in every language. Restore readiness is explicitly not assessed; verify recovery media access, the recovery package, restore-point availability and BitLocker keys separately. Static link checks do not establish safety against a hostile concurrent filesystem writer.

Do not treat a missing-file comparison as proof that PITR caused the difference. Restore only explicitly reviewed files. Never restore executable/startup content directly into a live profile; use an alternate inspection folder where permitted.
