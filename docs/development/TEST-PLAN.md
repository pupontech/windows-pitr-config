# Verification and acceptance gates

No synthetic result is evidence of real PITR rollback. Windows-hosted CI is agent execution; live Windows GUI/PITR/cloud/NAS/application behavior remains explicitly separate owner validation. Do not provision VMs.

## Unit and boundary tests
Run standalone tests/*.Tests.ps1 in fresh processes on Linux pwsh (portable logic) and Windows PowerShell 5.1 + pwsh (required). Cover registry profile discovery with fixtures, source scope filtering, canonical containment, volume alias rejection, root overlap, manifest strict schema/version/type/duplicate/corruption, hashing/mutation, honest state transitions, interruption/resume validation, explicit mapping, six comparison classifications and completeness, safe missing-only recovery, advanced data guard, conflict preservation, cancellation and report escaping. For new behavior capture failing RED then passing GREEN.

## Disposable Windows CI fixtures
Use job-specific temporary directories and a temporary secondary volume/VHD only if runner supports it with explicit teardown. Never snapshot/reboot/restore hosted OS. Execute actual CMD selftest and CLI from artifact extracted into paths with spaces, apostrophes, brackets and Unicode. Compare preserved upstream function behavior and ten-language XAML/control selftests. Validate OS-volume rejection including SUBST, junctions, mount points and mapped local network aliases. Validate hidden/AppData/empty directories, large streamed files, locked sharing violation, denied paths, long names/paths, junction/symlink cycles, alternate streams, Unicode, cancellation/resume, corrupted backup/manifest and preserved overwrite conflicts. Driver/cloud/EFS dependencies that cannot be exercised must be skipped with exact reason, never PASS.

Independent recovery package must be tested outside original application tree with original source unavailable. Verify manifest inventory/hash, perform missing/different/current-only fixture compare, explicit dry-run, recover selected missing content, byte compare, and prove unrelated current files unchanged. Malicious path entries and reparse parents must cause refusal without destination writes.

## UI verification
Parse XAML and localization/key/control contracts on Linux. Windows CI can load WPF and instantiate windows on STA, measure virtualization/small-screen/DPI layout and worker cancellation plumbing without claiming interactive usability. Owner verifies keyboard, screen scaling, modal choices, real profiles and application dialogs. Long operations must be workers with observed progress, never UI-thread copy/hash.

## Performance
Measure actual copy/full verify/fast compare/deep compare/resume wall time, bytes/files, peak memory where available and environment. Synthetic fixtures small enough for CI; no extrapolated GB/s or hundreds-of-GB claims. Medium tens-of-GB and large hundreds-of-GB remain pending until measured on appropriate Windows data.

## Readiness/security/regression
Fresh independent lanes inspect exact final diff for security defects and separate Spec/Standards findings. Reproduce defects with tests before fixes. Parent reruns integrated suite. Preserve original MIT/license and original apply/snapshot/autostart/idle/selftest entry paths. Live registry/task/WinRE/PITR mutation is not performed by CI. Unknown restore-point/BitLocker state cannot become green readiness. No release assets/upstream publication until approved.

## Acceptance ledger
For each criterion record Passed / Failed / Blocked / NotApplicable, environment, exact command, artifact/commit, measured result and limitation. A passing parse gate proves syntax on that engine only. Final report must explicitly list unknown real rollback, active application consistency, NAS disconnect, cloud/EFS recoverability, GUI usability and large-scale performance unless actual evidence exists.
