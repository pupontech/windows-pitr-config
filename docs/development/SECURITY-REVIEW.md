# Security review

Status: INITIAL THREAT MODEL ONLY. No completed implementation review, security certification, Windows proof or release approval is implied. Review must be repeated on the exact integrated source and built artifact.

## Trust boundaries
- Elevated application code vs ordinary user files and their filenames/attributes.
- Trusted packaged engine/UI vs untrusted manifest, stored original paths, hashes and profile identities.
- Approved destination roots vs lexical children, device/ADS paths, hardlinks, junction/symlink aliases and concurrent path substitution.
- Pre-restore identity vs current Windows users/SIDs and their access rights.
- Backup integrity vs application consistency vs authenticity of the portable executable code.
- Client-side UNC writeability vs server-side access controls, availability and physical failure domains.

## Required invariants
1. Resolve OS/destination/source volume identity independently; no destination on OS volume through local aliases or mounted paths. Classify network paths explicitly and reject this-host shares even through aliases where resolvable.
2. Never follow directory reparse points during inventory, comparison or recovery; reject untrusted root/ancestor substitutions. String-prefix containment alone is insufficient. Existing destination hardlinks and TOCTOU races require explicit review.
3. Manifests are data only, strictly version/type/path/ID validated and size bounded. Never evaluate contents as commands or interpolate them into shell script source.
4. No destructive mirroring/deletion, silent existing-generation overwrite, ACL/ownership bypass, snapshot changes, credential persistence, runtime helper downloads or data uploads.
5. Restore only explicitly approved mappings and selection. Existing content default Skip. Explicit replacement preserves current bytes, verifies preserved copy and replacement, and records every failure. Sensitive startup content/system hives blocked; AppData requires advanced consent and warning, alternate root preferred.
6. A backup hash stored beside bytes detects accidental corruption only; an attacker can replace both. Portable application inventory is not an authenticity signature. Trusted tool media and destination security remain necessary; never claim malware resistance.
7. Live file read success is not database consistency. Source mutation, cloud placeholders, EFS prerequisites, alternate-stream/link/sparse/ACL limitations and enumeration failures must remain visible. No strongest success on unaccounted/skipped items.
8. Cancellation/resume, lock ownership and transactional state must prevent false completion or generation mutation. Concurrent verify/resume/recovery operations must not corrupt shared state.
9. UI progress and CLI exit states must reflect failures, unknown scans and missing recovery dependencies. No automatic PITR/reboot; original Windows recovery stays available.
10. Logs/reports remain local and may expose sensitive filenames. CSV formula injection, text escaping, output collisions and report path containment require tests.

## Focused implementation review checklist
- Trace every manifest path to actual filesystem read/write, including package installation, output/report/conflict directories and temp-file cleanup.
- Exercise malicious manifests, rooted/relative traversal, case/trailing-dot/device names, ADS, reparse ancestors, backup symlinks/hardlinks, source/destination root overlap and wrong-account mappings.
- Exercise race/collision failure paths and ensure neither user source nor existing backup/current-only files are deleted or falsely marked recovered.
- Review process argument handling from actual CMD, including spaces/apostrophes/brackets/Unicode; no Invoke-Expression for manifest/user argv and no unattended auto-elevation.
- Confirm packaged recovery operates without original checkout/registry application state/network, uses trusted local modules, and never executes backed-up user scripts.

## Open acceptance evidence
Independent defect review plus separate Spec/Standards pass, Windows PowerShell 5.1/Windows filesystem tests, detached ZIP recovery fixture, owner live GUI/PITR/cloud/EFS/NAS tests, and actual measured performance. All remain release gates until their evidence is recorded.
