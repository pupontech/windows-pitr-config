$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$script=Join-Path $root 'tools/Measure-CopyAdapters.ps1'
if(-not (Test-Path -LiteralPath $script)) { throw 'RED: measured adapter benchmark not implemented' }
$base=[IO.Path]::GetTempPath(); if($env:TMPDIR) { $base=$env:TMPDIR }
$path=Join-Path $base ('pitr-perf-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    $report=& $script -SmallFiles 4 -LargeFiles 1 -LargeFileMiB 1 -ReportPath $path -SkipRobocopy
    if($report.SchemaVersion -ne 1 -or $report.Dataset.FileCount -ne 5) { throw 'Measured dataset inventory incorrect' }
    if($report.Adapters.Count -ne 1 -or $report.Adapters[0].VerifiedFiles -ne 5) { throw 'Actual copied file hashes not verified' }
    if($report.Adapters[0].CopySeconds -le 0 -or $report.Adapters[0].VerificationSeconds -le 0) { throw 'Benchmark did not record actual timers' }
    if(-not [IO.File]::Exists($path)) { throw 'Performance JSON report missing' }
    $persisted=[IO.File]::ReadAllText($path) | ConvertFrom-Json
    if($persisted.Dataset.Bytes -ne $report.Dataset.Bytes) { throw 'Persisted report differs' }
    Write-Output ('Measured native copy fixture passed: '+$report.Dataset.Bytes+' bytes; '+$report.Adapters[0].CopySeconds+' copy seconds. Synthetic cached fixture only.')
} finally { if([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
