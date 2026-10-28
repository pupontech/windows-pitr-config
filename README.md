# Windows PITR + file backup and restore

**Needs testing.** This version adds file backup and restore to the original PITR tool. Test it with disposable files first and keep an independent backup of anything important.

**Full instructions:** [USER-GUIDE.md](USER-GUIDE.md) - basic and advanced use, all tabs, command line and troubleshooting. A self-contained copy, [USER-GUIDE.html](USER-GUIDE.html), ships in the ZIP.

[Windows verification builds](https://github.com/pupontech/windows-pitr-config/actions/workflows/backup-recovery-ci.yml) · [Historical releases](https://github.com/pupontech/windows-pitr-config/releases)

For the combined three-tab interface, use **1.9.0-test.7** or newer. Download the portable ZIP from a successful matching verification run (`portable-windows-2022-powershell` artifact), or use the exact ZIP supplied with its verification report. Older releases do not contain this repair.

## The original PITR tool

[Stefan (henmedia)](https://github.com/henmedia/windows-pitr-config) wrote the original Windows PITR Config tool. PITR means **point-in-time restore**: Windows can take snapshots of its system drive so you can roll back after a bad update, driver or other change.

The original tool lets you change how often Windows takes those snapshots, how long it keeps them and how much space they can use. It can also request a snapshot now and restart into Windows Recovery to apply one. Your Windows 11 installation must already include PITR; this tool does not install it.

PITR covers the Windows drive, not your other drives. Its snapshots stay on that same drive, so they will not protect you if the drive fails. Some settings use undocumented Windows behaviour and may change after an update. Read the [original author's guide](https://henmedia.github.io/windows-pitr-config/guide.html) for the details.

## What we added

The application now has three distinct steps in one window: **Backup**, **Restore files**, and **Restore points**. The first two keep current files before a rollback and bring selected files back afterwards; Restore points retains the original Windows PITR configuration and recovery controls. Switching tabs keeps your entered paths and does not start any operation.

- All discovered user folders are selected by default. Remove any you do not want, or choose a custom folder.
- Back up to a different volume, preferably an external drive. The tool checks the copied files and reports problems.
- After a rollback, compare your saved backup with the current files and choose what to recover.
- Preview and confirm before restoring. Existing files are kept by default; replacing them is an explicit choice.

This is file recovery, not a system image or an app installer. It does not reinstall programs or perform the Windows rollback for you.

## Start here

1. Download and extract the **whole ZIP**. Keep the `src` folder beside the launchers.
2. Open **START-HERE.cmd** for file backup and restore.
3. Open **pitr-config.cmd** for the original PITR settings and snapshot window. It asks for administrator rights when needed.

Close apps before backing up. The file backup window does not automatically request administrator rights; reading another user's folder may require a separately authorised elevated session.

## Before you trust it

The testing ZIP passed automated Windows 2022/2025 checks with Windows PowerShell 5.1 and PowerShell 7. That does **not** prove a real Windows 11 rollback or every backup scenario works. Live PITR, real screen scaling, open/locked files, cloud folders, encrypted files and network drives still need testing.

A rollback can remove recent files, apps, drivers and updates. Save your work and verify your backup before proceeding. Do not use this as your only backup.

[Testing instructions](TESTING.md) · [Backup and restore guide](docs/BACKUP-RECOVERY-GUIDE.md) · [Report a problem](https://github.com/pupontech/windows-pitr-config/issues)

## Credit and licence

Original PITR Config by Stefan / [henmedia](https://github.com/henmedia/windows-pitr-config). File backup and selective restore additions maintained here by [pupontech](https://github.com/pupontech).

[MIT licence](LICENSE); the original copyright notice is retained. This project is not affiliated with or endorsed by Microsoft.
