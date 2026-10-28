$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$cmd = Join-Path $repo 'pitr-config.cmd'
$source = (New-Object Text.UTF8Encoding($false,$true)).GetString([IO.File]::ReadAllBytes($cmd))
if($source.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal) -or $source -match '(?<!\r)\n') { throw 'Original CMD must be UTF-8 without BOM and use CRLF, including its preamble.' }
$marker = '#___PSCODE___'
$at = $source.LastIndexOf($marker)
if ($at -lt 0) { throw 'Embedded PowerShell marker missing' }
$embedded = $source.Substring($at + $marker.Length)
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseInput($embedded, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw "Embedded PowerShell parser errors: $($errors -join '; ')" }
$batch = $source.Substring(0, $at)
$checks = [ordered]@{
    'delayed expansion disabled' = $batch -match '(?im)^setlocal DisableDelayedExpansion\s*$'
    'admin check uses token identity, not net session' = $batch -match 'WindowsPrincipal' -and $batch -notmatch '(?im)^net session'
    'elevation passes path as environment data' = $batch -match 'PITR_ELEVATE_SELF=%~f0' -and $batch -match 'Start-Process.*\$env:PITR_ELEVATE_SELF'
    'elevation is bounded to one launch' = $batch -match 'if not defined PITR_ELEVATION_ATTEMPTED'
    'CLI routes precede GUI elevation' = $batch.IndexOf('if /i "%~1"=="apply"') -lt $batch.IndexOf('PITR_ELEVATION_ATTEMPTED')
    'GUI startup reports failures' = $batch -match 'MessageBox.*Show' -and $batch -match 'catch'
}
$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
foreach ($check in $checks.GetEnumerator()) { '{0}: {1}' -f $check.Key, $(if ($check.Value) { 'PASS' } else { 'FAIL' }) }
if ($failed.Count) { throw "$($failed.Count) launcher assertions failed" }
'Embedded PowerShell syntax: PASS'

# Parse every actual -Command body, not a rewritten approximation. The legacy
# single-quoted filename was invalid source for O'Brien before it reached UAC.
$commands=@([regex]::Matches($batch,'(?m)^powershell(?:\.exe)?[^\r\n]* -Command "([^\r\n]*)"\r?$'))
foreach($command in $commands) {
    $parseTokens=$null;$parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($command.Groups[1].Value,[ref]$parseTokens,[ref]$parseErrors)
    if($parseErrors.Count) { throw ('Launcher command parse error: '+($parseErrors.Message -join '; ')) }
}
$elevation=@($commands | Where-Object { $_.Groups[1].Value -match 'Start-Process' })
if($elevation.Count -ne 1) { throw 'Expected one bounded elevation boundary.' }
$tempBase=if($env:TMPDIR) {$env:TMPDIR} else {[IO.Path]::GetTempPath()}
$fixture=Join-Path $tempBase ('pitr-elevation-command-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try {
    $probe=Join-Path $fixture 'probe.ps1'
    $capture=Join-Path $fixture 'captured.json'
    $fakePath=Join-Path $fixture "O'Brien (download 1) & A! pitr-config.cmd"
    $stub=@'
function Start-Process {
 param($FilePath,$Verb,$ArgumentList,$WorkingDirectory,[switch]$Wait,[switch]$PassThru)
 [IO.File]::WriteAllText($env:PITR_TEST_CAPTURE,([pscustomobject]@{FilePath=$FilePath;Verb=$Verb;ArgumentList=$ArgumentList;WorkingDirectory=$WorkingDirectory;Wait=[bool]$Wait;PassThru=[bool]$PassThru} | ConvertTo-Json))
 if($env:PITR_TEST_MODE -eq 'cancel') { throw 'Synthetic UAC cancellation' }
 if($env:PITR_TEST_MODE -eq 'null') { return }
 [pscustomobject]@{ExitCode=[int]$env:PITR_TEST_MODE}
}
'@
    [IO.File]::WriteAllText($probe,($stub+"`n"+$elevation[0].Groups[1].Value),(New-Object Text.UTF8Encoding($false)))
    foreach($mode in @('0','17','cancel','null')) {
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$probe+'"'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $info.EnvironmentVariables['PITR_ELEVATE_SELF']=$fakePath
        $info.EnvironmentVariables['PITR_ELEVATE_ARGS']='noupdate __pitr_elevated'
        $info.EnvironmentVariables['PITR_TEST_CAPTURE']=$capture
        $info.EnvironmentVariables['PITR_TEST_MODE']=$mode
        $process=[Diagnostics.Process]::Start($info)
        try {
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(15000)) { $process.Kill();$null=$process.WaitForExit(10000);throw 'Mocked elevation command hung.' }
            $expected=if($mode -in @('cancel','null')) {5} else {[int]$mode}
            if($process.ExitCode -ne $expected) { throw ('Elevation outcome lost: '+$mode+'; '+$stderr.Result+' '+$stdout.Result) }
            $received=[IO.File]::ReadAllText($capture) | ConvertFrom-Json
            if($received.FilePath -cne $fakePath -or $received.ArgumentList -cne 'noupdate __pitr_elevated' -or $received.Verb -ne 'RunAs' -or -not $received.Wait -or -not $received.PassThru -or $received.WorkingDirectory -cne [IO.Path]::GetDirectoryName($fakePath)) { throw 'Actual elevation boundary changed literal path, marker, no-update, verb or wait/exit contract.' }
        } finally { $process.Dispose() }
    }
    Write-Output 'Actual elevation command with inert Start-Process: literal apostrophe/metacharacter path, marker/no-update, exit17, cancellation and null-handle outcomes PASS. Real UAC not exercised.'
} finally { [IO.Directory]::Delete($fixture,$true) }
