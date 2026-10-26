# Windows PITR Config: User Backup and Recovery

## Authority and project identity
Owner-authorized implementation of the supplied Complete Development Handoff. Upstream: https://github.com/henmedia/windows-pitr-config at a6595a87e0aec337b781a2962218c501bba0a113. Private derived repository: https://github.com/pupontech/windows-pitr-config. Branch: feat/user-backup-recovery. Preserve MIT license, attribution, history, ten languages, existing CLI and configuration/snapshot/WinRE/diagnostic behavior. Do not publish upstream or release assets without owner authorization.

Priority: data safety > correctness/recoverability > regression preservation > usability > comparison/recovery > lightweight design > speed > maintainability. Implementation contract defines module seams, not a reduction of requirements. No OpenSpec executable found; versioned Markdown specs and decision records are the lightweight equivalent.

## Required vertical workflow
1. Discover normal ProfileList profiles (nonstandard paths), Public and selected extra OS-volume folders. Complete default includes hidden data and AppData; Personal and Custom explicitly scoped.
2. Inventory without following junctions or silently omitting inaccessible/unsupported entries. Preserve relative paths and ordinary Explorer-readable files; record stream/link/encryption/cloud/long-path limitations per item.
3. Validate physical/volume identity and writeability of backup destination independently of letter, reject OS-volume aliases, nested sources and insufficient space. UNC classified network with connection/physical-independence warnings. Never save credentials.
4. Create unique independent full backup, manifest and status/log; asynchronous copy, observed progress/cancel/resume, transactional state and SHA256. No destructive Robocopy switches, source deletion, backup overwrite or broad ACL changes.
5. Quick and full verification independently restartable. Verified integrity is not application consistency. Skipped, failed, changed or incomplete inventory forbids strongest success.
6. Include self-contained trusted recovery launcher/code/docs/version/hash inventory outside Windows. No runtime download, dependency on old installed app or drive letters. Manual Explorer recovery always possible.
7. Compare against explicitly mapped current profiles or alternate root. Missing, Different, Identical (hash), LikelyIdentical (metadata), CurrentOnly and Unknown; current-only files always preserved. Never attribute differences categorically to PITR.
8. Recover explicit selection, missing personal files safest default, dry-run CLI by default. No overwrite without explicit consent and preserved current version; hash validate source and destination. Advanced AppData restoration explicit; sensitive startup targets blocked. Reparse/traversal escapes refused.
9. Compact main UI section launches separate responsive four-stage wizard or virtualized/filterable recovery UI. All ten locales, keyboard/DPI/small screens. No automatic PITR, reboots or WinRE modifications from new code.
10. Expose CLI backup/create/verify/resume/list and recover/compare/restore, JSON/text and JSON/CSV/text reports, stable exit codes, no read-only elevation prompts.
11. Readiness accounts for backup integrity/completion/destination/recovery package, restore-point availability (unknown is not ready), user access/BitLocker acknowledgement. Existing Windows recovery remains available regardless.
12. Local logs and privacy warning. No uploads, arbitrary helper downloads, custom crypto, system-wide registry restoration or backed-up executable execution.
13. Owner-required repeatable warnings: explain potential data loss when continuing toward recovery without using the data-backup option; never treat opening the backup window as evidence of protection. Require explicit risk acknowledgement before the existing separate WinRE restart confirmation, with a safe backup/cancel route. Warn on every application launch that rollback can remove/revert installed apps and file backup does not reinstall them; remind users to close apps for live backup. No remembered dismissal; unattended CLI warns without a blocking modal and keeps machine-readable stdout intact.

## Decisions
- Independent full generations first; incremental investigation later, never block full workflow.
- Supported VSS requester/writer lifecycle needs separate proof. Initial live-copy fallback must explicitly classify live consistency and all unavailable/changed files, recommend closing apps, never claim database/application consistency. No VSS mutation allowed without separately verified ownership/cleanup and storage analysis.
- Develop as small testable PS5.1 modules, preserve upstream hybrid CMD. Portable multi-file ZIP acceptable initial packaging; single-file assembly desirable after verified integration. Recovery includes all dependencies.
- Agent Windows verification through GitHub-hosted runners using synthetic disposable file fixtures, never production PITR or VM provisioning. Owner performs live Windows/PITR test. No assertion of a real rollback or broad performance benchmark without measured evidence.

## Acceptance and release gates
Every handoff phase has a Kanban card and task list entry. Engine tests execute real code and hostile-input/refusal cases, not Python reimplementations. Parent reads lane diffs, reruns integrated checks, and obtains independent Security/Spec/Standards reviews. Windows PS5.1 and pwsh execution, actual CMD selftest, artifact extraction and independent recovery launch are mandatory. Record untested Windows 11 PITR, NAS interruption, EFS/cloud behavior, live applications, UI interactions and scale/performance honestly. Deliver local versioned ZIP only after verified gates; release publication remains owner-gated.
