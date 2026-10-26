$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Manifest.ps1')
. (Join-Path $root 'src/backup/Recovery.ps1')
$base=[IO.Path]::GetTempPath();if($env:TMPDIR){$base=$env:TMPDIR}
$f=Join-Path $base ('pitr-report-actions-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($f)
try {
    $actions=@(
        [pscustomobject]@{EntryId='one';RelativePath='a.txt';Action='RecoverMissing';Destination='new.txt';PreservedPath=$null;FailedPath=$null;RollbackStatus='NotNeeded';Result='Succeeded';VerificationStatus='FullVerified';Error=$null},
        [pscustomobject]@{EntryId='two';RelativePath='=formula.txt';Action='ReplacePreservingCurrent';Destination='old.txt';PreservedPath='preserved.txt';FailedPath='failed.txt';RollbackStatus='Restored';Result='Failed';VerificationStatus='NotAttempted';Error='failed, then rolled back'}
    )
    $report=[pscustomobject]@{BackupId=[guid]::NewGuid().ToString();Actions=$actions;Complete=$false}
    $path=Join-Path $f 'actions.csv'
    Export-PitrReport -Report $report -Path $path -Format Csv
    $rows=@(Import-Csv -LiteralPath $path)
    if($rows.Count -ne 2 -or $rows[0].Result -ne 'Succeeded' -or $rows[1].Result -ne 'Failed'){throw 'RED: restore CSV loses action outcomes'}
    if($rows[1].RollbackStatus -ne 'Restored' -or $rows[1].PreservedPath -ne 'preserved.txt' -or $rows[1].FailedPath -ne 'failed.txt'){throw 'CSV loses preservation/rollback evidence'}
    if($rows[1].Error -ne 'failed, then rolled back'){throw 'CSV quoting corrupted error'}
    if($rows[1].RelativePath -ne "'=formula.txt"){throw 'Action CSV formula mitigation absent'}
    Write-Output 'Restore CSV outcomes, rollback paths, escaping and formula mitigation passed.'
}finally{[IO.Directory]::Delete($f,$true)}
