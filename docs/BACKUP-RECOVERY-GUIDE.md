# User backup and recovery guide

Status: implementation documentation for the current development tree; not a release or Windows verification claim. Backup/recovery is separate from the existing Windows PITR rollback workflow. This feature never starts a restore point rollback, changes WinRE, or reboots the computer.

## Simple screens

Extract the whole ZIP and launch **pitr-backup.cmd**.

### Back up files

1. Choose a folder on separate storage, preferably an external drive. The Windows volume is refused.
2. All discovered user profiles and the supported Public folder are included automatically. Use **Change folders** only to exclude users. **Advanced backup options** holds Personal/Custom scopes and additional paths; review redirected/cloud locations separately.
3. Click **Start backup**. Full verification follows automatically. **Backup verified** means the recorded copy passed the checks, not that apps are consistent or PITR is ready. A cancelled/incomplete/problem result must not be treated as full protection. **View details** shows warnings and errors.

### Restore files

1. Choose the dated backup generation folder with **Choose backup folder**. You do not need to locate the manifest file. The tool checks the backup before showing folder suggestions.
2. Review the two-column folder table and tick **These are the correct folders for these users**. Whole-profile suggestions require an exact Windows account SID match; names and old paths are not used as identity proof. Enter destinations for unmatched, Personal or Custom sources yourself. Then click **Find missing files**.
3. Missing ordinary personal files are selected automatically; AppData and executable/startup content are not. Review the selection, click **Preview restore**, inspect **View details**, then click **Restore selected files** and confirm. No files are written by the preview. Changing files, mappings, conflict policy, alternate location or advanced consent requires a new preview.

Existing files are kept by default. Replacement, recovery alongside existing files, AppData consent, alternate folders, search/filters and direct manifest controls are under **Advanced restore options**. Reports are under **Details and reports**. Read every warning: incomplete scans, skipped files and errors are not silently turned into success. Problem rows remain visible in details even when routine rows are truncated.

The source CLI and safety limitations below remain available for advanced use. Live Windows/PITR acceptance and the limitations in TESTING.md remain separate from automated fixture tests.

## Before a PITR rollback

1. If Windows still runs, save work and close applications that may be writing files, especially databases, mail clients, browsers, and document editors. The backup reads the live filesystem; it does not create a VSS snapshot and is not application/database consistent. A file can change during capture.
2. Use **Backup Before Restore**, choose separate storage and the required data, complete the backup and run full verification. Inspect every skip/error, confirm the recovery launcher is available, and check that you can access the media and any BitLocker keys. Merely opening the backup window does not confirm protection. If you choose not to use the data-backup option, current files or newer changes may be lost in the rollback.
3. Only after reviewing the backup and recovery limitations, run the existing PITR rollback separately using its existing interface and normal Windows recovery guidance. The backup tool does not schedule, perform, or confirm that rollback.
4. Once Windows is available, use the backup recovery comparison to inspect what is currently present. A difference is only an observed difference; it is not proof that PITR caused it.

**Application warning on every run:** rollback can remove or revert apps, drivers and updates installed since the restore point. You may need to reinstall or repair apps. File backup does not preserve installed applications or reinstall them. Close apps before live backup. There is no remembered "do not show again" dismissal.

The main window repeats a data-backup warning before every **Restart to recovery** attempt because it has not established current backup readiness. **No** (the default) opens Backup Before Restore; **Cancel** stays in the main window; **Yes** acknowledges the risk and reaches the separate restart confirmation. Opening or cancelling the backup window never authorizes a restart. The separate backup/recovery window carries a persistent app warning; CLI warnings use stderr so JSON output stays parseable.

Do not use this tool as a substitute for a tested independent backup. Keep the destination on independent storage where possible. A network destination is not necessarily physically independent and can be unavailable.

## Create and verify a backup

The portable entry point is `pitr-config.cmd`; CLI modes run without launching the GUI. Discover exact options with:

    pitr-config.cmd --help

Examples (quote paths containing spaces):

    pitr-config.cmd backup --destination "E:\PITR-Backups" --scope all-users
    pitr-config.cmd backup --destination "E:\PITR-Backups" --scope personal --profile "S-1-5-..."
    pitr-config.cmd backup --destination "E:\PITR-Backups" --scope custom --folder "C:\Data"
    pitr-config.cmd backup verify --manifest "E:\PITR-Backups\...\manifest.json" --verification full
    pitr-config.cmd backup resume --manifest "E:\PITR-Backups\...\manifest.json"
    pitr-config.cmd backup list --destination "E:\PITR-Backups"

The backup GUI initially selects **all discovered profiles**, not just the signed-in user. Folder paths are shown in the list; click a selected folder to exclude it. Removing one folder leaves the others included. Removing every profile prevents a Complete/Personal backup rather than silently selecting them again. Unreadable registrations remain included and block backup until resolved or explicitly excluded. Custom scope remains an explicit-path-only choice. The CLI also defaults to all discovered profiles unless `--profile` narrows the selection.

`all-users` maps to Complete. Complete selects discovered ProfileList profiles, including Public, and inventories the profile tree; that includes hidden content and AppData when accessible. Inaccessible registered profiles fail selection rather than disappearing silently. Personal selects existing conventional Desktop, Documents, Downloads, Pictures, Videos, Music, Favorites and Saved Games folders. It is not a guarantee of every user's personal data: redirected folders, nonstandard locations and cloud-managed content require review and may need explicit Custom selections. Custom uses only the paths or profile SIDs explicitly selected; it does not silently include every profile. Review source warnings and the manifest inventory.

A destination must pass physical/volume identity, writeability, source overlap and capacity checks. Do not choose the operating-system volume or a nested source. UNC/network destinations carry connection and physical-independence caveats. No credentials are saved. Each backup is a unique generation; existing backup generations are not overwritten.

Create returning means copying ended, not integrity verification. Run full verification and inspect the final state, warnings, counts, `backup-log.txt`, and `manifest.json`. Quick verification is not the strongest verification. Any skipped, failed, changed, cancelled, or unknown item prevents a claim of complete verified success. Hash integrity does not prove application consistency or that an application can use restored data.

## Launch recovery independently

Keep the backup generation and its `recovery` directory together. The recovery directory contains `Start-Recovery.cmd`, README, the trusted application PowerShell modules, and `recovery-integrity.json`. The launcher locates the generation manifest relative to itself; it does not use a fixed drive letter or network download. The integrity inventory detects accidental changes but is not a digital signature. If the package is missing or damaged, use Explorer or another trusted application source; do not treat it as a valid recovery package.

Run `recovery\Start-Recovery.cmd` to open the recovery UI where supported. The current UI is still under development; controls and wizard flow are not all complete. A GUI comparison may require explicit source mapping. Never approve a guessed profile mapping.

## Compare, map, preview, and recover selectively

Map a manifest source ID to the intended current profile directory explicitly. First inspect source IDs in the manifest; do not substitute display names. Comparison is read-only by default:

    pitr-config.cmd recover compare --manifest "...\manifest.json" --mapping "SOURCE-ID=C:\Users\Name" --deep --format json --output "C:\Reports\comparison.json"

Deep comparison hashes both current and backed-up files. Without `--deep`, matching size and timestamp is only `LikelyIdentical`, not a content proof. Classifications are Missing, Different, Identical, LikelyIdentical, CurrentOnly and Unknown. `CurrentOnly` content is shown for awareness and never becomes a recovery target. Differences are not attributed categorically to rollback.

Select explicit entry IDs and preview before authorizing writes:

    pitr-config.cmd recover restore --manifest "...\manifest.json" --mapping "SOURCE-ID=C:\Users\Name" --entry ENTRY-ID --dry-run
    pitr-config.cmd recover restore --manifest "...\manifest.json" --alternate-root "C:\Recovered" --entry ENTRY-ID --dry-run

Restore is dry-run unless `--execute` is supplied. Default conflict policy is `skip`. `--conflict alongside` writes a separate restored copy; `--conflict replace` preserves the current file before replacement. Execute only after reviewing the selected entries, destination and report. There is no implicit overwrite. Recheck hashes and warnings. AppData is advanced content and requires explicit `--allow-advanced`; recovering it to an alternate folder is preferable. Sensitive executable/script/shortcut/startup targets are blocked from live-profile restoration and should not be executed from backup data.

An alternate root must already exist and must not be a reparse point. Mapped roots must be explicitly approved existing directories. Recovery validates relative paths and rejects traversal, unsafe Windows names and reparse-point escapes. Files are copied as ordinary readable content; backup is not a system-state or application installer.

Reports can be JSON, CSV or text (`--format`; use `--output` for CSV). Reports and logs can reveal private paths, names and content metadata. Store and share them accordingly; the application does not upload them.

## Limits

The engine does not preserve/reconstruct registry state, ACLs, ownership, alternate data streams, hard-link relationships or sparse allocation. Reparse points are not followed. EFS bytes may be unreadable without the correct keys; cloud placeholders may not be hydrated. Long/unsupported names, inaccessible objects, source changes and filesystem/provider errors may be skipped or failed and must be reviewed in the manifest. A live copy is not a point-in-time snapshot. No automatic image restore, PITR, reboot, WinRE modification, credential storage, backed-up executable launch, or broad system restore is performed.

Explorer manual recovery is always possible: browse `profiles/<source-id>/` or `extra-folders/<source-id>/` in the generation, inspect the file, and copy the chosen ordinary file to an appropriate destination. Keep current files; prefer copying alongside rather than replacing. Do not execute recovered files merely because they came from a backup.
