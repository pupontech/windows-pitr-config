# PITR-09 UI recovery controls evidence (partial)

Status: bounded implementation in progress; parent integration and Windows verification pending.

## Scope

Owned files only:
- `src/backup/Ui.ps1`
- `tests/UiRecoveryControls.Tests.ps1` (new)
- `docs/development/UI-CONTROLS-EVIDENCE.md` (this file)

No engine semantics, localization file, existing tests/evidence, manifest rules, generation protections, single-flight handling or cancellation logic were intentionally changed.

## Implementation

- Added a comparison classification filter (All, Missing, Different, Identical, LikelyIdentical, CurrentOnly, Unknown) alongside path search.
- Maintains explicit selected entry IDs separately from displayed rows. Filtering only changes visible rows; it restores selections for visible selected IDs and does not select hidden/new rows. User selection changes update IDs only for currently visible rows. Manifest path changes clear rows, selection IDs, mapping/report context and increment the existing generation.
- Added explicit conflict selector Skip / Alongside / Replace; XAML default is Skip. The same selected choice is forwarded through preview/dry-run and execute worker arguments to the existing Restore-PitrFiles `-Conflict` parameter.
- Execute confirmation names the selected conflict policy. Replace confirmation explicitly says the existing file is preserved in a unique conflict store before the backup copy is written. This UI does not implement replacement semantics; the existing recovery engine owns them.
- Added JSON / CSV / Text report selection, matching save-file extensions, and forwards the selected format to existing Export-PitrReport. Existing privacy notice says reports contain private filenames, and success status reiterates this.

## Focused test intent

`tests/UiRecoveryControls.Tests.ps1` parses Ui.ps1 and exercises extracted production AST bodies for filtering, manifest invalidation, recovery callback/worker forwarding, and the export worker. It checks XAML defaults, each conflict choice for dry-run and execute worker calls, selection retention/non-broadening, and Replace confirmation disclosure. It is a standalone test; it does not launch WPF.

## Execution evidence and blocker

Requested pre-implementation RED and post-implementation GREEN could not be captured in this environment. Both attempts to execute the focused test were blocked by the terminal's unattended single-query safety gate; no PowerShell test process ran and no config/approval workaround was attempted:

`pwsh -NoProfile -File tests/UiRecoveryControls.Tests.ps1`

Result each time: `BLOCKED: Command flagged as dangerous (script execution via -e/-c flag) but single-query mode (-q) runs without a user present to approve it.`

Thus AST parsing, assertions, real RED/GREEN, and PowerShell version behavior remain unverified here. This is an explicit skip/blocker, not a passing test claim.

`git diff --check` completed with exit code 0. It printed only existing Git LF-to-CRLF conversion warnings for unrelated dirty files. No full suite was run.

## Pending

- Run `pwsh -NoProfile -File tests/UiRecoveryControls.Tests.ps1` in an approved environment; record actual RED/GREEN output and fix any failures.
- Execute UI/event wiring on Windows PowerShell 5.1 and verify WPF rendering, selection retention, classification filtering, confirmation, report save dialogs, keyboard access, DPI and small-screen layout. These remain pending; Linux/static tests cannot establish WPF behavior.
- Parent owns integrated verification, broader suite, review, board/task closure and final acceptance.
