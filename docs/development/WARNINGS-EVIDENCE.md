# Repeatable safety warnings and Luna continuation

Status: development implementation, not a release or Windows acceptance.

## Owner-required warning behavior

- The original main window displays an app-impact warning on each normal GUI launch, with no persisted dismissal. Rollback may remove/revert apps, drivers and updates; app repair/reinstallation can be necessary. File backup does not preserve/reinstall installed apps. Close apps before live backup.
- Before every Restart to recovery attempt, the window states that no current verified backup has been confirmed. Skipping Backup Before Restore can lose current data/newer changes. Merely opening that window is not evidence of protection. The warning always repeats because readiness is not established by this window.
- No (default) opens the backup window and returns without rebooting; Cancel returns without rebooting; Yes reaches the separate restart confirmation, also defaulting to No. No new image-restore operation was added.
- The separate backup/recovery window has a persistent bold app warning on every launch. New CLI modes emit the warning on stderr (including help); machine-readable stdout stays unchanged. Original headless Apply/Snapshot/AutoStart/Idle modes also emit an app warning on stderr without prompting.
- New main-window strings currently use English fallback for the other locales; backup-window narrative text remains English. Full ten-language narrative coverage remains pending, not silently declared complete.

## Actual RED/GREEN and scope

`pwsh -NoProfile -File tests/SafetyWarnings.Tests.ps1` first failed for missing Show-PitrApplicationWarning, then passed the initial 19 assertions after the main-window gate. Further RED runs showed absent independent-window banner, absent CLI warning, and absent legacy CLI warnings. Final GREEN: 32 assertions. Tests execute production helpers and WinRE click callback with inert message/process boundaries; actual CLI children run twice against an empty test-owned directory and confirm stderr warning plus valid JSON stdout. Legacy warning branches execute through AST extraction with a captured stderr writer. No actual shutdown or PITR occurs. Windows WPF rendering/message-box overload behavior remains unverified.

## Parallel worker outputs and parent corrections

Three actual `gpt-6-luna` sessions ran via explicit `openai-codex` session overrides on luna/luna2/luna3; the named profile defaults were Step-5 and were not changed. Session model identity was checked in each profile's state.db. Workers delivered UI controls/tests, new user/schema documentation, and preliminary read-only engine review. Their PowerShell execution attempts were blocked by unattended policy, so child summaries provide no executed-test clearance.

Parent ran all 18 discovered suites in isolated Linux pwsh 7.6.7 processes. Initial run: 16 passed, 2 failed. Fixed production selection enumeration of generic lists; updated the manifest-context harness to execute the newly required production filter callback; repaired the new controls harness to initialize production SelectedIds and execute inner worker bodies rather than return scriptblocks. Focused controls/context suites passed. Final full run: 18 suites passed, 0 failed. Native Windows-dependent assertions still print explicit skips. Results: `/root/.hermes/cache/scratch/pitr-luna-continuation/final-test-results.json`. `git diff --check` passed; main hybrid CMD retains CRLF. All pre-worker inventoried files remain present.

CLI help was executed by the parent; worker documentation examples are consistent with that help. Parent corrected the user-guide sequence to explicitly back up and verify BEFORE the manually operated rollback.

## Release blockers retained

The preliminary Luna review identifies volume-identity fixture injection, failed replacement rollback and reparse payload boundaries as High concerns. These have source/control-flow evidence, not parent-confirmed repros or fixes in this continuation. Green suites do not retire those findings. See LUNA-SAFETY-REVIEW.md; reproduce and fix before release. Latest-tree Windows PS5.1/WPF/CMD/portable verification, complete localization/readiness/wizard acceptance and owner live PITR/data-scale gates remain open. No commit, push, release, global Hermes repair, VM or live recovery operation was performed by the parent. Existing dirty work was preserved under `/root/.hermes/cache/scratch/pitr-luna-continuation/pre-workers.tar.gz` before dispatch.
