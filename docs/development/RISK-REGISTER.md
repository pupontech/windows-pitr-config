# Risk register

| Risk | Impact | Mitigation / acceptance evidence |
|---|---|---|
| Destination alias resolves to OS volume | Backup erased by PITR | Native stable volume identity/final path; reject unresolved local identity; junction/mount/SUBST/mapped local UNC negative tests |
| Malformed manifest or reparse escape | Elevated arbitrary writes/data disclosure | Strict schema/IDs/relative containment, no-follow ancestor checks, explicit approved mapping, adversarial fixtures; TOCTOU concurrency remains review-critical |
| Active databases/hives copied live | Intact but inconsistent application data | LiveNotApplicationConsistent label, closed-app recommendation, item errors/change detection; do not claim VSS/application consistency |
| VSS competes with PITR storage | Evicts restore points | No VSS mutation in initial fallback; supported writer-aware requester only after separate ownership/cleanup proof |
| Cloud/EFS/ADS/sparse/link behavior | Missing data or false recoverability | Detect/report unsupported per item, no automatic hydration or key export, strongest status forbidden on skips |
| Backup generation overwrite/resume races | Destroys last good copy | GUID generation, exclusive writer, transactional manifest, never mutate verified generations, hash validate resume |
| Wrong profile mapping | Privacy breach | SID evidence only suggestion, explicit mapping approval, no display-name guessing, alternate-root recovery |
| Modified-file collision | Loses newer Windows data | Skip default; alongside unique name or explicitly approved replace with verified preserved current bytes |
| AppData/startup content restoration | App corruption or malicious persistence | Advanced consent, alternate folder preference, sensitive startup/executable guards, never execute backup content |
| Launcher missing after rollback | Cannot recover via GUI | Include independent trusted launcher/all code/docs + hashes outside OS; detached-media fixture; manual Explorer layout |
| PS5.1/Windows-only behavior | Works on Linux, breaks for user | Mandatory real Windows Actions execution, actual CMD and extracted ZIP tests |
| WPF UI blocking or huge result sets | User cancels unsafely / high memory | Worker runspaces/processes, shared cancel/progress, virtualization, measured bounds; no invented percentages |
| NAS/server aliases cannot prove independent storage | Backup may still share machine/volume | Explicit network classification/limits; refuse obvious local share aliases; UNC not mapped-letter dependence |
| Translation not independently reviewed | Safety instructions misunderstood | All ten locale keys; unreviewed translation status, owner/native-language acceptance pending |
| Real PITR unsupported on CI | False end-to-end assurance | Clearly blocked owner rollback validation; never provision or mutate production Windows |
| Development approval timeout | Missing AGENTS.md | Do not bypass denied write; rules live in approved implementation-contract/spec files |
