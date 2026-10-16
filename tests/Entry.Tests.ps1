$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$entry=Join-Path $root 'src/backup/Entry.ps1'
if(-not (Test-Path -LiteralPath $entry)) { throw 'RED: portable CLI entrypoint not implemented' }
$engine=(Get-Process -Id $PID).Path
$out=& $engine -NoProfile -File $entry --help 2>$null
if($LASTEXITCODE -ne 0 -or ($out -join "`n") -notmatch 'dry-run') { throw 'Portable help did not execute successfully' }
$out=& $engine -NoProfile -File $entry backup --unknown 2>$null
if($LASTEXITCODE -ne 3) { throw 'Invalid input must exit 3 without loading UI or engine' }
$out=& $engine -NoProfile -File $entry recover restore --manifest nowhere --execute 2>$null
if($LASTEXITCODE -ne 5) { throw 'Restore without explicit mapping/selection must exit 5 before reading data' }
Write-Output 'Portable CLI entrypoint assertions passed.'
