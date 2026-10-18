# UI implementation evidence

Status: development checkpoint, NOT release acceptance.

Parent implementation after both UI delegation routes failed (provider 429; alternate worker blocked by gateway update_paused). No Hermes update or credential change attempted. Standalone Codex CLI installed as a development tool but not used because it is unauthenticated.

## Real executions

`pwsh -NoProfile -File tests/Ui.Tests.ps1` first failed because Ui.ps1 was absent, then passed a real asynchronous STA runspace operation returning a shared result. Next RED: missing XAML provider; GREEN: XAML parses and required control names exist. Next RED: missing Localization.ps1; GREEN: eight primary action labels exist in all ten locale tables and unknown languages fall back to English.

All 12 standalone tests executed as isolated pwsh processes on Linux, each exit 0; captured output: `/root/.hermes/cache/scratch/pitr-suite-results.json`. This is a local evidence path, not an end-user dependency.

## Implemented

Separate WPF backup/recovery window; explicit profile multiselection and scopes; destination browser; backup/full verification workers; manifest selection and full verification; editable explicit SourceId/current-root mappings; deep comparison with virtualized results/search; missing nonadvanced nonsensitive default selection; dry-run and confirmed execution; safe conflict Skip; alternate directory and advanced consent; progress/cancellation through synchronized state and dispatcher timer; guarded close during cancellation; local JSON report export.

Recovery code is packaged under recovery/src/backup so worker module resolution matches normal application layout. Launcher uses Windows PowerShell STA and relative manifest discovery.

## Not verified / not complete

Actual Show-PitrBackupUi event wiring/rendering has NOT been exercised on Windows yet. A Windows-only XAML STA render/show/close smoke is in Ui.Tests.ps1. This test does not exercise all UI clicks. No claim of Windows rendering success is made from XML parsing.

Primary action labels translated into ten languages, machine-produced/unreviewed. Narrative warnings, runtime statuses, tab headers and other text remain English. This does NOT satisfy the full localization acceptance gate.

This is a compact staged form, not yet a polished four-page wizard. Missing: pre-copy size review, speed/ETA, status filters/pagination, conflict choice controls, CSV/text export controls, readiness integration (currently explicitly not assessed), performance measurements for huge result tables and full keyboard/DPI/small-screen acceptance.

No PITR, reboot, snapshot, ACL or ownership action is performed by this window. No release-readiness claim.
