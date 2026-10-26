$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Manifest.ps1')
$base=[IO.Path]::GetTempPath(); if($env:TMPDIR) { $base=$env:TMPDIR }
$fixture=Join-Path $base ('pitr-manifest-paths-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try {
    $manifest=New-PitrManifest -BackupId ([guid]::NewGuid().ToString())
    $entry=New-PitrManifestEntry -Id 'item' -SourceId 'source' -RelativePath 'data.txt' -Type File
    $manifest.Entries=@($entry)
    $path=Join-Path $fixture 'manifest.json'
    foreach($hostile in @('../outside.txt','/absolute.txt','\\server\share\file','C:\outside.txt','profiles/data.txt:stream')) {
        $entry.BackupRelativePath=$hostile
        [IO.File]::WriteAllText($path,($manifest | ConvertTo-Json -Depth 8))
        $refused=$false
        try { $null=Read-PitrManifest -ManifestPath $path } catch { $refused=$true }
        if(-not $refused) { throw ('Untrusted payload path accepted: '+$hostile) }
    }
    foreach($hostile in @('/absolute.txt','\\server\share\file','\rooted.txt')) {
        $refused=$false
        try { $null=ConvertTo-PitrSafeRelativePath -RelativePath $hostile } catch { $refused=$true }
        if(-not $refused) { throw ('Rooted relative path normalized instead of refused: '+$hostile) }
    }
    $entry.BackupRelativePath='profiles/source/data.txt'
    [IO.File]::WriteAllText($path,($manifest | ConvertTo-Json -Depth 8))
    $loaded=Read-PitrManifest -ManifestPath $path
    if($loaded.Entries[0].BackupRelativePath -ne 'profiles/source/data.txt') { throw 'Valid payload path changed' }
    Write-Output 'Manifest payload traversal, rooted paths, UNC, ADS refusal and valid round-trip passed.'
} finally { [IO.Directory]::Delete($fixture,$true) }
