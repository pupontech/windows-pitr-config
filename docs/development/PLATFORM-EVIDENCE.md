# Platform module evidence

Lane: PITR-05 (profiles, scope, safe path/volume validation). Owned files: `src/backup/Platform.ps1`, `tests/Platform.Tests.ps1`, this file. Nothing else in the repository was modified by this lane.

## Environment

- Host: Linux (Debian, kernel 6.12), non-Windows. `$env:OS` is not `Windows_NT`.
- Engine: PowerShell 7.6.7 (`pwsh`), Linux. Windows PowerShell 5.1 was not executed here.
- No runtime dependencies: the suite dot-sources `src/backup/Platform.ps1` only, uses no Pester/modules/network, and creates all fixtures under `$TMPDIR` with GUID names.

## Commands executed (exact)

```
pwsh -NoProfile -File tests/Platform.Tests.ps1
pwsh -NoProfile -File tools/Test-Source.ps1
```

## Results (this run)

| Command | Exit | Result |
| --- | --- | --- |
| `tests/Platform.Tests.ps1` | 0 | `Platform assertions passed: 171 checks, 5 skipped. Real Windows host: False. Forced Windows host: False.` |
| `tools/Test-Source.ps1` | 0 | `Source parse/encoding checks passed: 15 scripts plus hybrid CMD; 0 test fixture(s) with declared Unicode data; engine 7.6.7.` |

Baseline before this lane: the same suite reported **16 failures** on Linux (`Platform tests failed: 16 of 110 assertions.`). It is now 0 failures on Linux.

Counts describe this invocation only. `Test-Source.ps1` is parent-owned; it is executed, not modified, by this lane.

## What the 16 baseline failures were, and how each is now resolved

Three classes, all real, as stated:

1. Windows-only assertions ran and failed on Linux (native volume identity, drive-qualified OS-volume rejection and unresolvable-fixed-drive refusal, mapped/SUBST/junction/UNC alias handling). These now run only on a real Windows host and are otherwise **skipped with an explicit pending-real-Windows-CI reason**.
2. Three assertions contradicted `docs/development/IMPLEMENTATION-CONTRACT.md` (product authority) and were corrected to the contract, not weakened (details below).
3. A test-only host hook was added so the Windows branches are exercised by fixtures on Windows CI hosts and honestly skipped elsewhere.

## Contract correction (class 2)

`docs/development/IMPLEMENTATION-CONTRACT.md` is authoritative. Three owner-authored assertions contradicted it; the fixtures/expectations were changed to the contract:

1. **Complete scope root count.** Contract: `Get-PitrSourceRoots` scopes data (`Profile`) and personal (`Personal`) for every discoverable profile. With **two** usable profiles the correct count is **4** roots. The old fixture registered three usable profiles and asserted 4, so it failed at 6. The nonstandard-path registration now points at a directory the fixture does not create, so it is exposed as *inaccessible* (exercising the "profile path does not exist on this host" branch) instead of adding a third usable profile. The fixture therefore has exactly two usable profiles (standard + Public) and the assertion is **4** roots, 2 `Profile` + 2 `Personal`.
2. **Public is not folded into another profile.** Contract + TEST-PLAN: Public is its own profile. Export now asserts Public contributes **its own 2 scoped sources** (`Profile` + `Personal`) under the public SID, and that it is never merged into the standard profile. The old assertion of "exactly one source" for Public with Complete was wrong.
3. **A custom source that is an existing Explorer-readable FILE is allowed.** `docs/development/TEST-PLAN.md` lists user-selected files. The old assertion (`custom file source stays refused pending Windows drive-path semantics`) was removed; a new assertion proves a file source is **accepted** with `Category = Extra`, and a **missing** custom file is still refused (with a negative control).

None of these weakened a safety property: refusals for traversal, ADS, device names, rooted names, reparse ancestors, same-volume/OS-volume destinations, nested sources, inaccessible selected profiles and missing custom targets all remain, each with a negative control.

## Test-only host hook

`Get-PitrWindowsHost` (in `src/backup/Platform.ps1`) now returns true when `PITR_FORCE_WINDOWS_HOST=1`, in addition to the real `$env:OS -eq 'Windows_NT'` check. This is a test-only hook: it lets a Windows CI host (or any host with identity fixtures) drive the Windows branches of `Get-PitrVolumeIdentity`, `Test-PitrDestination` and `Get-PitrSourceRoots`. The suite records the **real** host and the **forced** host separately and never reports a forced run as a Windows verification. `PITR_VOLUME_IDENTITY_FIXTURE` (pre-existing) remains the identity-fixture mechanism.

Two host concepts are tracked in the suite:

- `$realWindows` = `$env:OS -eq 'Windows_NT'` — used for assertions that need the real Windows kernel/OS (native volume GUID+serial, drive letters, UNC/mapped/SUBST/junction classification). Skipped with an explicit reason off Windows.
- `$hostIsWindows` = `Get-PitrWindowsHost` — used for Windows *code-path* assertions that fixtures can drive anywhere.

## Negative controls

Every refusal assertion (`Assert-Rejected`) accepts an optional control block. The suite passes a benign input to the same call shape and requires it to succeed, so a probe that refuses everything fails the suite. This was verified by falsification: a block that does not refuse is reported as `expected refusal`, and a refusal whose control also refuses is reported as `negative control also refused`. Both were observed to fail as intended.

## Proven on Linux (this run)

- `Test-PitrSafePath`: traversal, ADS/zone-identifier streams, rooted/UNC/device/verbatim/extended-length relative names, reserved device names (CON/NUL/PRN/AUX/COM1-9/LPT1-9, with and without extension, `CLOCK$`), illegal characters `< > | ? * "` and control characters, over-length components, trailing dot/space, non-existent root, null/empty input — all refused with a passing negative control; ordinary, dot-segment, duplicate-separator, trailing-separator and Unicode-safe paths accepted.
- `Get-PitrVolumeIdentity`: object shape (`Kind/VolumeId/CanonicalPath/FileSystem/AvailableBytes/Warnings`), stability across calls, canonical path vs measured ancestor, explicit non-Windows fallback namespacing (`host-path:`) and its warning text, whitespace refusal, and that a missing descendant's Linux fallback identity is explicitly distinct (not a Windows volume identity).
- `Test-PitrDestination`: empty destination, negative `RequiredBytes`, identical/nested/ancestor source-destination overlap, empty source entry, sibling-prefix non-nesting (`Data` vs `Data-old`), same-fixture-volume refusal, OS-volume refusal via fixture under the forced Windows host, and destination-that-is-also-a-source — each with a passing control.
- `Get-PitrProfiles` / `Get-PitrSourceRoots`: fixture-driven profile exposure (5 registrations, inaccessible rows exposed not omitted), Public identification and placeholder expansion, Complete = 4 roots for two usable profiles, Personal = 2, unique ids, Custom without a folder refused, Custom = only the named paths, distinct ids for distinct paths, empty/missing custom targets refused, a file custom source accepted, and an inaccessible selected profile failing closed.
- Forced Windows host fixture class: the two-fixture-volume distinction, same-volume refusal, distinct-volume acceptance, use of a native identity when no fixture overrides it, fail-closed when neither is available, file-source scoping, and that removing the hook restores real host detection.

## Skipped pending real Windows CI

These are printed by the suite as `SKIP (pending real Windows CI): ...` and are **not** claimed as verified (5 skips in this run):

1. Native stable Windows volume identity (volume GUID + serial via `GetFileInformationByHandle`/`GetFinalPathNameByHandleW`).
2. Unresolvable fixed-drive identity/refusal for a drive-qualified path, plus the drive-root trailing-separator path-form refusal.
3. UNC/mapped-drive/SUBST/junction/mount-point alias classification (`Kind = Network`, `unc:` identity, loopback/127.0.0.1 rejection).
4. Forced-Windows-host native identity query (unavailable on a non-Windows kernel).
5. The forced-Windows-host class as a *real Windows verification* — branch coverage was exercised here; native volume identity, OS-volume aliasing and drive-letter semantics still require a real Windows host.

Additionally skipped only when the host cannot create them (they run on Windows CI): reparse-ancestor refusal and existing-reparse-root refusal via real symlink/junction creation. These did not appear in this run's skip list because the Linux fixtures created working symlinks, so the two assertions executed and passed.

## Remaining limitations and contract ambiguity left

- Windows PowerShell 5.1 was **not** run here. PS 5.1 compatibility is by construction (no `??`, `?.`, ternary, `-notin`-only constructs, no PS7-only cmdlets; `Add-Type` C# is unchanged and PS5.1-valid). Syntax was verified with the PowerShell parser on 7.6.7; a real 5.1 execution remains pending Windows CI.
- All Windows-native behavior above is **pending real Windows CI**. No Linux-only run is presented as proof of Windows behavior.
- Contract ambiguity left as-is (not resolved by me): "Complete default includes hidden data and AppData" (`PROJECT-SPEC.md` §1) is not decomposed into separate source roots; the module treats `Profile` and `Personal` as the two scopes and leaves AppData/hidden inclusion to the inventory lane. The contract does not enumerate the exact Personal-vs-Profile split, so the module keeps the existing two-category split rather than inventing a third.
- The Linux `Get-PitrVolumeIdentity` local fallback keys on the canonical path, so a not-yet-existing descendant reports a distinct identity from its ancestor. That is honest on Linux (there is no volume abstraction) but means the "missing descendant shares the ancestor volume" property is only meaningful on Windows; it is asserted under `$hostIsWindows` and pending real Windows CI where no fixture supplies an identity.

## Ownership

Only `src/backup/Platform.ps1`, `tests/Platform.Tests.ps1` and this file were changed. CLI, entry, tools, CI, docs/scaffolding and other engines were not modified. No git clean/reset/checkout/stash/commit/push was performed. No kanban task was marked complete.