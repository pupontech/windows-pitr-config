$ErrorActionPreference='Stop'
# End-to-end acceptance test of the production path: the real CLI entrypoint
# (src/backup/Entry.ps1, the file pitr-config.cmd and pitr-backup.cmd invoke) drives
# the real platform validation, backup engine, verification and comparison engine
# against synthetic fixture data. Nothing here is mocked inside the product: the only
# substitutions are the documented test hooks that answer Windows-only questions.

$root=Split-Path $PSScriptRoot -Parent
$entry=Join-Path $root 'src/backup/Entry.ps1'
if(-not (Test-Path -LiteralPath $entry)) { throw 'RED: backup CLI entrypoint missing' }
$engine=(Get-Process -Id $PID).Path

function Assert-True($Value,$Message) { if(-not $Value) { throw $Message } }
function Assert-Equal($Expected,$Actual,$Message) { if($Expected -ne $Actual) { throw ($Message + ' (expected ' + $Expected + ', got ' + $Actual + ')') } }
function Invoke-Cli {
    param([string[]]$Arguments,[hashtable]$ExtraEnvironment=@{})
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$engine
    $info.Arguments=((@('-NoProfile','-File',$entry) + $Arguments) | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute=$false
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.CreateNoWindow=$true
    foreach($key in $ExtraEnvironment.Keys) { $info.EnvironmentVariables[$key]=[string]$ExtraEnvironment[$key] }
    $process=[Diagnostics.Process]::Start($info)
    $stdout=$process.StandardOutput.ReadToEnd()
    $stderr=$process.StandardError.ReadToEnd()
    if(-not $process.WaitForExit(600000)) { $process.Kill(); throw 'CLI run exceeded 600s.' }
    [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$stdout; Error=$stderr }
}
function ConvertFrom-JsonOutput([string]$Text) {
    $start=$Text.IndexOf('{')
    if($start -lt 0) { throw ('No JSON object in output: ' + $Text) }
    return ($Text.Substring($start) | ConvertFrom-Json)
}

$base=[IO.Path]::GetTempPath(); if($env:TMPDIR) { $base=$env:TMPDIR }
$fixture=Join-Path $base ('pitr-e2e-'+[guid]::NewGuid().ToString('N'))
$profileRoot=Join-Path $fixture 'profiles/Alice'
$publicRoot=Join-Path $fixture 'profiles/Public'
$destination=Join-Path $fixture 'PITR-Backups'
$utf8=New-Object Text.UTF8Encoding($false)
$xaml=Join-Path $root 'docs/development'
foreach($dir in @($profileRoot,(Join-Path $profileRoot 'Documents'),(Join-Path $profileRoot 'AppData/Roaming'),$publicRoot,$destination)) { $null=[IO.Directory]::CreateDirectory($dir) }

function New-File([string]$Path,[string]$Content) {
    $directory=Split-Path -Parent $Path
    if(-not [IO.Directory]::Exists($directory)) { $null=[IO.Directory]::CreateDirectory($directory) }
    [IO.File]::WriteAllText($Path,$Content,$utf8)
}

try {
    New-File (Join-Path $profileRoot 'notes.txt') 'personal notes'
    New-File (Join-Path $profileRoot 'Documents/report.txt') 'quarterly report'
    New-File (Join-Path $profileRoot 'AppData/Roaming/settings.ini') '[main]'
    New-File (Join-Path $profileRoot 'hidden.dat') 'hidden content'
    (Get-Item -LiteralPath (Join-Path $profileRoot 'hidden.dat')).Attributes=[IO.FileAttributes]::Hidden
    New-File (Join-Path $publicRoot 'shared.txt') 'public document'

    $sid='S-1-5-21-1111111111-2222222222-3333333333-1001'
    $profileFixture=Join-Path $fixture 'profiles.csv'
    [IO.File]::WriteAllText($profileFixture,("Sid,Path`n" + $sid + ',' + $profileRoot + "`nS-1-5-32-545,`"%PITR_PUBLIC_ROOT%`"`n"),$utf8)

    # Volume fixtures: the profile volume and the destination volume are different
    # volumes, which is exactly the property the destination gate has to check.
    $sourceIdentity=[IO.Path]::GetFullPath($profileRoot)
    $destinationIdentity=[IO.Path]::GetFullPath($destination)
    $volumeFixture=Join-Path $fixture 'volumes.json'
    $volumeJson='{"' + $sourceIdentity.Replace('\','\\') + '":"local-osvol|serial:AAAA","' + $destinationIdentity.Replace('\','\\') + '":"local-backupvol|serial:BBBB"}'
    [IO.File]::WriteAllText($volumeFixture,$volumeJson,$utf8)

    $environment=@{
        PITR_PROFILELIST_FIXTURE_PATH=$profileFixture
        PITR_PUBLIC_ROOT=$publicRoot
        PITR_VOLUME_IDENTITY_FIXTURE=$volumeFixture
    }

    # --- the destination on the same volume as the source is refused
    $sameVolume=Join-Path $fixture 'volumes-same.json'
    [IO.File]::WriteAllText($sameVolume,('{"' + $sourceIdentity.Replace('\','\\') + '":"local-osvol|serial:AAAA"}'),$utf8)
    $inside=Join-Path $profileRoot 'Backups'
    $null=[IO.Directory]::CreateDirectory($inside)
    $refused=Invoke-Cli @('backup','--destination',$inside,'--scope','all-users') $environment
    Assert-True ($refused.ExitCode -ne 0) ('a backup destination inside the profile is refused, exit=' + $refused.ExitCode)
    Assert-True (-not (Get-ChildItem -LiteralPath $inside -Force | Where-Object { $_.Name -like '*manifest*' -or $_.Name -like 'profiles' })) 'the refused destination received no backup content'

    # --- a real backup through the CLI
    $backup=Invoke-Cli @('backup','--destination',$destination,'--scope','all-users','--verification','full') $environment
    Assert-True ($backup.ExitCode -in @(0,2)) ('run cleanly to completion, exit=' + $backup.ExitCode + ' stderr=' + $backup.Error)
    $backupResult=ConvertFrom-JsonOutput $backup.Output
    Assert-True ($backupResult.BackupId) 'the CLI reported a backup id'
    Assert-True ($backupResult.State -in @('Verified','CompletedWithWarnings')) ('the backup records an honest final state, got ' + $backupResult.State)

    $manifestPath=$backupResult.ManifestPath
    if(-not $manifestPath -or -not [IO.File]::Exists($manifestPath)) {
        $found=@(Get-ChildItem -LiteralPath $destination -Recurse -File -Filter 'manifest.json' -ErrorAction SilentlyContinue)
        Assert-True ($found.Count -eq 1) ('exactly one manifest should exist under the destination, found ' + $found.Count)
        $manifestPath=$found[0].FullName
    }
    Assert-True ([IO.File]::Exists($manifestPath)) 'a manifest was written'

    # --- the backup actually holds the user data, in the documented layout
    $backupRoot=Split-Path -Parent $manifestPath
    foreach($leaf in @('manifest.json','backup-status.json','backup-log.txt','profiles')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $backupRoot $leaf)) ('the backup generation contains ' + $leaf)
    }
    $manifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    # The recovery package must ship with the backup. While the presentation modules do
    # not exist yet, the engine must instead say plainly that it is not usable - never
    # quietly report a usable recovery environment it did not write.
    $recoveryDir=Join-Path $backupRoot 'recovery'
    $recoveryPresent=Test-Path -LiteralPath $recoveryDir
    $recoveryUsable=$false
    $packageField=$manifest.PSObject.Properties['RecoveryPackage']
    if($packageField -and $packageField.Value -and $null -ne $packageField.Value.PSObject.Properties['Usable']) { $recoveryUsable=[bool]$packageField.Value.Usable }
    if(Test-Path -LiteralPath (Join-Path $root 'src/backup/Ui.ps1')) {
        Assert-True $recoveryPresent 'the recovery package is written with the backup'
        Assert-True (Test-Path -LiteralPath (Join-Path $recoveryDir 'Start-Recovery.cmd')) 'the recovery launcher is written'
        Assert-True (Test-Path -LiteralPath (Join-Path $recoveryDir '../manifest.json')) 'the recovery launcher has its authoritative sibling manifest'
        Assert-True (Test-Path -LiteralPath (Join-Path $recoveryDir 'src/backup/Entry.ps1')) 'the recovery package retains the application-relative module layout'
    } else {
        Assert-True ((-not $recoveryUsable) -or $recoveryPresent) 'an absent recovery folder is never reported as a usable recovery package'
    }
    $profileEntries=@($manifest.Entries | Where-Object { $_.Type -eq 'File' -and $_.CopyStatus -eq 'Copied' })
    Assert-True ($profileEntries.Count -ge 5) ('every profile file was copied, counted ' + $profileEntries.Count)
    Assert-True (@($manifest.Entries | Where-Object { $_.RelativePath -match 'notes\.txt' }).Count -ge 1) 'notes.txt is in the manifest'
    Assert-True (@($manifest.Entries | Where-Object { $_.RelativePath -match 'AppData' -and $_.IsAdvanced }).Count -ge 1) 'AppData content is recorded and flagged advanced'
    Assert-True (@($manifest.Entries | Where-Object { $_.RelativePath -match 'hidden\.dat' }).Count -ge 1) 'a hidden file is included'
    Assert-True (@($manifest.Entries | Where-Object { $_.RelativePath -match 'shared\.txt' }).Count -ge 1) 'public documents are included'
    Assert-True ($manifest.Consistency -eq 'LiveNotApplicationConsistent') 'the backup states it is not an application-consistent snapshot'

    # every copied file is byte-identical to its source, by hash
    $verified=0
    foreach($item in $profileEntries) {
        if(-not $item.Sha256) { continue }
        $backupFile=Join-Path $backupRoot $item.BackupRelativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
        if(-not [IO.File]::Exists($backupFile)) { continue }
        $algorithm=[Security.Cryptography.SHA256]::Create()
        try { $hash=([BitConverter]::ToString($algorithm.ComputeHash([IO.File]::ReadAllBytes($backupFile)))).Replace('-','').ToLowerInvariant() } finally { $algorithm.Dispose() }
        if($hash -eq $item.Sha256) { $verified++ } else { throw ('backup copy does not match its recorded hash: ' + $item.RelativePath) }
    }
    Assert-True ($verified -ge 5) ('the payload hashes match the manifest, verified ' + $verified)

    # --- independent verification of the written backup
    $verify=Invoke-Cli @('backup','verify','--manifest',$manifestPath,'--verification','full','--format','json') $environment
    Assert-True ($verify.ExitCode -in @(0,2)) ('verification runs, exit=' + $verify.ExitCode + ' stderr=' + $verify.Error)

    # --- a tampered payload is detected by verification, not blessed
    $tamperTarget=@($manifest.Entries | Where-Object { $_.RelativePath -match 'notes\.txt' })[0]
    # Resolve the stored path exactly the way the engine does.
    $tamperPath=Join-Path $backupRoot $tamperTarget.BackupRelativePath
    Assert-True ([IO.File]::Exists($tamperPath)) ('the recorded backup path resolves to a real file: ' + $tamperPath)
    [IO.File]::WriteAllText($tamperPath,'tampered',$utf8)
    Assert-Equal 'tampered' (Get-Content -LiteralPath $tamperPath -Raw) 'the payload was actually altered'
    $tampered=Invoke-Cli @('backup','verify','--manifest',$manifestPath,'--verification','full','--format','json') $environment
    $tamperedManifest=[IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    $tamperedEntry=@($tamperedManifest.Entries | Where-Object { $_.RelativePath -match 'notes\.txt' })[0]
    Assert-True ($tampered.ExitCode -ne 0) ('a tampered backup fails verification, exit=' + $tampered.ExitCode + ' state=' + $tamperedManifest.State + ' entryStatus=' + $tamperedEntry.VerificationStatus + ' error=' + $tamperedEntry.Error + ' stderr=' + $tampered.Error)
    [IO.File]::WriteAllText($tamperPath,'personal notes',$utf8)
    $repaired=Invoke-Cli @('backup','verify','--manifest',$manifestPath,'--verification','full','--format','json') $environment
    Assert-True ($repaired.ExitCode -eq 0) ('the repaired backup verifies again, exit=' + $repaired.ExitCode + ' stderr=' + $repaired.Error)

    # --- comparison against the current installation
    $deleted=Join-Path $profileRoot 'Documents/report.txt'
    [IO.File]::Delete($deleted)
    $compare=Invoke-Cli @('recover','compare','--manifest',$manifestPath,'--mapping',($manifest.Sources[0].Id + '=' + $profileRoot),'--deep','--format','json') $environment
    Assert-True ($compare.ExitCode -in @(0,2)) ('comparison runs, exit=' + $compare.ExitCode + ' stderr=' + $compare.Error)
    $comparison=ConvertFrom-JsonOutput $compare.Output
    $rows=@($comparison.Entries)
    Assert-True ($rows.Count -ge 5) ('the comparison lists the backed-up files, counted ' + $rows.Count)
    $deletedRow=@($rows | Where-Object { $_.RelativePath -match 'report\.txt' })
    Assert-True ($deletedRow.Count -eq 1) ('the deleted file appears exactly once, found ' + $deletedRow.Count + ': ' + (($deletedRow | ForEach-Object { $_.Classification + '@' + $_.RelativePath }) -join ' | '))
    Assert-Equal 'Missing' $deletedRow[0].Classification 'a file removed after the backup is Missing'
    $unchangedRow=@($rows | Where-Object { $_.RelativePath -match 'notes\.txt' })[0]
    Assert-True ($unchangedRow.Classification -in @('Identical','LikelyIdentical')) ('an unchanged file is reported as identical, got ' + $unchangedRow.Classification)

    # --- dry run writes nothing
    $dryRun=Invoke-Cli @('recover','restore','--manifest',$manifestPath,'--mapping',($manifest.Sources[0].Id + '=' + $profileRoot),'--entry',[string]$deletedRow[0].Id,'--dry-run','--format','json') $environment
    Assert-True ($dryRun.ExitCode -in @(0,2)) ('dry run runs, exit=' + $dryRun.ExitCode + ' stderr=' + $dryRun.Error)
    Assert-True (-not [IO.File]::Exists($deleted)) 'the dry run restored nothing'

    # --- real recovery of the missing file, verified by hash
    $restore=Invoke-Cli @('recover','restore','--manifest',$manifestPath,'--mapping',($manifest.Sources[0].Id + '=' + $profileRoot),'--entry',[string]$deletedRow[0].Id,'--execute','--format','json') $environment
    Assert-True ($restore.ExitCode -in @(0,2)) ('recovery runs, exit=' + $restore.ExitCode + ' stderr=' + $restore.Error)
    Assert-True ([IO.File]::Exists($deleted)) 'the missing file was recovered'
    Assert-Equal 'quarterly report' (Get-Content -LiteralPath $deleted -Raw) 'the recovered content is the backed-up content'

    # --- the list command finds the generation
    $list=Invoke-Cli @('backup','list','--destination',$destination,'--format','json') $environment
    Assert-True ($list.ExitCode -in @(0,2)) ('list runs, exit=' + $list.ExitCode + ' stderr=' + $list.Error)
    $listing=ConvertFrom-JsonOutput $list.Output
    Assert-True (@($listing.Backups).Count -ge 1) 'the backup list reports the generation'
    Assert-True ($listing.Backups[0].State -in @('Verified','CompletedWithWarnings')) 'the listed generation carries its state'

    # --- help is available and says the safe thing
    $help=Invoke-Cli @('--help') $environment
    Assert-Equal 0 $help.ExitCode 'help exits successfully'
    Assert-True ($help.Output -match 'dry-run') 'help documents the dry-run default'

    Write-Output 'Backup CLI end-to-end assertions passed.'
} finally {
    if([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture,$true) }
}
