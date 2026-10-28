# Windows PITR + Backup and Restore - User Guide

Version 1.9.0-test.8 (testing build). This guide ships inside the ZIP as `USER-GUIDE.md` and `USER-GUIDE.html`.

Point-in-time restore (PITR) is a Windows feature that keeps snapshots of the system drive so you can roll back after a bad update, driver or app change. This tool configures it and adds a separate file backup/restore workflow so you can keep current files before a rollback and bring selected files back afterwards.

Nothing here replaces a tested independent backup. Start with disposable data.

---

## 1. Start here

1. **Extract the whole ZIP** to a normal local folder. Keep `START-HERE.cmd`, `pitr-config.cmd`, `pitr-backup.cmd` and the `src` folder together. Running a launcher from inside the ZIP or without `src` will fail.
2. **Double-click `START-HERE.cmd`.** Windows asks for administrator rights once, because the window contains the Windows PITR configuration. Accept it.
3. You get **one window with three tabs**:
   - **Backup** - save current files to separate storage.
   - **Restore files** - bring selected files back from a saved backup.
   - **Restore points** - the original Windows PITR configuration and recovery actions.

Switching tabs never starts an operation and never grants permission: entering a path, opening a tab or closing the window does not prove a backup exists, does not approve a restore and does not authorize a reboot.

**Other ways to start**

| Launcher | What it does |
|---|---|
| `START-HERE.cmd` | Combined three-tab application (asks for admin once). |
| `pitr-config.cmd` | Same combined application. Also the command-line entry point. |
| `pitr-backup.cmd` | Optional standalone file backup/restore window. Does **not** elevate. |
| `recovery\Start-Recovery.cmd` (inside each backup) | Independent recovery launcher for that backup. |

**Safety in one paragraph.** A rollback can remove or revert apps, drivers and updates installed since the restore point, and you may have to reinstall them. A file backup is a live copy, not an application-consistent image: close apps, expect open databases and mail stores to be inconsistent, and keep BitLocker keys and recovery media somewhere else. Do not use this tool as your only backup.

---

## 2. Basic use

### 2.1 Back up files

1. Open the **Backup** tab.
2. Under *Where should the backup be saved?* click **Choose folder...** and pick storage on a **different volume** than Windows and your source data - preferably an external drive. Same-volume destinations are refused. Network shares are allowed but carry connection and independence warnings.
3. Leave the folder list alone the first time: every discovered user profile and the Public folder are included by default.
4. Click **Start backup**. Verification runs automatically afterwards; you do not need a second step.
5. Read the status line:
   - **Backup verified** - copied bytes match the recorded hashes.
   - **Backup finished with problems** / **cancelled** - some files may not be protected. Click **View details** and read every skip and error.
6. Keep the whole generated backup folder, including its `recovery` subfolder. Ordinary files are still readable in Explorer without this tool.

"Verified" means the copy is internally consistent. It does **not** mean applications are consistent, and it does not prove PITR readiness.

### 2.2 Restore files

1. Open the **Restore files** tab and click **Choose backup folder...**. Choose the dated backup generation folder - the one containing `manifest.json`, not its parent and not the `recovery` folder.
2. The tool checks the backup, then suggests a current folder for each backed-up source. Suggestions require an **exact Windows account identity (SID)** match; names and old paths are not used as identity proof.
3. Check the two-column table. If a row is blank, type the correct current folder. Tick **These are the correct folders for these users**.
4. Click **Find missing files**. Missing ordinary personal files are selected automatically; AppData, scripts and technical rows are not.
5. Click **Preview restore**. Nothing is written; the preview proves exactly which files would change.
6. Review **View details**, then click **Restore selected files** and confirm the dialog. The confirmation defaults to **No**. Existing files are kept by default.

Changing the selection, mappings, conflict policy, alternate folder or advanced consent invalidates the preview - preview again before restoring.

### 2.3 Restore points (the Windows feature)

The **Restore points** tab shows the original tool's view of the PITR engine:

- **Current state** - whether this Windows supports PITR (supported / incomplete / not present), Windows edition, last and next scheduled run, task state, recovery-environment (WinRE) availability, storage used, the oldest point, and the existing restore points with their time, age, status and build.
- **Settings** - *Active*, *Frequency*, *Retention* and *Storage limit*, each shown as currently effective together with its source (this tool's policy value, Intune/MDM, the Settings app, or the Windows default).
- **Apply** - save changed settings. They take effect on the next scheduled run, and that run only happens when Windows is idle.
- **Apply and run now** - save, then trigger a run immediately.
- **Create snapshot now** - ask for a restore point right away without changing settings.
- **Reset everything** - remove every value this tool wrote and return to the Windows default.
- **Copy state** - copy edition, settings with sources, task status and restore points as plain text, for a bug report.
- **Restart to recovery** - reboot into WinRE, where a restore point is applied. Unsaved work in other programs is lost. A warning appears first; **No** (default) switches to the Backup tab, **Cancel** stays, and **Yes** reaches a separate restart confirmation.

The tab also offers ten interface languages, a link to the original author's PITR guide and a project-page link. An update notice appears when a newer release exists; this tool never downloads or installs anything automatically.

If the tab reports *not present in this Windows*, everything that writes is disabled and the tool is read-only. PITR arrives with Windows updates, so a pending cumulative update can still add it.

---

## 3. Advanced use

### 3.1 Backup scope and exclusions

Under **Change folders** you can click a selected user folder to exclude it. Unreadable registrations stay included and block backup until resolved or explicitly excluded; excluding every profile prevents a Complete or Personal backup rather than silently re-selecting them.

Under **Advanced backup options**:

| Scope | Meaning |
|---|---|
| **Complete** | Entire profile trees of discovered ProfileList profiles plus Public, including hidden content and AppData where readable. |
| **Personal** | Existing conventional personal folders: Desktop, Documents, Downloads, Pictures, Videos, Music, Favorites, Saved Games. Not a guarantee for redirected or cloud-managed content. |
| **Custom** | Only the absolute paths you list, one per line. |

Redirected folders, OneDrive/cloud placeholders, EFS-encrypted files, alternate data streams, long paths and inaccessible files are reported per item rather than silently skipped. Review those warnings: the strongest success state is refused while any item is skipped, changed or unknown.

### 3.2 Backup destination rules

A destination must pass volume identity, writeability, source-overlap and capacity checks. The Windows volume, a nested source, and aliases of either are refused. UNC/network destinations are classified as network with connection and physical-independence caveats. No credentials are stored. Every backup is a unique generation; existing generations are never overwritten.

### 3.3 Advanced restore controls

Inside **Advanced restore options**:

- **Conflict policy** - *Skip* (default: keep the existing file), *Alongside* (write a separate copy), *Replace* (preserve the current bytes first, then replace). Re-preview after changing it.
- **Optional alternate recovery folder** - restore into an existing inspection folder instead of the live profile. Preferred for executable or startup content.
- **Advanced AppData consent** - required before AppData content can be selected; close applications first.
- **Search and classification filter** - narrow the results list (All, Missing, Different, Identical, LikelyIdentical, CurrentOnly, Unknown).
- **Open manifest...**, **Check backup again**, **Reload folders**, **Compare all files** - direct manifest work, re-verification, refreshed SID suggestions, and full comparison instead of the missing-files shortlist.

Restoring into a live profile is refused for sensitive startup targets. A comparison result is an observed difference; it is never proof that PITR caused it.

### 3.4 Reports and privacy

**Details and reports** holds the running status plus **Save report** in JSON, CSV or text. Reports contain private filenames and paths - keep them local and review before sharing. No credentials are saved and nothing is uploaded. The CLI emits warnings on stderr so JSON stays parseable.

### 3.5 Command line - Windows PITR configuration

Run from an elevated prompt. `apply`, `snapshot` and `autostart` need administrator rights and do not self-elevate; without them they exit 5. `selftest` and `idle` need no rights and write nothing.

```
pitr-config.cmd selftest
pitr-config.cmd --help
pitr-config.cmd apply freq=4h reten=5d size=20g active=on
pitr-config.cmd apply status
pitr-config.cmd apply reset
pitr-config.cmd apply freq=default
pitr-config.cmd snapshot
pitr-config.cmd autostart on delay=5m [copy]
pitr-config.cmd autostart off
pitr-config.cmd autostart status
pitr-config.cmd idle
pitr-config.cmd noupdate
```

| Option | Range / meaning |
|---|---|
| `freq` | 60m to 24h - interval between restore points. |
| `reten` | 1d to 7d - lifetime of a restore point. |
| `size` | 2g to 50g - storage limit for all points together. |
| `active` | `on` or `off` - the feature itself. |
| `reset` | Remove every value this tool wrote. |
| `status` | Print effective values; writes nothing. |
| `default` | As a value (`freq=default`) removes that single override. |

`autostart on` registers a SYSTEM scheduled task that creates a point a few minutes after every boot, because Windows' own startup request waits for an idle system. `delay` accepts 1-60 minutes. Add `copy` when the tool sits on a network share: the task cannot reach your share as SYSTEM, so it copies itself to ProgramData first. `autostart status` warns when that copy is missing or stale.

`idle` reports whether Windows ever reaches the idle state every restore point depends on. It returns 2 when the idle state is blocked system-wide, which makes it usable from monitoring. From an unelevated prompt it sees fewer scheduled tasks and says so.

`--help`, `help`, `-h` and `/?` print usage and exit without opening a window. A bare double-click opens the GUI.

### 3.6 Command line - file backup and recovery

```
pitr-config.cmd backup --destination "E:\PITR-Backups" --scope all-users
pitr-config.cmd backup --destination "E:\PITR-Backups" --scope personal --profile SID
pitr-config.cmd backup --destination "E:\PITR-Backups" --scope custom --folder "C:\Data"
pitr-config.cmd backup verify --manifest "...\manifest.json" --verification quick|full
pitr-config.cmd backup resume --manifest "...\manifest.json"
pitr-config.cmd backup list --destination "E:\PITR-Backups"
pitr-config.cmd recover --gui --manifest "...\manifest.json"
pitr-config.cmd recover compare --manifest "..." --mapping "SOURCE-ID=C:\Users\Name" --deep
pitr-config.cmd recover restore --manifest "..." --mapping "SOURCE-ID=C:\Users\Name" --entry FILE-ID --dry-run
pitr-config.cmd recover restore --manifest "..." --entry FILE-ID --alternate-root "D:\Inspect" --execute
```

- `--conflict skip|alongside|replace` (default `skip`); `replace` preserves current bytes.
- `--allow-advanced` permits selected advanced content; prefer `--alternate-root`.
- `--format json|text|csv` and `--output PATH` export a local report.
- Restore is a dry run unless `--execute` is present, and requires explicit `--entry` selection plus an approved `--mapping` or `--alternate-root`.
- Options are single-use except `--mapping`, `--entry`, `--profile` and `--folder`.

Exit codes: `0` complete, `2` warnings/incomplete, `3` invalid input or operation failure, `4` verification failure, `5` missing explicit recovery authorization or selection.

### 3.7 Independent recovery package

Each backup generation contains a `recovery` folder with `Start-Recovery.cmd`, a README, the trusted application modules and `recovery-integrity.json`. Copy the **whole generation** to accessible media; the launcher finds its manifest relative to itself and never depends on a drive letter or a download. The integrity inventory detects accidental corruption, not tampering - it is not a digital signature. If it is missing or damaged, use Explorer or another trusted copy of this application instead.

### 3.8 Startup automation, idle and task history

- The **At every system start** checkbox registers the startup snapshot task; the adjacent list chooses 1, 2, 5, 10, 15 or 30 minutes after boot.
- The idle-check button reports whether Windows still reaches idle. If it does not, no scheduled point can be created regardless of settings.
- The task-history button enables the Task Scheduler operational log, which is what the *last run* result is read from.
- **Copy state** produces a plain-text summary suitable for a forum post or bug report.

### 3.9 Files in the package

| File / folder | Purpose |
|---|---|
| `START-HERE.cmd`, `pitr-config.cmd`, `pitr-backup.cmd` | Launchers described above. |
| `src\backup\*.ps1` | File backup, restore, manifest, platform and UI modules. Required. |
| `docs\BACKUP-RECOVERY-GUIDE.md` | Backup/restore reference with CLI detail and limitations. |
| `docs\guide.html` | The original author's PITR guide, ten languages, offline copy. |
| `USER-GUIDE.md`, `USER-GUIDE.html` | This guide. |
| `README.md`, `TESTING.md`, `CHANGELOG.md`, `LICENSE` | Overview, test instructions, history, MIT licence. |
| `package-integrity.json` | SHA-256 inventory of every packaged file. |

There is no installer: delete the extracted folder to remove the tool. Values already written to the PITR policy key remain until you use **Reset everything** (or `apply reset`), and a registered startup task remains until you switch it off.

### 3.10 Troubleshooting

| Symptom | Action |
|---|---|
| Window does not open | Double-click `START-HERE.cmd` with no arguments and read the console - it now stays open on failure. Check that `pitr-config.cmd` and `src` are beside it. |
| "Administrator rights were not granted" | The tool asked once and stopped. Re-run and accept the UAC prompt. |
| Settings show "not present in this Windows" | This build lacks PITR. Everything that writes is disabled; a pending Windows update may still add it. |
| No restore points are created | Check *Current state*: task state, next run, WinRE and idle. Run `pitr-config.cmd idle` from an elevated prompt. |
| Backup refuses the destination | Choose storage on a different physical volume, not a nested folder, not the Windows drive. |
| Restore folder suggestion is blank | Enter the correct current folder manually and tick the approval box. Exact account identity cannot be inferred. |
| Restore refused after changing something | Preview again; the previous preview no longer matches your selection. |
| Which build am I running? | The window subtitle shows the version; `pitr-config.cmd apply status` prints it too. |

---

## 4. Limits of this testing build

Verified by automated Windows 2022/2025 runs with Windows PowerShell 5.1 and PowerShell 7: source parsing, the behaviour suites, real WPF composition of the three tabs, a synthetic end-to-end backup/preview/confirmed-restore cycle, native launcher startup, and package integrity. That is not proof of the following, which remain your own test gates:

- Real UAC approval or cancellation on your account.
- Live Windows 11 PITR support, snapshot creation, or an actual rollback.
- Physical per-monitor DPI changes (layout is simulated at several logical scales).
- Live applications and locked files, cloud/EFS/NAS sources, disconnects and very large data sets.
- Safety against a hostile process changing paths while the tool runs.

The Windows PITR configuration values are undocumented by Microsoft and may change in a future release; **Reset everything** always returns to the Windows default. The file workflow does not create VSS snapshots, does not reinstall applications, does not perform the rollback and never reboots; the Restore points tab keeps the original confirmed WinRE restart action.

Interface languages: the Restore points window is fully translated into English, German, Dutch, French, Spanish, Portuguese, Italian, Polish, Ukrainian and Czech. Backup/Restore primary actions are translated; some explanatory backup text and this guide are English.

Original PITR Config by Stefan / henmedia. File backup and selective restore additions maintained by pupontech. MIT licence; the original copyright notice is retained. Not affiliated with or endorsed by Microsoft.
