$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($module in @('Platform','Manifest','Recovery')) { . (Join-Path $root ('src/backup/'+$module+'.ps1')) }
$base=[IO.Path]::GetTempPath(); if($env:TMPDIR) { $base=$env:TMPDIR }
$fixture=Join-Path $base ('pitr-recovery-boundary-'+[guid]::NewGuid().ToString('N'))
$backup=Join-Path $fixture 'backup';$current=Join-Path $fixture 'current';$outside=Join-Path $fixture 'outside'
foreach($folder in @($backup,$current,$outside)) { $null=[IO.Directory]::CreateDirectory($folder) }
try {
    $link=Join-Path $current 'nested'
    try { $null=New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop } catch {
        if($env:OS -eq 'Windows_NT') { Write-Output 'SKIP: symbolic link creation unavailable; real Windows junction/alias acceptance still required.';return }
        throw
    }
    $payload=Join-Path $backup 'payload.txt'; [IO.File]::WriteAllText($payload,'preserved backup bytes')
    $manifest=New-PitrManifest -BackupId ([guid]::NewGuid().ToString())
    $manifest.Sources=@([pscustomobject]@{Id='source';Path=$current})
    $manifest.Entries=@(New-PitrManifestEntry -Id 'selected' -SourceId 'source' -RelativePath 'nested/value.txt' -BackupRelativePath 'payload.txt' -Type File -CopyStatus Copied -Length ([IO.FileInfo]$payload).Length -Sha256 (Get-PitrHash $payload))
    $path=Join-Path $backup 'manifest.json';$null=Write-PitrManifest -ManifestPath $path -Manifest $manifest
    $result=Restore-PitrFiles -ManifestPath $path -Mappings @{source=$current} -EntryIds @('selected') -Execute
    if([IO.File]::Exists((Join-Path $outside 'value.txt'))) { throw 'Recovery wrote through a symlink outside the approved root' }
    if($result.Complete -or @($result.Entries | Where-Object {$_.Result -eq 'Succeeded'}).Count) { throw 'Unsafe recovery must be refused and incomplete' }
    Write-Output 'Real symlink boundary regression passed: no write outside approved recovery root.'
} finally {
    if($link -and (Test-Path -LiteralPath $link)) { [IO.Directory]::Delete($link) }
    [IO.Directory]::Delete($fixture,$true)
}
