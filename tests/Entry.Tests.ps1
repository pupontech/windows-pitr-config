$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$entry=Join-Path $root 'src/backup/Entry.ps1'
if(-not (Test-Path -LiteralPath $entry)) { throw 'RED: portable CLI entrypoint not implemented' }
$engine=(Get-Process -Id $PID).Path

# Started through .NET on purpose: Windows PowerShell 5.1 raises a terminating
# NativeCommandError for a native command's stderr under ErrorActionPreference=Stop,
# even with 2>$null. That would make an intentionally invalid option look like a
# harness failure instead of letting the exit code be asserted.
function Invoke-Portable {
    param([string[]]$PortableArguments)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$engine
    $info.Arguments=($PortableArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute=$false
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    $stdout=$process.StandardOutput.ReadToEnd()
    $null=$process.StandardError.ReadToEnd()
    if(-not $process.WaitForExit(120000)) { $process.Kill();throw 'Portable run exceeded 120s.' }
    [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$stdout }
}

$run=Invoke-Portable @('-NoProfile','-File',$entry,'--help')
if($run.ExitCode -ne 0 -or $run.Output -notmatch 'dry-run') { throw 'Portable help did not execute successfully' }
$run=Invoke-Portable @('-NoProfile','-File',$entry,'backup','--unknown')
if($run.ExitCode -ne 3) { throw 'Invalid input must exit 3 without loading UI or engine' }
$run=Invoke-Portable @('-NoProfile','-File',$entry,'recover','restore','--manifest','nowhere','--execute')
if($run.ExitCode -ne 5) { throw 'Restore without explicit mapping/selection must exit 5 before reading data' }
Write-Output 'Portable CLI entrypoint assertions passed.'
