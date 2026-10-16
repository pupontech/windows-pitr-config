# CI/build evidence

The initial delegated scaffolding lane failed HTTP 429 before writing owned files. Parent implemented the lane, without claiming a substitute delegate success.

## Executed locally
- `pwsh -NoProfile -File tests/Source.Tests.ps1` RED: exit 1, `RED: source verifier not implemented`.
- Same command GREEN: exit 0; `Source parse/encoding checks passed: 5 scripts plus hybrid CMD; engine 7.6.7.` and `Source and reproducible portable-build assertions passed.` Count describes this invocation only, not subsequent added scripts.
- The tests run the actual PowerShell builder twice on a test-owned synthetic package, compare ZIP SHA256 for deterministic bytes, inspect root CMD CRLF and included entrypoint/integrity inventory, then require refusal after removing a mandatory module. Synthetic package is not the finished application.
- CLI parser separate RED/GREEN: actual tests/Cli.Tests.ps1 failed absent parser, then passed assertions for routing, literal paths, explicit mapping, safe defaults and invalid/ambiguous options.

## Implemented but not yet executed on Windows
`.github/workflows/backup-recovery-ci.yml` matrix Windows 2022/2025 x Windows PowerShell 5.1/pwsh. Runs real source parser and dependency-free behavior suites in fresh processes, original actual CMD selftest, reproducible builder, extracted artifact inventory verification and launcher/selftest in a path with spaces/brackets/apostrophe. Requires full integrated source; missing modules fail packaging, not a false release. No actual Actions run is asserted here.

Builder normalizes executable line endings to CRLF and UTF8 no BOM, includes original guide as root guide.html for offline use, retains MIT LICENSE and attribution. It refuses to replace an existing different ZIP with the same version. Integrity inventory detects changes but is not an authenticity signature. Full extraction/independent backup recovery behavioral tests remain to integrate after engine lanes.

No live PITR rollback, actual user application data, interactive WPF acceptance, cloud/EFS/NAS failure or large-scale throughput was tested by this lane.
