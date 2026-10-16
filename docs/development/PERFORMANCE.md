# Performance evidence

## Actual measured run (recorded)
Command: `pwsh -NoProfile -File tests/Performance.Tests.ps1` on Linux (Debian 13), PowerShell 7.6.7, local filesystem.
- Dataset: synthetic cached fixture, 5 files, **1,068,032 bytes** (4 small + one 1 MiB file), created by tools/Measure-CopyAdapters.ps1 from a seeded RNG.
- Adapter measured: bounded 256 KiB streaming .NET copy, no whole-file buffering.
- Result recorded by the test run: copy 0.028 s and verification of every copied file by SHA-256 reread of both source and destination; 5/5 files verified, 0 mismatches. The test asserted both timers are strictly positive, so these are actual measurements, not placeholders.
- Robocopy leg: skipped on Linux (`-SkipRobocopy`); the real Robocopy leg must run on Windows.

## Not measured (must not be claimed)
- Tens-of-GB and hundreds-of-GB profiles, media libraries and deep trees.
- Network/NAS throughput and interruption, external USB, BitLocker/EFS volumes, cloud placeholder hydration.
- Memory and CPU under long copies; GUI responsiveness under a real copy.
- A larger standalone benchmark invocation (400 files + 32 MiB) was not executed: the tool approval for the command timed out before it ran, and it was not retried by another route. No number from that run exists.

## Method notes and limits
- Verification rereads source and destination and compares SHA-256, so both copies are on the measured path.
- Robocopy reference on Windows: `tools/Measure-CopyAdapters.ps1` (no -SkipRobocopy). It uses `/E /COPY:DAT /DCOPY:DA /R:2 /W:2 /XJ`, never mirror/purge/move, and hash-verifies the separate destination tree; its exit code and any copy failures are recorded per adapter.
- Any published figure must name dataset scale, filesystem, storage class, cache state and verification mode. Full-file hashing twice (copy then verify) is deliberate here and its cost is part of the number.
- Use the Windows CI legs to compare adapters on runner storage; treat the owner's real drives as the only credible large-scale source.
