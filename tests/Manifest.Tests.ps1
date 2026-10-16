$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Manifest.ps1')
function Assert-True($Value,$Message) { if(-not $Value) { throw $Message } }
function Assert-Throws([scriptblock]$Action,$Message) {
    $failed=$false
    try { $null=& $Action } catch { $failed=$true }
    Assert-True $failed $Message
}

$base=[IO.Path]::GetTempPath(); if($env:TMPDIR) { $base=$env:TMPDIR }
$temp=Join-Path $base ('pitr-manifest-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($temp)
try {
    $manifest=New-PitrManifest -BackupId ([guid]::NewGuid().ToString()) -Scope 'Complete'
    Assert-True ($manifest.SchemaVersion -eq 1) 'manifest schema version is 1'
    Assert-True ($manifest.State -eq 'Planned') 'new manifest starts Planned, never complete'
    Assert-True ($manifest.Consistency -eq 'LiveNotApplicationConsistent') 'live copy is labelled not application consistent'
    Assert-True ($manifest.SourceView -eq 'Live') 'source view recorded'

    $path=Join-Path $temp 'manifest.json'
    $null=Write-PitrManifest -ManifestPath $path -Manifest $manifest
    Assert-True ([IO.File]::Exists($path)) 'manifest written'
    Assert-True (-not (Get-ChildItem -LiteralPath $temp -File | Where-Object { $_.Name -notin @('manifest.json') })) 'no temporary manifest left behind'

    $read=Read-PitrManifest -ManifestPath $path
    Assert-True ($read.BackupId -eq $manifest.BackupId) 'round trip keeps the backup id'
    Assert-True ($read.State -eq 'Planned') 'round trip keeps the honest state'

    # State machine: an interrupted run must never be able to look complete.
    Assert-Throws { Set-PitrManifestState -Manifest $manifest -State 'Verified' } 'cannot skip straight to Verified'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'Running'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'Interrupted'
    Assert-Throws { Set-PitrManifestState -Manifest $manifest -State 'Verified' } 'interrupted cannot jump to Verified'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'Running'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'CopyCompleted'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'Verifying'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'Verified'
    Assert-True ($manifest.State -eq 'Verified') 'full ordered path reaches Verified'
    Assert-Throws { Set-PitrManifestState -Manifest $manifest -State 'Running' } 'Verified is terminal'

    # Strongest status is refused while anything is unaccounted for.
    $warned=New-PitrManifest -BackupId ([guid]::NewGuid().ToString()) -Scope 'Complete'
    $warned=Set-PitrManifestState -Manifest $warned -State 'Running'
    $warned=Set-PitrManifestState -Manifest $warned -State 'CopyCompleted'
    $warned=Set-PitrManifestState -Manifest $warned -State 'Verifying'
    $warned=Set-PitrManifestState -Manifest $warned -State 'CompletedWithWarnings'
    Assert-Throws { Set-PitrManifestState -Manifest $warned -State 'Verified' } 'Verified refused after warnings'
    Assert-Throws { Set-PitrManifestState -Manifest $manifest -State 'NotAState' } 'unknown state rejected'
    Assert-Throws { New-PitrManifest -BackupId 'not-a-guid' -Scope 'Complete' } 'non-GUID backup id rejected'
    Assert-Throws { New-PitrManifest -BackupId ([guid]::NewGuid().ToString()) -Scope 'invented' } 'unknown scope rejected'

    # Untrusted input: malformed JSON, wrong schema, wrong types, duplicate ids, bad paths.
    $bad=Join-Path $temp 'bad.json'
    $guid=([guid]::NewGuid().ToString())
    [IO.File]::WriteAllText($bad,'{ not json')
    Assert-Throws { Read-PitrManifest -ManifestPath $bad } 'malformed JSON refused'
    [IO.File]::WriteAllText($bad,'{"SchemaVersion":99}')
    Assert-Throws { Read-PitrManifest -ManifestPath $bad } 'unsupported schema rejected'
    [IO.File]::WriteAllText($bad,('{"SchemaVersion":1,"BackupId":"'+$guid+'","Scope":"Complete","State":"Complete","Entries":[]}'))
    Assert-Throws { Read-PitrManifest -ManifestPath $bad } 'unknown state in a loaded manifest refused'
    [IO.File]::WriteAllText($bad,'{"SchemaVersion":1,"BackupId":"not-a-guid","Scope":"Complete","State":"Planned","Entries":[]}')
    Assert-Throws { Read-PitrManifest -ManifestPath $bad } 'non-GUID BackupId refused'
    [IO.File]::WriteAllText($bad,('{"SchemaVersion":1,"BackupId":"'+$guid+'","Scope":"Complete","State":"Planned","Entries":[{"Id":"a","SourceId":"s","RelativePath":"..\\escape","Type":"File","Length":1,"CopyStatus":"Copied"}]}'))
    Assert-Throws { Read-PitrManifest -ManifestPath $bad } 'parent-directory relative path refused'
    [IO.File]::WriteAllText($bad,('{"SchemaVersion":1,"BackupId":"'+$guid+'","Scope":"Complete","State":"Planned","Entries":[{"Id":"a","SourceId":"s","RelativePath":"C:\\rooted.txt","Type":"File","Length":1,"CopyStatus":"Copied"}]}'))
    Assert-Throws { Read-PitrManifest -ManifestPath $bad } 'rooted relative path refused'
    [IO.File]::WriteAllText($bad,('{"SchemaVersion":1,"BackupId":"'+$guid+'","Scope":"Complete","State":"Planned","Entries":[{"Id":"a","SourceId":"s","RelativePath":"ok.txt","Type":"File","Length":"1","CopyStatus":"Copied"}]}'))
    Assert-Throws { Read-PitrManifest -ManifestPath $bad } 'wrong field type refused'
    [IO.File]::WriteAllText($bad,('{"SchemaVersion":1,"BackupId":"'+$guid+'","Scope":"Complete","State":"Planned","Entries":[{"Id":"a","SourceId":"s","RelativePath":"one.txt","Type":"File","Length":1,"CopyStatus":"Copied"},{"Id":"a","SourceId":"s","RelativePath":"two.txt","Type":"File","Length":1,"CopyStatus":"Copied"}]}'))
    Assert-Throws { Read-PitrManifest -ManifestPath $bad } 'duplicate entry id refused'
    [IO.File]::WriteAllText($bad,('{"SchemaVersion":1,"BackupId":"'+$guid+'","Scope":"Complete","State":"Planned","Entries":[{"Id":"a","SourceId":"s","RelativePath":"ok.txt","Type":"File","Length":1,"CopyStatus":"InstantWin"}]}'))
    Assert-Throws { Read-PitrManifest -ManifestPath $bad } 'unknown copy status refused'

    # Untrusted content is data, never a command.
    [IO.File]::WriteAllText($bad,('{"SchemaVersion":1,"BackupId":"'+$guid+'","Scope":"Complete","State":"Planned","Entries":[{"Id":"a","SourceId":"s","RelativePath":"ok.txt","Type":"File","Length":1,"CopyStatus":"Copied","Error":"$(Remove-Item -Recurse -Force C:\\backups)"}]}'))
    $loaded=Read-PitrManifest -ManifestPath $bad
    Assert-True ($loaded.Entries[0].Error -match 'Remove-Item') 'hostile text is preserved as inert data'

    # Hashing: streaming, correct, and it notices a single byte change.
    $fileA=Join-Path $temp 'a.bin'
    [IO.File]::WriteAllBytes($fileA,[byte[]](1..255))
    $hashA=Get-PitrHash -Path $fileA
    Assert-True ($hashA.Length -eq 64 -and $hashA -match '^[0-9a-f]{64}$') 'SHA-256 hex digest shape'
    Assert-True ($hashA -eq (Get-PitrHash -Path $fileA)) 'hashing is deterministic'
    $fileB=Join-Path $temp 'b.bin'
    [IO.File]::WriteAllBytes($fileB,[byte[]](2..255))
    Assert-True ((Get-PitrHash -Path $fileB) -ne $hashA) 'a changed byte changes the digest'
    Assert-Throws { Get-PitrHash -Path (Join-Path $temp 'missing.bin') } 'hashing a missing file fails'

    # A large file must not be loaded whole: hash it and confirm the same value via a stream.
    $big=Join-Path $temp 'big.bin'
    $stream=New-Object IO.FileStream($big,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $chunk=New-Object byte[] (1MB); for($i=0;$i -lt 12;$i++) { $stream.Write($chunk,0,$chunk.Length) } } finally { $stream.Dispose() }
    $bigHash=Get-PitrHash -Path $big
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $expected=([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($big)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    Assert-True ($bigHash -eq $expected) 'streamed hash matches an independent computation for a 12 MiB file'

    # Transactional write must not corrupt a good manifest when it fails.
    $good=Join-Path $temp 'good.json'
    $null=Write-PitrManifest -ManifestPath $good -Manifest (New-PitrManifest -BackupId ([guid]::NewGuid().ToString()) -Scope 'Complete')
    $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($good))
    $broken=Read-PitrManifest -ManifestPath $good
    $broken.State='NotAState'
    Assert-Throws { Write-PitrManifest -ManifestPath $good -Manifest $broken } 'invalid manifest refused on write'
    $after=[Convert]::ToBase64String([IO.File]::ReadAllBytes($good))
    Assert-True ($before -ceq $after) 'existing manifest untouched by a refused write'
    $stillGood=Read-PitrManifest -ManifestPath $good
    Assert-True ($stillGood.State -eq 'Planned') 'existing manifest still readable after a refused write'
    Assert-True (-not (Get-ChildItem -LiteralPath $temp -File | Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '.*.tmp' })) 'no temporary files left after a refused write'

    Write-Output 'Manifest assertions passed.'
} finally {
    if([IO.Directory]::Exists($temp)) { [IO.Directory]::Delete($temp,$true) }
}
