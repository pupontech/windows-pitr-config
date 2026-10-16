# Repository audit and baseline

## Identity
Inspected upstream `henmedia/windows-pitr-config` at `a6595a87e0aec337b781a2962218c501bba0a113` on new branch `feat/user-backup-recovery`. Running version is `1.8.2`, defined once as `$Version` in original `pitr-config.cmd:172`; CHANGELOG first entry is 1.8.2. Private derived repo `pupontech/windows-pitr-config` preserves upstream history and MIT license. Initial source was clean. No existing automated tests, build scripts or CI workflows were tracked; `.github/FUNDING.yml` was the only initial GitHub configuration.

## Original architecture
- Single hybrid Batch/PowerShell file, 4323 lines at baseline. Batch dispatches selftest/apply/snapshot/autostart/idle before GUI elevation. Full PowerShell begins after final `#___PSCODE___` at original line 135. Explicit UTF8 loader intentionally supports non-ASCII localization without a BOM.
- Parameters line 161: SelfTest, Apply, Snapshot, AutoStart, Idle, Options. Existing modes must retain their arguments and process exit behavior.
- WPF assemblies loaded at 208-210, before top-level GUI/CLI branching. Selftest is non-mutating but is a WPF construction/translation test, not portable headless logic.
- `$LangText` contains per-language dictionaries; `$LangCodes` at 1923 has en/de/nl/fr/es/pt/it/pl/uk/cs. `T` fallback is English. `Apply-Language`, `Set-Lang` and explicit language handlers repaint the existing interface.
- Registry settings use existing PITR Settings values/precedence. Read functions Get-PitrValue, Get-RestorePoints, Get-ShadowStorage, Get-WinReState and Get-PitrSupport are separate from mutation functions.
- XAML starts at 2340, loads through XamlReader at 2785. Main window width 900, scrollable layout. Get-NamedElements walks WPF logical tree into `$ctl`, avoiding a manually maintained control list.
- Background update checking already uses a separate PowerShell runspace with three-second HTTP timeout, suppressible with PITR_NOUPDATE/noupdate. Preserve upstream feature; new backup/recovery has no network dependency.
- Existing Update-Ui pumps dispatcher for original PITR operations, but must not be used to run long backup/hash loops on the UI thread. New operations require independent workers and cancellation state.
- Original Set-Busy at 3643 disables the listed original controls, then separately keeps unsupported PITR mutation buttons disabled. Backup must remain usable independently of PITR presence.
- Set-Lang at 3665 repaints, handlers begin 3675. Original selftest at 4239 iterates all ten languages and ends before ShowDialog. Original GUI is shown at final line 4323.

## Minimal integration seams
1. Add `backup`/`recover`/help batch branches before UAC. Pass literal native argv to new Entry.ps1; no reconstruction/evaluation of user options as PowerShell code. Unattended/read-only modes never prompt elevation.
2. Add one compact Backup & Recovery GroupBox before GrpLog. Four controls launch separate windows; don't add huge tables to main window.
3. Lazy-load new presentation/engine modules on click using trusted app-relative paths; launch with original selected locale. Extend main Apply-Language for the compact controls without changing existing keys or handlers.
4. Keep copy/verify/compare/recover outside original WPF state. Portable recovery package contains trusted modules and its own launcher, allowing original application to be absent after rollback.
5. Initial maintainable portable ZIP retains small sidecars. Build normalizes executable bytes to UTF8 no BOM CRLF and includes local guide.html. Single-CMD assembly is an optional packaging refinement, not duplicate implementation.

## Baseline evidence
- Actual `pwsh -NoProfile -File tests/Source.Tests.ps1` passed the original embedded PowerShell parser and encoding checks under PowerShell 7.6.7 on Linux, plus synthetic builder tests. This is not Windows PowerShell 5.1 or WPF runtime evidence.
- An attempted direct extracted original SelfTest invocation was blocked by tool approval timeout before execution. It was not retried through another route and no WPF runtime result is claimed. Windows CI executes the real CMD selftest instead.
- Original README 580-590 requires UTF8 no BOM and CRLF; 631-635 documents selftest; 640 onward specifies semver and vX.Y.Z tags. No compiled build process exists upstream: the CMD is the distribution. New full feature requires a minor semver increase when release gates actually pass, not while partial scaffold is unverified.

## Unverified / release-blocking
Real Windows 5.1 parsing/serialization, original all-language WPF selftest, new UI runtime, profile/volume native APIs, actual detached recovery and end-to-end PITR rollback remain unverified until explicit test evidence. Original net-session GUI elevation and apostrophe-path quoting are legacy risks requiring separate Windows launcher regression coverage, not claims of correctness from Linux parsing.
