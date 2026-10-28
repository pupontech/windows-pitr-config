# Windows PITR + file backup and restore

Two jobs, one window: **configure Windows point-in-time restore** and **back up / restore your files** before and after a rollback.

**[Read the user guide](USER-GUIDE.md)** — basic and advanced use, every tab, both command lines, troubleshooting. The ZIP also contains a self-contained [USER-GUIDE.html](USER-GUIDE.html).

**Testing build.** Start with disposable data and keep an independent backup.

## The three tabs

| Tab | What it does |
|---|---|
| **Backup** | Copies all discovered user profiles (or your chosen folders) to separate storage and verifies the copy. |
| **Restore files** | Finds missing files in a saved backup, previews the restore, and brings back only what you approve. Existing files are kept by default. |
| **Restore points** | The original Windows PITR controls: frequency, retention, storage limit, snapshot now, startup snapshot, restart to recovery. |

Switching tabs keeps your settings and never starts anything. Backup/restore is a file copy, not a system image: it does not reinstall apps or perform the rollback. A rollback can remove apps, drivers and updates installed since the restore point.

## Start

1. Download and extract the **whole ZIP**; keep `src` beside the launchers.
2. Double-click **`START-HERE.cmd`** — one administrator prompt, then the three-tab window.
3. Pick a backup destination on a **different volume**, usually an external drive.

`pitr-config.cmd` opens the same window and is the command-line entry. `pitr-backup.cmd` is an optional file-only window that does not elevate.

## Before you trust it

Automated checks pass on Windows 2022/2025 with Windows PowerShell 5.1 and PowerShell 7, including a real end-to-end file backup and restore on synthetic data. Not proven: an actual Windows 11 rollback, real UAC interaction, live/locked files, cloud/EFS/NAS sources, or physical per-monitor DPI changes. See the guide's limits section.

[CI runs](https://github.com/pupontech/windows-pitr-config/actions/workflows/backup-recovery-ci.yml) · [Testing notes](TESTING.md) · [Backup/restore reference](docs/BACKUP-RECOVERY-GUIDE.md) · [Report a problem](https://github.com/pupontech/windows-pitr-config/issues)

## Credit and licence

Original PITR Config by Stefan / [henmedia](https://github.com/henmedia/windows-pitr-config). File backup and selective restore additions by [pupontech](https://github.com/pupontech).

Written in Windows PowerShell 5.1 with WPF/.NET; no third-party libraries or binaries are bundled, and nothing is downloaded at runtime. [MIT licence](LICENSE), original copyright retained. Not affiliated with or endorsed by Microsoft.
