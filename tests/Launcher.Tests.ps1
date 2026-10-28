$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$startHere=Join-Path $root 'START-HERE.cmd'
if(-not [IO.File]::Exists($startHere)) { throw 'RED: obvious START-HERE.cmd entrypoint is missing.' }
$startText=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($startHere))
if($startText -notmatch 'PITR_MAIN=%~dp0pitr-config\.cmd' -or $startText -notmatch '(?m)^"%PITR_MAIN%"\r?$') { throw 'START-HERE must chain to the unified main launcher without CALL re-expansion.' }
if($startText -match '(?<!\r)\n' -or $startText.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)) { throw 'START-HERE encoding/CRLF violation.' }
if($startText -notmatch '-File "%PITR_ENTRY%" %\*') { throw 'Explicit START-HERE CLI must stay direct and non-elevating.' }
if($env:OS -eq 'Windows_NT') { & $startHere --help; if($LASTEXITCODE -ne 0) { throw 'Actual START-HERE launcher failed.' } }
$path=Join-Path $root 'pitr-backup.cmd'
if(-not [IO.File]::Exists($path)) { throw 'RED: portable CMD launcher not implemented' }
$bytes=[IO.File]::ReadAllBytes($path)
$text=[Text.Encoding]::UTF8.GetString($bytes)
if($text -match '(?<!\r)\n' -or $text.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)) { throw 'Launcher encoding/CRLF violation' }
if($text -notmatch '-File "%PITR_ENTRY%" %\*') { throw 'Launcher must pass literal native args to -File entrypoint' }
if($text -match 'Start-Process|RunAs|net session|Invoke-Expression') { throw 'CLI launcher must never elevate or evaluate args' }
if($text -notmatch '(?im)^setlocal DisableDelayedExpansion\s*$') { throw 'RED: launchers must disable inherited delayed expansion to preserve exclamation marks in paths.' }
if($text -notmatch '(?im)^pause\s*$' -or $text -notmatch '(?im)^:cli\s*$') { throw 'RED: no-argument GUI startup failures must remain visible, without pausing explicit CLI commands.' }
if($env:OS -eq 'Windows_NT') {
    & $path --help
    if($LASTEXITCODE -ne 0) { throw 'Actual CMD launcher help failed' }
}
Write-Output 'Portable CMD launcher assertions passed; actual CMD execution Windows-only.'
