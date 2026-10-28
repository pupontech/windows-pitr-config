$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Output 'SKIP: real file workflow inside unified WPF host requires Windows.'; return }
$engine=(Get-Process -Id $PID).Path
& $engine -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'UiSimpleWindows.Tests.ps1') -Unified
if($LASTEXITCODE -ne 0) { throw 'Unified host file backup/preview/confirmed-restore workflow failed.' }
Write-Output 'PASS: real backup/verify/preview/default-keep/confirmed file restore inside the three-tab host.'
