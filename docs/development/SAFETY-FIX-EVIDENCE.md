# Safety-fix integration evidence

Status: fixes implemented and locally exercised; NOT Windows/release acceptance or independent post-fix clearance.

## Worker contribution

Three actual gpt-6-luna CLI lanes generated new regression suites and focused source-review notes for volume fixture identity, replacement transaction rollback, and payload containment. They owned only new tests/reports, not production. Their attempted pwsh execution was blocked by unattended approval policy; they did not establish RED/GREEN. Parent executed the suites and owns all production changes in this pass. Pre-pass snapshot: `/root/.hermes/cache/scratch/pitr-safety-fixes/before-safety-fixes.tar.gz`.

## Reproduced and fixed

### LUNA-02: replacement rollback

Parent executed the real Restore-PitrFiles fixture with a process-local hash override that throws only after the replacement reaches its final pathname. RED: original bytes were not back at the original destination. Recovery.ps1 now includes final verification in the replacement transaction. On failure it retains the failed replacement at a separate unique conflict path and puts the preserved current bytes back. If a competing directory blocks rollback, the original stays in its preservation path and the failed action reports both paths plus the rollback error. New action fields: FailedPath and RollbackStatus (NotNeeded/Restored/Failed). Parent extended the real fixture to prove the blocked-rollback branch and preserved original bytes. GREEN: RecoveryTransaction.Tests.ps1 passes. No real user path was restored.

### LUNA-03: linked payloads

Parent corrected worker-fixture issues (PowerShell's read-only IsWindows variable, cross-platform scratch root, profile payload namespace) before treating failures as evidence. The real fixture then showed external linked bytes classified Different and actually restored despite a matching manifest hash; parent-directory full verification could claim Verified. Resolve-PitrPayloadPath in Manifest.ps1 now validates relative syntax, canonical containment, generation/ancestor and leaf attributes, refusing reparse paths. Verify, resume revalidation/adoption/copy and comparison/recovery hash/open paths use the resolver. Static checks are repeated at sensitive reads/writes but do NOT prove race-free immunity against hostile concurrent link/hardlink swaps; there is no Windows no-follow handle implementation.

Additional RED: Quick re-verification retained FullVerified on a linked payload after a previous full verification. Failed checks now degrade VerificationStatus regardless of mode. GREEN: BackupPayloadBoundary.Tests.ps1 passes 20 assertions with 0 skipped on Linux, including leaf/parent links, quick/full verification, comparison, restore refusal, unchanged outside/current bytes and resume. Windows now attempts disposable link creation and records explicit privilege/support skips when unavailable; that branch has not run here.

### LUNA-01: ambient Windows identity override

RED: spoofing env:OS made Get-PitrWindowsHost report Windows on Linux. Native Windows detection now uses the actual runtime platform, and inherited volume fixtures are refused on genuine Windows. Native local identity failure still refuses; OS-volume checks use the runtime Windows directory, not env:SystemRoot, and fail closed when identity is unavailable. Only non-Windows synthetic coverage retains force/fixture hooks, clearly not Windows proof.

GREEN locally: VolumeFixtureBoundary.Tests.ps1 passes its 2 Linux assertions. Its genuine-Windows branch checks environment spoofing and fixture resistance, but remains unexecuted. Existing Platform synthetic-volume classes are restricted to non-Windows; native tests remain separate. The forced Linux class now explicitly supplies a synthetic OS identity rather than relying on a failed OS lookup being ignored. Windows BackupCli fixtures now place destination media in RUNNER_TEMP rather than fictitiously assigning a second volume to an OS-volume directory. Exact Windows matrix execution is mandatory before accepting those fixture adaptations.

## Integrated verification

Parent ran every discovered tests/*.Tests.ps1 as a separate Linux pwsh 7.6.7 child process: **21 suites passed, 0 failed**. Native-dependent skips remain explicitly printed (including WPF rendering); Linux results are not Windows evidence. Full outputs: `/root/.hermes/cache/scratch/pitr-safety-fixes/integrated-results.json`. Existing repeatable safety warnings remain covered by their 32-assertion suite. git diff --check passed.

Three scratch-only negative controls were rejected (each focused suite exited 1): remove payload reparse guards; remove replacement rollback; restore environment-based OS detection. Results: `/root/.hermes/cache/scratch/pitr-safety-fixes/mutation-results.json`. These prove those regression suites depend on the critical production guards, not that all hostile concurrency/native Windows behavior is covered.

## Still gated

No independent post-fix Security/Spec PASS; no exact-current-tree Windows PS5.1/WPF/CMD/portable run, live PITR, scale/NAS/cloud/EFS acceptance or complete narrative localization. Wider manifest strictness/provenance gaps from LUNA-SAFETY-REVIEW.md remain open. No commit/push/release, VM, live restore, snapshot mutation or credential change was performed. Source fixes must not be described as release-ready just because local suites pass.
