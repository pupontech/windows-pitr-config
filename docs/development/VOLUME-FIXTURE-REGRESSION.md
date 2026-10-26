# LUNA-01 volume-fixture regression evidence

Status: regression test added; execution outcome pending the focused PowerShell attempt below. No production file or existing test was changed.

## Concern and expected reproduction

`Get-PitrVolumeIdentity` currently reads `PITR_VOLUME_IDENTITY_FIXTURE` before its native Windows query (Platform.ps1 around 416-425). An inherited JSON fixture can therefore replace the `VolumeId` for a genuine Windows path. `Test-PitrDestination` relies on `VolumeId` equality to reject same-volume sources (around 502-503) and to reject the OS volume (around 506-512). `PITR_FORCE_WINDOWS_HOST` and `$env:OS` also influence the OS decision in `Get-PitrWindowsHost` (around 333-340), so neither is a trustworthy shipped security boundary.

`tests/VolumeFixtureBoundary.Tests.ps1` is standalone and PS5.1-compatible. On Windows it reads the native identity of the current Windows directory, sets a fixture claiming a forged identity for that same canonical path, and requires the second identity to remain native or fail closed. It only queries identity; it does not probe/write a destination. On non-Windows it checks that a spoofed `$env:OS=Windows_NT` cannot make the actual-runtime OS decision report Windows, then confirms Linux synthetic volume fixtures remain usable. That Linux branch is explicitly not evidence of Windows native identity behavior. Current Linux-run fixtures are created only under `/root/.hermes/cache/scratch`; the Windows branch selects the runner's external system temp directory because `/root` does not exist there. Both branches remove their unique fixture roots in `finally`.

## Existing tests requiring adaptation if Windows fixtures are denied

- `tests/Platform.Tests.ps1:265-270` uses a fixture to make `Data` and `Data-old` appear to be separate volumes so it can reach ancestor-boundary assertions. Keep these fixtures for non-Windows synthetic tests; on Windows use real distinct volumes where needed or restructure the assertions so volume identity does not pre-empt the path-boundary case.
- `tests/Platform.Tests.ps1:272-293` expects `PITR_VOLUME_IDENTITY_FIXTURE` to replace identity and sets `PITR_FORCE_WINDOWS_HOST=1` plus a spoofed `$env:SystemRoot` to simulate OS-volume rejection. The “fixture overrides” expectation is specifically invalid on Windows. Test native system-volume identity read-only on Windows, and retain the simulated fixture/OS branch only in a non-Windows fixture lane that is clearly not Windows proof. `SystemRoot` must not be test-controlled for a shipped OS-volume decision.
- `tests/Platform.Tests.ps1:436-477` forces Windows branches and maps fixture paths to fabricated distinct IDs. These synthetic distinct-volume checks cannot run as Windows security-decision tests once fixture overrides are denied. Preserve synthetic coverage on non-Windows, and use actual separate volumes or a harness-only injected adapter isolated from shipped decisions for Windows branch tests. Do not expose an inherited environment bypass.
- `tests/BackupCli.Tests.ps1:64-76` passes a volume fixture into child CLI processes and labels the profile and destination as separate volumes even though fixtures are co-located under one test root. On Windows the same-volume CLI path should be rejected natively. Adapt the Windows end-to-end destination to a genuinely independent volume (if available), or split platform-independent CLI coverage from Windows native-volume acceptance; do not weaken the native gate to preserve the fixture expectation. Profile-list fixtures are separate hooks and are not the volume-identity issue.

## Minimal suggested production patch (report only; parent owns implementation)

1. Detect Windows from runtime platform (`[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT`, compatible with Windows PowerShell 5.1), not `$env:OS`. The fixture force switch must not decide a shipped safety branch. If Windows branch testing needs forcing, use an explicit internal harness seam that is not inherited into the CLI/product process and cannot change production identity decisions.
2. On a genuine Windows runtime, never consult environment-provided volume fixtures for a local identity. Query the native handle-based identity first; if unavailable/empty, preserve the existing fail-closed behavior and throw `Local volume identity could not be verified natively; refusing to guess: <path>`. A fixture must not rescue that failure. Keep synthetic fixtures only for the non-Windows fixture path, with no claim that they model native Windows semantics.
3. Ensure `Test-PitrDestination`’s OS-volume identity is based on the real Windows system directory/runtime, not a spoofable environment path or OS flag, before same-volume/OS-volume security decisions.

Native route in the current code is `[Pitr.WindowsNative]::QueryIdentity($resolved)`, with `FinalPath` for canonical resolution. Its current intended failure behavior is refusal when no native local `VolumeId` is available; the regression must preserve that behavior rather than falling back to an environment fixture or host-path guess.

## Execution evidence

- Test file written: `tests/VolumeFixtureBoundary.Tests.ps1`.
- Focused attempt: `pwsh -NoProfile -File tests/VolumeFixtureBoundary.Tests.ps1` was blocked before execution by the unattended terminal policy: `BLOCKED: Command flagged as dangerous (script execution via -e/-c flag) but single-query mode (-q) runs without a user present to approve it.` No policy/config workaround was attempted. This is not test output; no RED/GREEN or pass/fail result is claimed.
- Windows native identity proof: not available from a Linux run; remains pending a real Windows execution.
