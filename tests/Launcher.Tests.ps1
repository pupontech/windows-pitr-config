$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$path=Join-Path $root 'pitr-backup.cmd'
if(-not [IO.File]::Exists($path)) { throw 'RED: portable CMD launcher not implemented' }
$bytes=[IO.File]::ReadAllBytes($path)
$text=[Text.Encoding]::UTF8.GetString($bytes)
if($text -match '(?<!\r)\n' -or $text.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)) { throw 'Launcher encoding/CRLF violation' }
if($text -notmatch '-File "%PITR_ENTRY%" %\*') { throw 'Launcher must pass literal native args to -File entrypoint' }
if($text -match 'Start-Process|RunAs|net session|Invoke-Expression') { throw 'CLI launcher must never elevate or evaluate args' }
if($env:OS -eq 'Windows_NT') {
    & $path --help
    if($LASTEXITCODE -ne 0) { throw 'Actual CMD launcher help failed' }
}
Write-Output 'Portable CMD launcher assertions passed; actual CMD execution Windows-only.'
