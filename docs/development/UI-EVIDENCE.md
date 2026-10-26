# UI implementation evidence

Status: development checkpoint, NOT release acceptance.

Parent implementation after both UI delegation routes failed (provider 429; alternate worker blocked by gateway update_paused). No Hermes update or credential change attempted. Standalone Codex CLI installed as a development tool but not used because it is unauthenticated.

## Real executions

`pwsh -NoProfile -File tests/Ui.Tests.ps1` first failed because Ui.ps1 was absent, then passed a real asynchronous STA runspace operation returning a shared result. Next RED: missing XAML provider; GREEN: XAML parses and required control names exist. Next RED: missing Localization.ps1; GREEN: eight primary action labels exist in all ten locale tables and unknown languages fall back to English.

All 12 standalone tests executed as isolated pwsh processes on Linux, each exit 0; captured output: `/root/.hermes/cache/scratch/pitr-suite-results.json`. This is a local evidence path, not an end-user dependency.

## Implemented

Separate WPF backup/recovery window; explicit profile multiselection and scopes; destination browser; backup/full verification workers; manifest selection and full verification; editable explicit SourceId/current-root mappings; deep comparison with virtualized results/search; missing nonadvanced nonsensitive default selection; dry-run and confirmed execution; safe conflict Skip; alternate directory and advanced consent; progress/cancellation through synchronized state and dispatcher timer; guarded close during cancellation; local JSON report export.

Recovery code is packaged under recovery/src/backup so worker module resolution matches normal application layout. Launcher uses Windows PowerShell STA and relative manifest discovery.

## Manifest-context regression (2026-10-25)

Parent review found that changing the manifest left the preceding comparison rows, selected entry IDs, mapping rows and export report in the window. A later recovery click reads the current manifest with those old IDs; IDs are only manifest-local, so selection must not cross backup boundaries.

`tests/UiManifestContext.Tests.ps1` executes the actual production manifest-change, timer and worker-launch scriptblocks extracted through the PowerShell AST. WPF controls and completion handles are inert doubles, not a live Windows UI. The initial test failed for the absent invalidation handler. Subsequent RED runs demonstrated stale progress replacing the new status, obsolete worker exceptions replacing the new status, and manifest publication erasing the newly completed backup report.

GREEN behavior: manifest changes clear rows, selections, mappings and report; increment the active generation; request cancellation of any previous work. Launch captures that generation. The timer ignores obsolete progress, completion and exceptions, but still disposes the old worker and retains single-flight ownership until completion. A completed backup publishes its manifest before retaining its own report, so the invalidation event cannot erase the new report. Current-generation comparisons still publish and select eligible missing files.

Five scratch-only mutations independently removed selection clearing, launch-generation capture, stale-progress protection, stale-completion protection and stale-error protection. Every mutation caused the real regression suite to exit nonzero. Evidence: `/root/.hermes/cache/scratch/pitr-ui-mutation-results.json`.

All 16 standalone suites then ran in isolated Linux pwsh 7.6.7 processes with exit 0. Full outputs: `/root/.hermes/cache/scratch/pitr-resume-final-tests.json`. This does not establish Windows PowerShell 5.1 or WPF event-dispatch behavior for the new change. No commit, push, release or live PITR operation was performed.

## Not verified / not complete

Actual Show-PitrBackupUi event wiring/rendering has NOT been exercised on Windows yet. A Windows-only XAML STA render/show/close smoke is in Ui.Tests.ps1. This test does not exercise all UI clicks. No claim of Windows rendering success is made from XML parsing.

Primary action labels translated into ten languages, machine-produced/unreviewed. Narrative warnings, runtime statuses, tab headers and other text remain English. This does NOT satisfy the full localization acceptance gate.

This is a compact staged form, not yet a polished four-page wizard. Missing: pre-copy size review, speed/ETA, status filters/pagination, conflict choice controls, CSV/text export controls, readiness integration (currently explicitly not assessed), performance measurements for huge result tables and full keyboard/DPI/small-screen acceptance.

No PITR, reboot, snapshot, ACL or ownership action is performed by this window. No release-readiness claim.
