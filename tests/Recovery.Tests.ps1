$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Manifest.ps1')
. (Join-Path $root 'src/backup/Recovery.ps1')

function Assert-True($Value,$Message) { if(-not $Value) { throw $Message } }
function Assert-Throws([scriptblock]$Action,$Message) {
    $failed=$false
    try { $null=& $Action } catch { $failed=$true }
    Assert-True $failed $Message
}
function Get-EntryId([object[]]$Entries,[string]$RelativePath) {
    $found=@($Entries | Where-Object { $_.RelativePath -eq $RelativePath })
    if($found.Count -ne 1) { throw ('Expected exactly one comparison entry for '+$RelativePath+' but found '+$found.Count) }
    return [string]$found[0].Id
}

$base=[IO.Path]::GetTempPath(); if($env:TMPDIR) { $base=$env:TMPDIR }
$fixture=Join-Path $base ('pitr-recovery-'+[guid]::NewGuid().ToString('N'))
$backupRoot=Join-Path $fixture 'backup'
$currentRoot=Join-Path $fixture 'current'
$alternateRoot=Join-Path $fixture 'alternate-out'
$backupProfiles=Join-Path $backupRoot 'profiles/src-1'
foreach($dir in @($backupProfiles,$currentRoot,$alternateRoot)) { $null=[IO.Directory]::CreateDirectory($dir) }

$utf8=New-Object Text.UTF8Encoding($false)
function New-File([string]$Path,[string]$Content) {
    $directory=Split-Path -Parent $Path
    if(-not [IO.Directory]::Exists($directory)) { $null=[IO.Directory]::CreateDirectory($directory) }
    [IO.File]::WriteAllText($Path,$Content,$utf8)
}

# Backup side
New-File (Join-Path $backupProfiles 'missing.txt') 'backup-only content'
New-File (Join-Path $backupProfiles 'same.txt') 'identical content'
New-File (Join-Path $backupProfiles 'changed.txt') 'backup version'
New-File (Join-Path $backupProfiles 'AppData/Roaming/app.db') 'application database bytes'
New-File (Join-Path $backupProfiles 'Desktop/tool.exe') 'not really an executable, but a sensitive name'
New-File (Join-Path $backupProfiles 'deep/Documents/report.csv') 'col1,col2'

# Current side: same.txt identical, changed.txt different, an extra file only here
New-File (Join-Path $currentRoot 'same.txt') 'identical content'
New-File (Join-Path $currentRoot 'changed.txt') 'current newer version'
New-File (Join-Path $currentRoot 'current-only.txt') 'created after the backup'
$sameInfo=New-Object IO.FileInfo((Join-Path $currentRoot 'same.txt'))

$manifestPath=Join-Path $backupRoot 'manifest.json'
try {
    $manifest=New-PitrManifest -BackupId ([guid]::NewGuid().ToString()) -Scope 'Complete' -ApplicationVersion '1.9.0-test'
    $manifest.Sources=@([pscustomobject]@{ Id='src-1'; Path='C:\Users\Test'; ProfileSid='S-1-5-21-1-1-1-1001'; SourceVolumeId='vol-a'; Category='Profile'; DisplayName='Test' })
    $entries=New-Object 'Collections.Generic.List[object]'
    foreach($relative in @('missing.txt','same.txt','changed.txt','AppData/Roaming/app.db','Desktop/tool.exe','deep/Documents/report.csv')) {
        $backupFile=Join-Path $backupProfiles $relative
        $parameters=@{
            Id=('entry-'+($relative -replace '[^A-Za-z0-9]','-')); SourceId='src-1'; RelativePath=$relative
            Type='File'; Length=(New-Object IO.FileInfo($backupFile)).Length
            CopyStatus='Copied'; VerificationStatus='FullVerified'
            Sha256=(Get-PitrHash -Path $backupFile)
        }
        if($relative -eq 'same.txt') { $parameters.LastWriteUtc=$sameInfo.LastWriteTimeUtc.ToString('o') }
        $entries.Add((New-PitrManifestEntry @parameters))
    }
    $manifest.Entries=$entries.ToArray()
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'Running'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'CopyCompleted'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'Verifying'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'Verified'
    $null=Write-PitrManifest -ManifestPath $manifestPath -Manifest $manifest
    $mappings=@{ 'src-1' = $currentRoot }

    # --- mapping is required and unmapped sources are never guessed
    $unmapped=Compare-PitrBackup -ManifestPath $manifestPath
    Assert-True (-not $unmapped.Complete) 'comparison without an approved location is incomplete'
    Assert-True (@($unmapped.Warnings) -join ' ' -match 'no approved current location') 'missing mapping is stated in a warning'
    Assert-True (@($unmapped.Entries | Where-Object { $_.Classification -ne 'Unknown' }).Count -eq 0) 'nothing is classified without an approved location'

    # --- shallow classification
    $shallow=Compare-PitrBackup -ManifestPath $manifestPath -Mappings $mappings
    Assert-True ($shallow.Complete) 'mapped shallow comparison is complete'
    Assert-True (@($shallow.Entries | Where-Object { $_.RelativePath -eq 'missing.txt' })[0].Classification -eq 'Missing') 'a file absent from the restored installation is Missing'
    Assert-True (@($shallow.Entries | Where-Object { $_.RelativePath -eq 'same.txt' })[0].Classification -eq 'LikelyIdentical') 'matching metadata is LikelyIdentical, not proof of identity'
    Assert-True (@($shallow.Entries | Where-Object { $_.RelativePath -eq 'changed.txt' })[0].Classification -eq 'Different') 'a differing file is Different'
    Assert-True (@($shallow.Entries | Where-Object { $_.RelativePath -eq 'current-only.txt' })[0].Classification -eq 'CurrentOnly') 'a file only on the current installation is CurrentOnly'
    Assert-True (@($shallow.Entries | Where-Object { $_.RelativePath -eq 'AppData/Roaming/app.db' })[0].IsAdvanced) 'AppData content is marked advanced'
    Assert-True (@($shallow.Entries | Where-Object { $_.RelativePath -eq 'Desktop/tool.exe' })[0].IsSensitive) 'executable content is marked sensitive'
    # Four backup entries have no counterpart at all in the current installation:
    # missing.txt, AppData/Roaming/app.db, Desktop/tool.exe and deep/Documents/report.csv.
    Assert-True ($shallow.Summary.Missing -eq 4) ('summary reports the four absent files, got ' + $shallow.Summary.Missing)
    Assert-True ($shallow.Summary.CurrentOnly -eq 1) ('summary reports one current-only file, got ' + $shallow.Summary.CurrentOnly)
    Assert-True (@($shallow.Entries | Where-Object { $_.RelativePath -eq 'CurrentOnly' -or $_.CurrentPath -like '*current-only.txt' })[0].BackupPath -eq $null) 'a current-only file has no backup source'

    # --- deep classification actually hashes
    $deep=Compare-PitrBackup -ManifestPath $manifestPath -Mappings $mappings -Deep
    Assert-True (@($deep.Entries | Where-Object { $_.RelativePath -eq 'same.txt' })[0].Classification -eq 'Identical') 'deep comparison proves identity by hash'
    Assert-True (@($deep.Entries | Where-Object { $_.RelativePath -eq 'same.txt' })[0].ContentVerified) 'deep result records that content was verified'
    Assert-True (@($deep.Entries | Where-Object { $_.RelativePath -eq 'changed.txt' })[0].Classification -eq 'Different') 'deep comparison detects a changed file'

    # --- selection rules
    Assert-Throws { Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @() } 'recovery without a selection is refused'
    Assert-Throws { Restore-PitrFiles -ManifestPath $manifestPath -EntryIds @('entry-missing-txt') } 'recovery without mapping or alternate root is refused'
    Assert-Throws { Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @('entry-missing-txt') -AlternateRoot (Join-Path $fixture 'no-such-root') } 'a missing alternate root is refused'

    $missingId=Get-EntryId $deep.Entries 'missing.txt'
    $changedId=Get-EntryId $deep.Entries 'changed.txt'
    $sameId=Get-EntryId $deep.Entries 'same.txt'
    $appDataId=Get-EntryId $deep.Entries 'AppData/Roaming/app.db'
    $exeId=Get-EntryId $deep.Entries 'Desktop/tool.exe'
    $deepId=Get-EntryId $deep.Entries 'deep/Documents/report.csv'
    $currentOnlyId=Get-EntryId $deep.Entries 'current-only.txt'

    # --- dry run writes nothing
    $dry=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($missingId)
    Assert-True ($dry.DryRun) 'recovery is dry-run unless explicitly executed'
    Assert-True (@($dry.Actions)[0].Result -eq 'DryRun') 'dry run reports DryRun'
    Assert-True (-not [IO.File]::Exists((Join-Path $currentRoot 'missing.txt'))) 'dry run created no file'

    # --- unknown/current-only entries are never targets
    $unknownId=[string](@($unmapped.Entries | Select-Object -First 1).Id)
    $refused=Restore-PitrFiles -ManifestPath $manifestPath -Mappings @{} -EntryIds @($unknownId) -AlternateRoot $alternateRoot
    Assert-True (@($refused.Actions)[0].Action -eq 'RefusedUnknown') 'an unknown entry is refused, not recovered'
    $keepOnly=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($currentOnlyId) -Execute
    Assert-True (@($keepOnly.Actions)[0].Result -eq 'Skipped') 'a current-only file is not a recovery target'
    Assert-True (@($keepOnly.Actions)[0].Action -eq 'PreserveCurrentOnly') 'current-only files are explicitly preserved'

    # --- identical entries are skipped
    $identical=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($sameId) -Conflict Replace -Execute
    Assert-True (@($identical.Actions)[0].Action -eq 'SkipIdentical') 'an identical file needs no recovery'

    # --- default conflict policy keeps the existing file
    $skipDefault=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($changedId) -Execute
    Assert-True (@($skipDefault.Actions)[0].Result -eq 'Skipped') 'an existing file is kept by default'
    Assert-True ((Get-Content -LiteralPath (Join-Path $currentRoot 'changed.txt') -Raw) -eq 'current newer version') 'the existing file is untouched by the default policy'

    # --- recover a missing file, byte for byte
    $recover=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($missingId) -Execute
    $restored=Join-Path $currentRoot 'missing.txt'
    Assert-True (@($recover.Actions)[0].Result -eq 'Succeeded') 'a missing file is recovered'
    Assert-True ((Get-Content -LiteralPath $restored -Raw) -eq 'backup-only content') 'the recovered file content matches the backup'
    Assert-True ((Get-PitrHash -Path $restored) -eq (Get-PitrHash -Path (Join-Path $backupProfiles 'missing.txt'))) 'the recovered file verifies by hash'
    Assert-True (@($recover.Actions)[0].VerificationStatus -eq 'FullVerified') 'recovery records its verification'

    # --- nested structure is preserved
    $nested=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($deepId) -Execute
    $nestedAction=@($nested.Actions)[0]
    Assert-True ([IO.File]::Exists((Join-Path $currentRoot 'deep/Documents/report.csv'))) ('recovery preserves the relative directory structure: action=' + $nestedAction.Action + ' result=' + $nestedAction.Result + ' destination=' + $nestedAction.Destination + ' error=' + $nestedAction.Error)

    # --- alongside keeps both versions
    $alongside=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($changedId) -Conflict Alongside -Execute
    $alongsidePath=[string](@($alongside.Actions)[0].Destination)
    Assert-True (@($alongside.Actions)[0].Result -eq 'Succeeded') 'alongside recovery succeeds'
    Assert-True ((Get-Content -LiteralPath $alongsidePath -Raw) -eq 'backup version') 'the alongside copy holds the backup bytes'
    Assert-True ((Get-Content -LiteralPath (Join-Path $currentRoot 'changed.txt') -Raw) -eq 'current newer version') 'the current file survives alongside recovery'

    # --- replace preserves the current bytes first
    $replace=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($changedId) -Conflict Replace -Execute
    $preserved=[string](@($replace.Actions)[0].PreservedPath)
    Assert-True (@($replace.Actions)[0].Result -eq 'Succeeded') 'replace recovery succeeds'
    Assert-True ((Get-Content -LiteralPath (Join-Path $currentRoot 'changed.txt') -Raw) -eq 'backup version') 'replace installs the backup bytes'
    Assert-True ($preserved -and [IO.File]::Exists($preserved)) 'replace preserves the previous file'
    Assert-True ((Get-Content -LiteralPath $preserved -Raw) -eq 'current newer version') 'the preserved file holds the previous bytes'

    # --- advanced content needs explicit consent, and the alternate root is preferred
    $noConsent=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($appDataId) -Execute
    Assert-True (@($noConsent.Actions)[0].Action -eq 'SkipAdvancedNotPermitted') 'AppData is not restored without explicit advanced consent'
    Assert-True (-not [IO.File]::Exists((Join-Path $currentRoot 'AppData/Roaming/app.db'))) 'no advanced content was written'
    $advanced=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($appDataId) -AllowAdvanced -AlternateRoot $alternateRoot -Execute
    Assert-True (@($advanced.Actions)[0].Result -eq 'Succeeded') 'advanced content can be recovered into an approved alternate root'
    Assert-True ([IO.File]::Exists((Join-Path $alternateRoot 'AppData/Roaming/app.db'))) 'advanced content landed under the alternate root'

    # --- sensitive content is never written into a live profile
    $sensitive=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($exeId) -Execute
    Assert-True (@($sensitive.Actions)[0].Action -eq 'RefusedSensitive') 'executable or startup content is refused inside a live profile'
    Assert-True (-not [IO.File]::Exists((Join-Path $currentRoot 'Desktop/tool.exe'))) 'no executable was written into the profile'
    $sensitiveAlt=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($exeId) -AlternateRoot $alternateRoot -Execute
    Assert-True (@($sensitiveAlt.Actions)[0].Result -eq 'Succeeded') 'executable content can be recovered into an alternate folder for inspection'

    # --- a tampered backup copy is refused, not restored
    [IO.File]::WriteAllText((Join-Path $backupProfiles 'changed.txt'),'tampered bytes',$utf8)
    $tampered=Restore-PitrFiles -ManifestPath $manifestPath -Mappings $mappings -EntryIds @($changedId) -Conflict Replace -Execute
    $tamperedAction=@($tampered.Actions)[0]
    Assert-True ($tamperedAction.Action -eq 'RefusedBackupChanged') ('a backup copy that no longer matches the manifest is refused, got action=' + $tamperedAction.Action + ' result=' + $tamperedAction.Result + ' error=' + $tamperedAction.Error)
    Assert-True ((Get-Content -LiteralPath (Join-Path $currentRoot 'changed.txt') -Raw) -eq 'backup version') 'the refused recovery changed nothing'

    # --- hostile manifest paths are refused at read time
    $hostile=Read-PitrManifest -ManifestPath $manifestPath
    $hostile.Entries[0].RelativePath='../../escape.txt'
    $hostilePath=Join-Path $fixture 'hostile.json'
    $json=$hostile | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($hostilePath,$json,$utf8)
    $hostileManifest=$null
    Assert-Throws { $hostileManifest=Read-PitrManifest -ManifestPath $hostilePath } 'a manifest whose entry escapes upward is refused'

    # --- cancellation stops work and reports incompleteness
    $cancelled=New-Object 'Collections.Hashtable'
    $cancelled['Cancelled']=$true
    $cancelledCompare=Compare-PitrBackup -ManifestPath $manifestPath -Mappings $mappings -Cancellation $cancelled
    Assert-True (-not $cancelledCompare.Complete) 'a cancelled comparison is incomplete'
    Assert-True (@($cancelledCompare.Warnings) -join ' ' -match 'cancel') 'a cancelled comparison says so'

    # --- reports are local, escaped and complete
    $reportPath=Join-Path $fixture 'report.json'
    $null=Export-PitrReport -Report $deep -Path $reportPath -Format Json
    Assert-True ([IO.File]::Exists($reportPath)) 'JSON report written'
    $reloaded=[IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
    Assert-True ($reloaded.SchemaVersion -eq 1 -and $reloaded.Summary.Missing -eq $deep.Summary.Missing) 'JSON report keeps its schema and counts'
    $csvPath=Join-Path $fixture 'report.csv'
    $null=Export-PitrReport -Report $deep -Path $csvPath -Format Csv
    $csv=[IO.File]::ReadAllText($csvPath)
    Assert-True ($csv -match 'Classification,SourceId,RelativePath') 'CSV has a header'
    Assert-True ($csv.Split("`r`n")[0].Split(',').Count -eq 8) ('CSV header keeps all eight columns, got ' + $csv.Split("`r`n")[0].Split(',').Count)
    $textPath=Join-Path $fixture 'report.txt'
    $null=Export-PitrReport -Report $deep -Path $textPath -Format Text
    Assert-True ((Get-Content -LiteralPath $textPath -Raw) -match 'Windows PITR Config') 'text report written'
    $formula=Export-PitrReport -Report ([pscustomobject]@{ SchemaVersion=1; BackupId='x'; Entries=@([pscustomobject]@{ Classification='Different'; SourceId='s'; RelativePath='=cmd|calc'; BackupLength=1; CurrentLength=1; BackupSha256=$null; CurrentSha256=$null; Error=$null }) }) -Path (Join-Path $fixture 'formula.csv') -Format Csv
    $formulaText=[IO.File]::ReadAllText($formula)
    Assert-True ($formulaText -match "'=cmd\|calc") 'a spreadsheet formula in a file name is neutralised'
    Assert-True (-not (Get-ChildItem -LiteralPath $fixture -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.tmp' })) 'no temporary report or restore files are left behind'

    Write-Output 'Recovery assertions passed.'
} finally {
    if([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture,$true) }
}
