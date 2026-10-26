# Documentation continuation evidence — PITR-11

Date per session context: 2026-10-25. Scope: documentation-only lane; owned files are the three documents listed below. Current-tree Windows verification is pending.

## Work completed

- Added `docs/BACKUP-RECOVERY-GUIDE.md`: user instructions separate the manually operated existing PITR rollback from this independently operated live-file backup/recovery feature; cover scope, destination, live consistency, package launcher, Explorer recovery, mapping, comparison, dry-run/selective recovery, conflict behavior, privacy and limitations.
- Added `docs/development/BACKUP-SCHEMA-REPORTS.md`: schema/report reference and acceptance-gap matrix tied to the implementation contract and source modules.
- This evidence file records source-grounding and command verification status.

## Source grounding

Read first: `docs/development/PROJECT-SPEC.md`, `IMPLEMENTATION-CONTRACT.md`, and `RESUME-CHECKPOINT.md`.

Inspected `src/backup/Entry.ps1`, `Cli.ps1`, `Platform.ps1`, `Backup.ps1`, and `Recovery.ps1`. CLI syntax in the guide matches parser/help source: backup create with `--destination`, `--scope`, `--profile`, `--folder`; verify/resume/list; recover compare/restore with explicit `--mapping`, `--entry`, optional `--deep`, `--alternate-root`, `--dry-run`/`--execute`, `--conflict`, `--allow-advanced`, `--format`, and `--output`. Scope behaviors were checked against `Get-PitrSourceRoots`; package layout and launcher claims against `Install-PitrRecoveryPackage` and launcher/readme text; lifecycle and report claims against engine functions and `Entry.ps1`.

## Commands and actual results

- `pwsh -NoProfile -File src/backup/Entry.ps1 --help` — NOT RUN: terminal policy blocked script execution (`BLOCKED: Command flagged as dangerous ... single-query mode`). No claim is made that CLI help was executed. The exact options above were cross-checked against `Get-PitrCommandHelp` and `ConvertFrom-PitrCommandLine` source. Parent can rerun the help command in an approved interactive context.
- No engine tests run in this documentation lane. No Windows or PowerShell 5.1 verification was performed. No full suite was run.
- No measurements, performance claims, actual rollback, restore, snapshot, reboot or external system change were performed.

## Limits / open blockers

- Current-tree Windows PowerShell 5.1/pwsh, Windows 11 behavior, actual launcher execution/extracted package, real PITR, redirected folders, cloud/EFS/ADS, NAS interruptions, live applications, UI interactions, scale and performance remain unverified as identified by project checkpoint/spec.
- Concurrent UI lane still has conflict/filter/report-control work; documentation describes stable engine/CLI behavior, not completed GUI acceptance.
- README/changelog integration, independent security/spec reviews, board/task closure and final integration/verification are parent-owned and remain open.
