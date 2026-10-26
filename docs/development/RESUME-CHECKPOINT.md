# PITR resume checkpoint — 2026-10-25

## Repository and authority

- Checkout: `/root/Projects/windows-pitr-config`, branch `feat/user-backup-recovery`, HEAD `0ce2fe0`.
- Private derived repository: `https://github.com/pupontech/windows-pitr-config`.
- Product authority: `PROJECT-SPEC.md` and `IMPLEMENTATION-CONTRACT.md` in this directory; milestone map: `TASKS.md` and Kanban board `windows-pitr-config`.
- Preserve all existing dirty changes. No reset/clean/stash/checkout/commit/push, upstream publication or release is authorized by this checkpoint. No VM provisioning or live Windows PITR operations.

## Proven in this continuation

All 15 pre-existing behavior suites passed in isolated Linux PowerShell processes before changes. Parent review identified a manifest-context selection bug in the WPF recovery window and fixed it in `src/backup/Ui.ps1` with `tests/UiManifestContext.Tests.ps1`. See `UI-EVIDENCE.md` for RED/GREEN, exact scope and limits.

All 16 suites passed afterward under Linux pwsh 7.6.7. Outputs: `/root/.hermes/cache/scratch/pitr-resume-final-tests.json`. Five scratch-only mutations of the UI fix were rejected by the real regression test: `/root/.hermes/cache/scratch/pitr-ui-mutation-results.json`. `git diff --check` passed (line-ending conversion warnings are not test failures).

The test executes production callback bodies with inert control/completion doubles. It proves invalidation of stale rows, selected IDs, mappings and reports; stale progress/completion/error rejection; resource cleanup; current-result publication; new-backup report retention; and generation capture/single-flight launch. It does not prove actual WPF event wiring or Windows 5.1 behavior.

## Previous Windows evidence — NOT evidence for the new fix

Read back GitHub Actions run `39133847368`: success at full commit `19506caba4852fa03f6e664f43b7c474d16dcffc`.

https://github.com/pupontech/windows-pitr-config/actions/runs/39133847368

That is an older verification branch commit, not current feature HEAD or the current dirty tree. Do not describe the current UI fix as Windows-verified. No new CI run was triggered because project rules prohibit commit/push.

## Remaining acceptance work

1. **UI (PITR-09):** full ten-language coverage (currently primary action buttons only), readiness assessment (currently explicitly unknown), pre-copy size review, speed/ETA, result status filters, conflict-choice controls, additional report-format controls, keyboard/DPI/small-screen and large-table evidence. The current window is a staged form rather than a finished four-page wizard.
2. **Documentation (PITR-11):** owner-facing backup/recovery guide and README/changelog integration, schema/report documentation and measured performance scope. Existing upstream download badges do not deliver this private development implementation.
3. **Independent review (PITR-12):** neither prior Security nor Spec reviewer produced a verdict; they failed with HTTP 429. Parent regression testing is not independent clearance. No reviewer was spawned in this continuation.
4. **Exact-current-tree Windows verification (PITR-13):** needs an authorized commit/push path before the existing 2022/2025 × powershell/pwsh workflow can verify this change. The workflow dynamically discovers the new test. Retain all extracted-package/CMD checks.
5. **Owner gates (PITR-14/15):** real live Windows/PITR, cloud/EFS/NAS/scale and full UI interaction remain unproven. Release/upstream publication remains explicitly owner-gated.

No milestone is complete solely from this checkpoint. Existing engine fixtures under untracked `profiles/` and `extra-folders/` are not shipping inputs; inspect before any future staging. `tools/Build-Portable.ps1` uses explicit application inputs, not a repository-wide archive.

## Later continuation — actual Luna workers and owner warning requirement

Three actual gpt-6-luna CLI workers delivered bounded recovery UI controls, user/schema docs, and a preliminary safety review. Parent integrated the owner-required no-backup recovery confirmation and app warning on every launch, corrected controls/harness execution defects, and ran all 18 standalone suites with exit 0 under Linux pwsh. See `WARNINGS-EVIDENCE.md` for real RED/GREEN, warning surfaces, exact output path and limitations. This supersedes the 16-suite local count above, not the remaining Windows/release gates.

The three High concerns now have parent-applied source fixes and real local regression evidence in `SAFETY-FIX-EVIDENCE.md`: replacement rollback through final verification, static payload reparse-boundary checks, and native-Windows isolation from environment identity fixtures/runtime OS spoofing. All 21 suites passed locally; three scratch-only guard mutations were rejected. Native Windows validation and independent post-fix clearance remain mandatory, and hostile concurrent path swaps are not solved by static checks. Wider manifest strictness/provenance gaps remain open. New warning narratives currently use English fallback; full localization and Windows WPF rendering remain pending. No commit/push/release authorized or performed.

## Repeatable local verification

Run each `tests/*.Tests.ps1` as its own `pwsh -NoProfile -File <path>` child and inspect each actual child exit code. Do not assume a combined `-Command` loop ran all suites merely because its first source-check script printed success. Count discovered suites programmatically and retain outputs.

Build only into a new scratch output directory to avoid the builder's intentional refusal to replace different bytes under one version. Rehash every `package-integrity.json` member and inspect the extracted artifact; inventories detect corruption, not an adversary replacing code and inventory together. A Linux development ZIP is not a Windows-verified owner delivery.
