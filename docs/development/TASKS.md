# Implementation task list

Project board: windows-pitr-config. Branch: feat/user-backup-recovery. Private GitHub derived repository: pupontech/windows-pitr-config. No upstream/release publication authorized.

Status legend: active / queued / review / verified / blocked. No task is complete on a child self-report alone.

| ID | Milestone | Owner | State | Depends on | Acceptance |
|---|---|---|---|---|---|
| PITR-01 | Source architecture audit and baseline | parent (delegate rate-limited) | verified (Linux baseline only) | - | Version, exact integration points, baseline evidence |
| PITR-02 | Windows research and threat model | parent (delegate rate-limited) | verified (research only) | - | Microsoft citations, VSS/live-copy decision, filesystem hazards |
| PITR-03 | Requirements/API/manifest specification | parent | review | PITR-01, PITR-02 | Full handoff scope traced, no safety dilution |
| PITR-04 | CI/build and regression foundation | parent (delegate rate-limited) | active | PITR-01 | Real PS parser, original selftest, Windows 5.1/pwsh, reproducible ZIP |
| PITR-05 | Profiles, scope, safe path/volume validation | platform subagent | active | PITR-03 | Alias/OS-volume rejection and profile fixtures |
| PITR-06 | Full backup, manifest, verification, resume | backup subagent | active | PITR-03, PITR-05 | Every entry accounted, hash failure/interruption/resume tests |
| PITR-07 | Independent recovery package | backup subagent + parent | active | PITR-06 | Detached-media launcher, integrity inventory, no original installation |
| PITR-08 | Compare, explicit mapping and safe recovery | recovery subagent | active | PITR-03, PITR-05, PITR-06 | Six classes, no default overwrite, preserved conflicts, hostile paths |
| PITR-09 | WPF wizard/recovery and ten locales | UI subagent | active | PITR-03 | Async responsive worker, actual progress/cancel, selectable results |
| PITR-10 | CLI and compact original-window integration | parent | active | PITR-05, PITR-06, PITR-08, PITR-09 | Unattended no UAC, JSON/text, dry-run, original commands preserved |
| PITR-11 | User/technical docs, reports, performance fixtures | parent | queued | PITR-06, PITR-08 | README, guide, changelog, schema, real synthetic reports |
| PITR-12 | Independent Security and Spec/Standards reviews | fresh review lanes | queued | PITR-04 through PITR-11 | Exact diff inspected, findings fixed with regressions |
| PITR-13 | Integrated Windows CI and extracted ZIP tests | parent | queued | PITR-12 | Actual runner evidence for exact commit, artifact verified |
| PITR-14 | Owner live Windows/PITR and scale validation | owner | blocked | PITR-13 | No VM provision; real rollback/live UI/cloud/EFS/NAS/large data not fabricated |
| PITR-15 | Release publication approval | owner | blocked | PITR-13 | No published assets/upstream PR before explicit permission |

## Environment notes
OpenSpec executable absent; lightweight equivalent uses version-controlled spec, implementation contract, this task list, test plan and risk/acceptance records. Hermes launcher currently reports an unrelated interrupted dependency/update completion and can stall; do not repair global installation as part of this project. Board was created and read back as windows-pitr-config. Native delegate_task lanes are active; no duplicate dispatcher workers.

AGENTS.md creation hit an approval timeout and was not written. Do not retry through another tool/path; project rules remain in the implementation contract. No task completion claim follows from scaffolding alone.
