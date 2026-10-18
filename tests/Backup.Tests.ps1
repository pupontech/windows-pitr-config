$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Platform.ps1')
. (Join-Path $root 'src/backup/Manifest.ps1')
. (Join-Path $root 'src/backup/Backup.ps1')

# This suite is dependency-free: plain assertion functions, no Pester, no modules, no network.
# Two host concepts are tracked separately so a Linux run never reports a Windows behaviour:
#   $realWindows   - the process really runs on a Windows OS ($env:OS -eq 'Windows_NT').
#   $hostIsWindows - Get-PitrWindowsHost: true on real Windows, or when the test-only hook
#                    PITR_FORCE_WINDOWS_HOST=1 forces the Windows code branches to run.
# Assertions on Windows CODE PATHS run under $hostIsWindows (fixtures drive them anywhere).
# Assertions on Windows KERNEL SEMANTICS (native volume identity, drive letters, junctions,
# UNC/mapped drives, EFS/cloud attributes, ACLs, the CMD launcher) run under $realWindows and are
# otherwise SKIPPED with an explicit pending-real-Windows-CI reason, never failed and never
# claimed as verified.
$script:Passed=0
$script:Failures=New-Object 'Collections.Generic.List[string]'
$script:Skips=New-Object 'Collections.Generic.List[string]'
$script:Origins=New-Object 'Collections.Generic.List[string]'

function Assert-True($Value,$Message) {
    if($Value) { $script:Passed++ } else { $script:Failures.Add('expected true: '+$Message) }
}
function Assert-False($Value,$Message) {
    if(-not $Value) { $script:Passed++ } else { $script:Failures.Add('expected false: '+$Message) }
}
function Assert-Equal($Expected,$Actual,$Message) {
    if($Expected -eq $Actual) { $script:Passed++ } else { $script:Failures.Add('expected ['+$Expected+'] actual ['+$Actual+']: '+$Message) }
}
function Assert-Contains($Text,$Fragment,$Message) {
    if([string]$Text -like ('*'+$Fragment+'*')) { $script:Passed++ } else { $script:Failures.Add('expected to contain ['+$Fragment+'] but got ['+$Text+']: '+$Message) }
}
function Assert-Skip($Condition,[string]$Reason) {
    if(-not $Condition) { $script:Skips.Add($Reason) }
    return $Condition
}
function New-TestRoot([string]$Label) {
    $base=$env:TMPDIR
    if(-not $base) { $base=[IO.Path]::GetTempPath() }
    $path=Join-Path $base ('pitr-backup-'+$Label+'-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($path)
    $script:Origins.Add($path)
    return $path
}
function New-TestBackupDestination([string]$FixtureRoot) {
    # Exercise native destination validation on Windows, not a safety bypass.
    # Hosted runners expose their workspace/temp disk separately from the OS disk.
    if ($env:OS -eq 'Windows_NT') {
        if (-not $env:RUNNER_TEMP) { throw 'Windows backup fixtures require a separate RUNNER_TEMP volume.' }
        $mediaRoot=Join-Path $env:RUNNER_TEMP ('pitr-backup-media-'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($mediaRoot)
        $script:Origins.Add($mediaRoot)
        return (Join-Path $mediaRoot 'PITR-Backups')
    }
    return (Join-Path $FixtureRoot 'media/PITR-Backups')
}
function New-TestDirectory([string]$Path) {
    if(-not [IO.Directory]::Exists($Path)) { $null=[IO.Directory]::CreateDirectory($Path) }
    return $Path
}
function New-TestFile([string]$Path,[string]$Content) {
    $parent=Split-Path $Path -Parent
    if($parent -and -not [IO.Directory]::Exists($parent)) { $null=[IO.Directory]::CreateDirectory($parent) }
    $utf8=New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path,$Content,$utf8)
    return $Path
}
function New-BinaryTestFile([string]$Path,[int]$Length,[byte]$Seed) {
    $parent=Split-Path $Path -Parent
    if($parent -and -not [IO.Directory]::Exists($parent)) { $null=[IO.Directory]::CreateDirectory($parent) }
    $bytes=New-Object byte[] $Length
    for($i=0;$i -lt $Length;$i++) { $bytes[$i]=[byte](($i*31+$Seed) % 251) }
    [IO.File]::WriteAllBytes($Path,$bytes)
    return $Path
}
function New-FailureFixtureFile([string]$Root,[string[]]$RelativePaths) {
    $path=Join-Path $Root ('failure-fixture-'+[guid]::NewGuid().ToString('N')+'.txt')
    $utf8=New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllLines($path,[string[]]$RelativePaths,$utf8)
    return $path
}
function Get-ManifestEntries($Manifest) { return @($Manifest.Entries) }
function Get-EntryFor($Manifest,[string]$RelativePath) {
    return @($Manifest.Entries | Where-Object { $_.RelativePath -eq $RelativePath })
}
function Get-GenerationOf($Manifest) { return (Split-Path $Manifest.ManifestPath -Parent) }
function New-Sources([string]$Path) {
    $identity=Get-PitrVolumeIdentity -Path $Path
    return @([pscustomobject]@{
        Id='test-source-'+(New-PitrStableId -Text $Path).Substring(0,12)
        Path=$Path
        ProfileSid=$null
        SourceVolumeId=$identity.VolumeId
        Category='Extra'
        DisplayName=(Split-Path $Path -Leaf)
        IsPublic=$false
        Complete=$false
        Warnings=@($identity.Warnings)
    })
}

$realWindows=($env:OS -eq 'Windows_NT')
$hostIsWindows=(Get-PitrWindowsHost)

# ---------------------------------------------------------------------------
# The engine must not be able to claim a backup it cannot evidence, and the
# manifest it writes must be writable more than once in a process: compile-time
# functions, no PSCustomObject property lists.
# ---------------------------------------------------------------------------
$missingFunctions=@()
foreach($name in @('New-PitrBackup','Resume-PitrBackup','Test-PitrBackup','Install-PitrRecoveryPackage')) {
    if(-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) { $missingFunctions += $name }
}
Assert-Equal '' ($missingFunctions -join ',') 'the four contract functions exist'

# ---------------------------------------------------------------------------
# A real, small backup, end to end, in a test-owned tree.
# ---------------------------------------------------------------------------
$treeRoot=New-TestRoot 'tree'
$sourceRoot=New-TestDirectory (Join-Path $treeRoot 'work/profile A')
$destination=New-TestBackupDestination $treeRoot
$null=New-TestDirectory $destination
New-TestFile (Join-Path $sourceRoot 'notes.txt') 'alpha'
New-BinaryTestFile (Join-Path $sourceRoot 'data.bin') 300000 7
New-TestFile (Join-Path $sourceRoot 'nested/deep/value.txt') 'beta'
$null=New-TestDirectory (Join-Path $sourceRoot 'nested/empty-folder')
New-TestFile (Join-Path $sourceRoot 'startup-link.bat') '@echo off'
New-TestFile (Join-Path $sourceRoot 'AppData/settings.txt') 'advanced fixture'
$sources=New-Sources $sourceRoot

$phases=New-Object 'Collections.Generic.List[string]'
$progressObjects=New-Object 'Collections.Generic.List[object]'
$missingProgressField=New-Object 'Collections.Generic.List[string]'
$cbProgress={
    param($p)
    $progressObjects.Add($p)
    foreach($field in @('Phase','Profile','File','FilesProcessed','BytesProcessed','TotalBytes','ErrorCount')) {
        if($null -eq $p.PSObject.Properties[$field]) { $missingProgressField.Add($field) }
    }
    if($phases.Count -eq 0 -or $phases[$phases.Count-1] -ne $p.Phase) { $phases.Add($p.Phase) }
}
$backup=New-PitrBackup -Sources $sources -Destination $destination -Scope 'Custom' -Progress $cbProgress

Assert-Equal 'CopyCompleted' $backup.State 'a completed copy is reported as CopyCompleted, not complete'
Assert-Equal 'LiveNotApplicationConsistent' $backup.Consistency 'the copy is labelled live, not application consistent'
Assert-Equal 'Live' $backup.SourceView 'the source view is recorded as live'
Assert-True ($null -ne $backup.ManifestPath) 'the returned manifest carries a runtime ManifestPath'
Assert-True ([IO.File]::Exists($backup.ManifestPath)) 'the manifest file exists on disk'
Assert-Equal 'manifest.json' (Split-Path $backup.ManifestPath -Leaf) 'the manifest is named manifest.json'
Assert-Equal 0 $missingProgressField.Count ('progress reports every contract field; missing: '+($missingProgressField -join ','))
Assert-True ($progressObjects.Count -gt 0) 'progress was reported'
Assert-True ($phases -contains 'Copy') 'progress reported a Copy phase'
Assert-True ($phases -contains 'CopyCompleted') 'progress reported the CopyCompleted phase'

$generation=Get-GenerationOf $backup
$generationName=Split-Path $generation -Leaf
Assert-Equal ([Environment]::MachineName) (Split-Path (Split-Path $generation -Parent) -Leaf) 'generations live under their computer identity'
Assert-Equal 'PITR-Backups' (Split-Path (Split-Path (Split-Path $generation -Parent) -Parent) -Leaf) 'generations live under PITR-Backups/COMPUTER'
Assert-True ($generationName -match '^\d{8}-\d{6}_[0-9a-f]{8}$') ('the generation folder is <timestamp>_<short-id>: '+$generationName)
foreach($required in @('manifest.json','backup-status.json','backup-log.txt')) {
    Assert-True ([IO.File]::Exists((Join-Path $generation $required))) ('the generation contains '+$required)
}
Assert-True ([IO.Directory]::Exists((Join-Path $generation 'extra-folders'))) 'custom data has its own payload tree'
$extraFolder=Join-Path $generation 'extra-folders'
Assert-True ([IO.Directory]::Exists($extraFolder)) 'a custom source is stored under extra-folders/'
Assert-True ((Get-ChildItem -Recurse -File -LiteralPath $extraFolder).Count -ge 4) 'the stored extra folders hold the copied files'
Assert-Equal 0 @(Get-ChildItem -Recurse -File -LiteralPath $generation -Force | Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '.*.tmp' }).Count 'no temporary copy files are left behind'

# Every selected object is accounted for, and the accounting adds up.
$entries=Get-ManifestEntries $backup
$entryCount=$entries.Count
$copiedCount=@($entries | Where-Object { $_.CopyStatus -eq 'Copied' }).Count
$skippedCount=@($entries | Where-Object { $_.CopyStatus -eq 'Skipped' }).Count
$failedCount=@($entries | Where-Object { $_.CopyStatus -eq 'Failed' }).Count
$pendingCount=@($entries | Where-Object { $_.CopyStatus -eq 'Pending' }).Count
Assert-Equal 0 $pendingCount 'no selected object is left unaccounted for'
Assert-Equal $entryCount ($copiedCount+$skippedCount+$failedCount) 'every entry is Copied, Skipped or Failed'
Assert-Equal $entryCount $backup.Counts.Expected 'the manifest counts agree with the entry list'
Assert-Equal $copiedCount $backup.Counts.Copied 'the copied count agrees with the entry list'
Assert-Equal $skippedCount $backup.Counts.Skipped 'the skipped count agrees with the entry list'
Assert-Equal $failedCount $backup.Counts.Failed 'the failed count agrees with the entry list'
Assert-Equal 0 $skippedCount 'a clean live copy skips nothing'
Assert-Equal 0 $failedCount 'a clean live copy fails nothing'

$notesEntry=Get-EntryFor $backup 'notes.txt'
Assert-Equal 1 $notesEntry.Count 'the plain file was inventoried'
Assert-Equal 'File' $notesEntry[0].Type 'the plain file is typed File'
Assert-Equal 'Copied' $notesEntry[0].CopyStatus 'the plain file was copied'
Assert-Equal 5 $notesEntry[0].Length 'the recorded length is the stored length'
Assert-True ($notesEntry[0].Sha256 -match '^[0-9a-f]{64}$') 'the copied file records a SHA-256'
Assert-Equal (Get-PitrHash -Path (Join-Path $sourceRoot 'notes.txt')) $notesEntry[0].Sha256 'the recorded hash is the hash of the copied bytes'
$storedNotes=Join-Path $generation $notesEntry[0].BackupRelativePath
Assert-True ([IO.File]::Exists($storedNotes)) 'the copied file exists in the generation'
Assert-Equal 'alpha' ([IO.File]::ReadAllText($storedNotes)) 'the stored bytes are the source bytes'
Assert-Equal (Get-PitrHash -Path $storedNotes) $notesEntry[0].Sha256 'the stored bytes hash to the recorded value'

$emptyEntry=Get-EntryFor $backup 'nested/empty-folder'
Assert-Equal 1 $emptyEntry.Count 'an empty folder is recorded'
Assert-Equal 'Directory' $emptyEntry[0].Type 'an empty folder is recorded as a Directory'
Assert-True ([IO.Directory]::Exists((Join-Path $generation $emptyEntry[0].BackupRelativePath))) 'the empty folder exists in the generation'

$sensitiveEntry=Get-EntryFor $backup 'startup-link.bat'
Assert-Equal 1 $sensitiveEntry.Count 'an executable script is inventoried'
Assert-True $sensitiveEntry[0].IsSensitive 'an executable script is marked sensitive'
$advancedEntry=$entries | Where-Object { $_.IsAdvanced } | Select-Object -First 1
Assert-True ($null -ne $advancedEntry) 'a live scoped entry is marked advanced'

# The copy is a real copy: the source is untouched and nothing was deleted or moved.
Assert-Equal 'alpha' ([IO.File]::ReadAllText((Join-Path $sourceRoot 'notes.txt'))) 'the source file is unchanged'
Assert-Equal 5 (New-Object IO.FileInfo((Join-Path $sourceRoot 'notes.txt'))).Length 'the source file length is unchanged'
Assert-True ((Get-ChildItem -Recurse -File -LiteralPath $sourceRoot).Count -ge 4) 'no source file was deleted or moved'
Assert-Equal 1 @(Get-ChildItem -LiteralPath (Split-Path $generation -Parent) -Directory).Count 'exactly one generation exists: no overwrite and no duplicate'

# ---------------------------------------------------------------------------
# A second backup to the same destination must create a new generation.
# ---------------------------------------------------------------------------
$second=New-PitrBackup -Sources $sources -Destination $destination -Scope 'Custom'
Assert-True ($second.BackupId -ne $backup.BackupId) 'a second backup is a new generation, not an overwrite'
Assert-True ((Get-GenerationOf $second) -ne $generation) 'the second generation uses a different folder'
Assert-True ([IO.File]::Exists($backup.ManifestPath)) 'the first generation still exists after the second backup'
Assert-Equal 2 @(Get-ChildItem -LiteralPath (Split-Path $generation -Parent) -Directory).Count 'both generations remain on the destination'

# ---------------------------------------------------------------------------
# Full verification (hash recomputation) and quick verification (metadata).
# ---------------------------------------------------------------------------
$verified=Test-PitrBackup -ManifestPath $second.ManifestPath -Mode Full
Assert-Equal 'Verified' $verified.State 'a clean full verification reaches Verified'
Assert-Equal $verified.Counts.Copied $verified.Counts.Verified 'every copied file is verified'
Assert-Equal 'LiveNotApplicationConsistent' $verified.Consistency 'verification does not upgrade the consistency claim'
$allFull=@($verified.Entries | Where-Object { $_.CopyStatus -eq 'Copied' -and $_.VerificationStatus -ne 'FullVerified' }).Count
Assert-Equal 0 $allFull 'a full pass marks every copied file FullVerified'
Assert-Equal 'FullVerified' (Get-EntryFor $verified 'notes.txt')[0].VerificationStatus 'the file entry is FullVerified'

$quick=Test-PitrBackup -ManifestPath $second.ManifestPath -Mode Quick
Assert-Equal 'CompletedWithWarnings' $quick.State 'a quick pass never claims the strongest state'
Assert-Equal 'FullVerified' (Get-EntryFor $quick 'notes.txt')[0].VerificationStatus 'a quick pass never downgrades a FullVerified file'
Assert-True ([IO.File]::Exists($second.ManifestPath)) 'the manifest still exists after quick verification'

# ---------------------------------------------------------------------------
# A corrupted backup byte is detected by hash, and the state cannot stay Verified.
# ---------------------------------------------------------------------------
$victim=Join-Path $generation $notesEntry[0].BackupRelativePath
$victimLength=(New-Object IO.FileInfo($victim)).Length
$stream=New-Object IO.FileStream($victim,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try { $stream.Position=$victimLength-1; $stream.WriteByte(90) } finally { $stream.Dispose() }
Assert-Equal $victimLength (New-Object IO.FileInfo($victim)).Length 'the corrupted file keeps its original length, so only a hash can catch it'
$corrupt=Test-PitrBackup -ManifestPath $backup.ManifestPath -Mode Full
Assert-True ($corrupt.State -ne 'Verified') ('a corrupted backup is never Verified; state was '+$corrupt.State)
Assert-True (@($corrupt.Entries | Where-Object { $_.VerificationStatus -eq 'Failed' }).Count -ge 1) 'the corrupted file has failed verification separately from the copy outcome'
$corruptEntry=(Get-EntryFor $corrupt 'notes.txt')[0]
Assert-Equal 'Failed' $corruptEntry.VerificationStatus 'the corrupted entry is marked Failed'
Assert-Contains $corruptEntry.Error 'hash' 'the failure explains that the hash did not match'
Assert-Equal 'Copied' $corruptEntry.CopyStatus 'verification never rewrites the copy outcome'

# ---------------------------------------------------------------------------
# Interruption and resume: hashes are re-validated, finished files are kept.
# ---------------------------------------------------------------------------
$cancelRoot=New-TestRoot 'cancel'
$cancelSource=New-TestDirectory (Join-Path $cancelRoot 'big/profile')
$cancelDestination=New-TestBackupDestination $cancelRoot
$null=New-TestDirectory $cancelDestination
for($i=0;$i -lt 6;$i++) { New-BinaryTestFile (Join-Path $cancelSource ('blob-'+$i+'.bin')) 400000 ($i+3) }
$cancelSources=New-Sources $cancelSource
$cancelHash=[hashtable]::Synchronized(@{ Cancelled=$false; Events=(New-Object 'Collections.Generic.List[string]') })
$cancelProgress={
    param($p)
    $cancelHash.Events.Add(([string]$p.Phase+':'+[string]$p.FilesProcessed))
    if($p.Phase -eq 'Copy' -and $p.FilesProcessed -ge 2) { $cancelHash.Cancelled=$true }
}.GetNewClosure()
$interrupted=New-PitrBackup -Sources $cancelSources -Destination $cancelDestination -Scope 'Custom' -Progress $cancelProgress -Cancellation $cancelHash
if($interrupted.State -ne 'Interrupted') { throw ('Cancellation regression: state='+$interrupted.State+' flag='+$cancelHash.Cancelled+' events='+($cancelHash.Events -join ',')) }
Assert-Equal 'Interrupted' $interrupted.State 'a cancelled copy leaves an Interrupted generation, never a complete one'
$interruptedPath=$interrupted.ManifestPath
$interruptedGeneration=Get-GenerationOf $interrupted
$interruptedRoleNames=$env:PITR_FORCE_WINDOWS_HOST
$keptCopied=@($interrupted.Entries | Where-Object { $_.CopyStatus -eq 'Copied' })
Assert-True ($keptCopied.Count -ge 1) 'cancellation keeps the files that were already copied'
$keptFile=Join-Path $interruptedGeneration $keptCopied[0].BackupRelativePath
Assert-True ([IO.File]::Exists($keptFile)) 'a file copied before the cancellation is still on disk'
Assert-Equal (Get-PitrHash -Path $keptFile) $keptCopied[0].Sha256 'the kept file still matches its recorded hash'
Assert-Equal 0 @($interrupted.Entries | Where-Object { $_.CopyStatus -eq 'Pending' -and $_.Type -eq 'File' -and [IO.File]::Exists((Join-Path $interruptedGeneration $_.BackupRelativePath)) }).Count 'no half-written file was left for a pending entry'
$strayParts=@(Get-ChildItem -Recurse -File -LiteralPath $interruptedGeneration -Force | Where-Object { $_.Name -like '.pitr-part-*' })
Assert-Equal 0 $strayParts.Count 'no partial copy file is left behind after cancellation'

# Resume validates the previously copied hashes instead of trusting the manifest.
$beforeResume=@($interrupted.Entries | Where-Object { $_.CopyStatus -eq 'Copied' }).Count
$keptFileSizeBefore=(New-Object IO.FileInfo($keptFile)).Length
# Corrupt a completed object while the generation is still Interrupted. Resume must
# revalidate rather than trusting the old Copied status.
$stream=New-Object IO.FileStream($keptFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try { $stream.Position=0; $stream.WriteByte(1) } finally { $stream.Dispose() }
$resumed=Resume-PitrBackup -ManifestPath $interruptedPath
Assert-Equal 'CopyCompleted' $resumed.State 'resume finishes the copy'
Assert-Equal 0 @($resumed.Entries | Where-Object { $_.CopyStatus -eq 'Pending' }).Count 'resume leaves no unaccounted object'
Assert-Equal 0 $resumed.Counts.Failed 'resume completes the remaining files'
Assert-Equal 0 $resumed.Counts.Skipped 'resume skips nothing in a portable fixture'
Assert-Equal 6 @($resumed.Entries | Where-Object { $_.Type -eq 'File' -and $_.CopyStatus -eq 'Copied' }).Count 'resume scans all six source files, including those never reached before cancellation'
$repairedPayload=Join-Path $interruptedGeneration (Get-EntryFor $resumed $keptCopied[0].RelativePath)[0].BackupRelativePath
Assert-Equal (Get-PitrHash -Path (Join-Path $cancelSource $keptCopied[0].RelativePath)) (Get-PitrHash -Path $repairedPayload) 'resumed repaired payload matches the live source bytes'
Assert-Equal $keptFileSizeBefore (New-Object IO.FileInfo($keptFile)).Length 'the re-validation pass retains the intact file length'
Assert-True ([IO.File]::Exists($keptFile)) 'resume preserves even the previous damaged payload for inspection'
# Keep the generation unverified while exercising repair. Verified generations are immutable to resume.

# Resume repaired the damaged object from the live source, then verification may finish.
$interruptedCopy=@($interrupted.Entries | Where-Object { $_.CopyStatus -eq 'Copied' })[0]
$repairedEntry=(Get-EntryFor $resumed $interruptedCopy.RelativePath)[0]
Assert-Equal (Get-PitrHash -Path (Join-Path $cancelSource $interruptedCopy.RelativePath)) $repairedEntry.Sha256 'the re-copied file matches the live source'
Assert-Equal 'Verified' (Test-PitrBackup -ManifestPath $interruptedPath -Mode Full).State 'the repaired generation verifies'

# ---------------------------------------------------------------------------
# A Verified generation must refuse to be mutated by resume.
# ---------------------------------------------------------------------------
$verifiedGeneration=$interruptedPath
$verifiedManifestBefore=[IO.File]::ReadAllBytes($verifiedGeneration)
$refusedViaResume=$false
try { $null=Resume-PitrBackup -ManifestPath $verifiedGeneration } catch { $refusedViaResume=$true }
Assert-True $refusedViaResume 'resume refuses a Verified generation'
$verifiedManifestAfter=[IO.File]::ReadAllBytes($verifiedGeneration)
Assert-Equal ([Convert]::ToBase64String($verifiedManifestBefore)) ([Convert]::ToBase64String($verifiedManifestAfter)) 'the refused resume did not touch the verified manifest'

# ---------------------------------------------------------------------------
# Skipped and failed objects are accounted for with a reason.
# ---------------------------------------------------------------------------
$skipRoot=New-TestRoot 'skip'
$skipSource=New-TestDirectory (Join-Path $skipRoot 'mixed/profile')
$skipDestination=New-TestBackupDestination $skipRoot
$null=New-TestDirectory $skipDestination
New-TestFile (Join-Path $skipSource 'fine.txt') 'fine'
New-TestFile (Join-Path $skipSource 'readable.txt') 'readable'
New-TestFile (Join-Path $skipSource 'cloud-placeholder.dat') 'placeholder'
New-TestFile (Join-Path $skipSource 'unsupported-object') 'unsupported'
$attributesFixture=Join-Path $skipRoot 'attributes.txt'
[IO.File]::WriteAllText($attributesFixture,'cloud-placeholder.dat',(New-Object Text.UTF8Encoding($false)))
$unsupportedFixture=Join-Path $skipRoot 'unsupported.txt'
[IO.File]::WriteAllText($unsupportedFixture,'unsupported-object',(New-Object Text.UTF8Encoding($false)))
$failureFixture=New-FailureFixtureFile $skipRoot @('fine.txt')
$env:PITR_BACKUP_ATTRIBUTES_FIXTURE=$attributesFixture
$env:PITR_BACKUP_UNSUPPORTED_FIXTURE=$unsupportedFixture
$env:PITR_BACKUP_FAILURE_FIXTURE=$failureFixture
$mixed=$null
try { $mixed=New-PitrBackup -Sources (New-Sources $skipSource) -Destination $skipDestination -Scope 'Custom' } finally {
    Remove-Item Env:PITR_BACKUP_ATTRIBUTES_FIXTURE -ErrorAction SilentlyContinue
    Remove-Item Env:PITR_BACKUP_UNSUPPORTED_FIXTURE -ErrorAction SilentlyContinue
    Remove-Item Env:PITR_BACKUP_FAILURE_FIXTURE -ErrorAction SilentlyContinue
}
Assert-Equal 2 @($mixed.Entries | Where-Object { $_.CopyStatus -eq 'Skipped' }).Count 'both placeholder and unsupported objects are accounted as skipped'
$skipped=(@($mixed.Entries | Where-Object { $_.RelativePath -eq 'cloud-placeholder.dat' }))[0]
Assert-Equal 'ReparsePoint' $skipped.Type 'the placeholder is recorded as a reparse object, not dropped'
Assert-True ($skipped.Error -match 'cloud|placeholder|reparse') 'placeholder limitation is explicitly reported'
Assert-True (-not [string]::IsNullOrWhiteSpace($skipped.Error)) 'the skipped object carries a reason'
Assert-Equal 'Pending' $skipped.VerificationStatus 'a skipped object is never claimed as verified'
Assert-True (-not [IO.File]::Exists((Join-Path (Get-GenerationOf $mixed) $skipped.BackupRelativePath))) 'nothing was copied for the skipped object'
Assert-Equal 1 @($mixed.Entries | Where-Object { $_.CopyStatus -eq 'Failed' }).Count 'the unreadable object is failed, not omitted'
$failedEntry=(@($mixed.Entries | Where-Object { $_.CopyStatus -eq 'Failed' }))[0]
Assert-True (-not [string]::IsNullOrWhiteSpace($failedEntry.Error)) 'the failed object carries a reason'
Assert-Equal 1 @($mixed.Entries | Where-Object { $_.CopyStatus -eq 'Copied' }).Count 'the readable object is still copied'
Assert-True ($mixed.Warnings.Count -ge 1) 'unaccounted success is warned about'

# Evidence cannot be forged from a skipped or failed object.
$mixedVerified=Test-PitrBackup -ManifestPath $mixed.ManifestPath -Mode Full
Assert-True ($mixedVerified.State -ne 'Verified') ('a generation with skipped or failed objects never becomes Verified; state was '+$mixedVerified.State)
Assert-Equal 'CompletedWithWarnings' $mixedVerified.State 'a generation with unaccounted success ends CompletedWithWarnings'
Assert-True ($mixedVerified.Counts.Skipped -ge 1) 'the skipped count survives verification'
Assert-True ($mixedVerified.Counts.Failed -ge 1) 'the failed count survives verification'

# ---------------------------------------------------------------------------
# Verification and resume restart safely: repeated calls converge.
# ---------------------------------------------------------------------------
$again=Test-PitrBackup -ManifestPath $backup.ManifestPath -Mode Full
Assert-True ($again.State -ne 'Verified') 're-verifying the corpus with a corrupted file stays honest'
Assert-Equal $again.Counts.Failed $corrupt.Counts.Failed 'a restarted verification reports the same failures'
$null=Test-PitrBackup -ManifestPath $interruptedPath -Mode Full
Assert-Equal 'Verified' (Test-PitrBackup -ManifestPath $interruptedPath -Mode Full).State 'a restarted verification rechecks an intact verified generation'

# ---------------------------------------------------------------------------
# Destination and source validation is enforced by Platform.ps1, not re-implemented here.
# ---------------------------------------------------------------------------
$sameVolumeRoot=New-TestRoot 'samevolume'
$sameVolumeSource=New-TestDirectory (Join-Path $sameVolumeRoot 'data/profile')
New-TestFile (Join-Path $sameVolumeSource 'a.txt') 'a'
$sameVolumeDestination=Join-Path $sameVolumeRoot 'backups/PITR-Backups'
$null=New-TestDirectory $sameVolumeDestination
if($realWindows) {
    $osDestination=Join-Path $env:SystemRoot ('PITR-refused-'+[guid]::NewGuid().ToString('N'))
    $refusedSameVolume=$false
    try { $null=New-PitrBackup -Sources (New-Sources $sameVolumeSource) -Destination $osDestination -Scope 'Custom' } catch { $refusedSameVolume=$true }
    Assert-True $refusedSameVolume 'the actual OS-volume destination is refused'
    Assert-False (Test-Path -LiteralPath $osDestination) 'OS-volume refusal creates no generation'
} else { Assert-Skip $false 'actual OS-volume refusal requires native Windows volume identity; fixtures do not establish it' | Out-Null }
$nestedDestination=Join-Path $sameVolumeSource 'inner/PITR-Backups'
$refusedNested=$false
try { $null=New-PitrBackup -Sources (New-Sources $sameVolumeSource) -Destination $nestedDestination -Scope 'Custom' } catch { $refusedNested=$true }
Assert-True $refusedNested 'a destination inside the source is refused'
$refusedNoSources=$false
try { $null=New-PitrBackup -Sources @() -Destination $sameVolumeDestination -Scope 'Custom' } catch { $refusedNoSources=$true }
Assert-True $refusedNoSources 'a backup with no selected object is refused'

# ---------------------------------------------------------------------------
# The recovery package.
# ---------------------------------------------------------------------------
$packageGeneration=$second.ManifestPath
$packageRoot=Split-Path $packageGeneration -Parent
$applicationSource=$root
$recoveryFolder=Join-Path $packageRoot 'recovery'
if([IO.Directory]::Exists($recoveryFolder)) { [IO.Directory]::Delete($recoveryFolder,$true) }
$packageManifest=Read-PitrManifest -ManifestPath $packageGeneration
$package=$null
$packageThrew=$false
try { $package=Install-PitrRecoveryPackage -BackupRoot $packageRoot -RecoverySource $applicationSource -Manifest $packageManifest } catch { $packageThrew=$true }
Assert-False $packageThrew 'installing the recovery package does not throw'
if($null -ne $package) {
    Assert-True $package.Installed 'the recovery package reports itself installed when every dependency is present'
    Assert-True ([IO.File]::Exists((Join-Path $recoveryFolder 'src/backup/Backup.ps1'))) 'the recovery package ships the backup module'
    Assert-True ([IO.File]::Exists((Join-Path $recoveryFolder 'src/backup/Manifest.ps1'))) 'the recovery package ships the manifest module'
    Assert-True ([IO.File]::Exists((Join-Path $recoveryFolder 'src/backup/Platform.ps1'))) 'the recovery package ships the platform module'
    Assert-True ([IO.File]::Exists((Join-Path $recoveryFolder 'src/backup/Entry.ps1'))) 'the recovery package ships the entry point'
    Assert-True ([IO.File]::Exists((Join-Path $recoveryFolder 'Start-Recovery.cmd'))) 'the recovery package ships the launcher'
    Assert-True ([IO.File]::Exists((Join-Path $recoveryFolder 'README.txt'))) 'the recovery package ships a readme'
    Assert-True ([IO.File]::Exists((Join-Path $recoveryFolder 'recovery-integrity.json'))) 'the recovery package ships an integrity inventory'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $recoveryFolder -File | Where-Object { $_.Name -like '*.tmp' }).Count 'no temporary package file is left behind'

    $inventory=Get-Content -LiteralPath (Join-Path $recoveryFolder 'recovery-integrity.json') -Raw | ConvertFrom-Json
    Assert-True ($inventory.Files.Count -ge 10) 'the integrity inventory lists every shipped file'
    $inventoryMismatch=@()
    foreach($file in $inventory.Files) {
        $shipped=Join-Path $recoveryFolder $file.Path
        if(-not [IO.File]::Exists($shipped)) { $inventoryMismatch += $file.Path; continue }
        if((Get-PitrHash -Path $shipped) -ne $file.Sha256) { $inventoryMismatch += $file.Path }
    }
    Assert-Equal '' ($inventoryMismatch -join ',') 'every inventory hash matches the shipped file'
    Assert-True ((New-Object IO.FileInfo((Join-Path $recoveryFolder 'src/backup/Backup.ps1'))).Length -gt 0) 'the shipped module has content'

    $launcher=Get-Content -LiteralPath (Join-Path $recoveryFolder 'Start-Recovery.cmd') -Raw
    Assert-Contains $launcher '%~dp0' 'the launcher resolves its own folder'
    Assert-Contains $launcher 'manifest.json' 'the launcher locates the manifest'
    Assert-True ($launcher -notmatch '(?i)\b[A-Z]:\\') 'the launcher contains no fixed drive letter'
    Assert-True ($launcher -notmatch '(?i)net use|\\\\[A-Za-z0-9_.-]+\\[A-Za-z0-9$_.-]+') 'the launcher reaches no network share'
    Assert-True ($launcher -notmatch '(?i)Start-Process|RunAs|^net session|Invoke-Expression|reg add|bcdedit|vssadmin|wmic shadowcopy') 'the launcher never elevates, evaluates or mutates the system'
    Assert-True ($launcher -match 'powershell\.exe.*-STA.*--gui') 'the launcher uses the supported Windows PowerShell STA GUI host'
    $launcherBytes=[IO.File]::ReadAllBytes((Join-Path $recoveryFolder 'Start-Recovery.cmd'))
    $launcherIsAscii=$true
    foreach($byte in $launcherBytes) { if($byte -gt 127) { $launcherIsAscii=$false } }
    Assert-True $launcherIsAscii 'the launcher is ASCII-only'
    Assert-True ($launcher -match "`r`n") 'the launcher uses CRLF line endings'
    Assert-True ($launcher -notmatch '(?<!\r)\n') 'the launcher has no bare LF line endings'
    $launcherText=[Text.Encoding]::UTF8.GetString($launcherBytes)
    Assert-True (-not $launcherText.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)) 'the launcher has no byte order mark'
    $readme=Get-Content -LiteralPath (Join-Path $recoveryFolder 'README.txt') -Raw
    Assert-Contains $readme 'LiveNotApplicationConsistent' 'the readme states the live consistency classification'
    Assert-Contains $readme 'Explorer' 'the readme says files remain readable in Explorer'
    Assert-True ($readme -match '(?i)not (application|database)[- ]consistent') 'the readme explicitly disclaims application consistency'

    # A missing dependency must fail loudly, never claim a usable package.
    $brokenSource=New-TestDirectory (Join-Path (New-TestRoot 'broken') 'app/src/backup')
    foreach($name in @('Platform.ps1','Manifest.ps1','Recovery.ps1','Cli.ps1','Entry.ps1','Localization.ps1','Ui.ps1')) {
        New-TestFile (Join-Path $brokenSource $name) '# placeholder'
    }
    $brokenGeneration=New-TestDirectory (Join-Path (New-TestRoot 'brokengen') 'gen')
    $broken=$null
    $brokenThrew=$false
    try { $broken=Install-PitrRecoveryPackage -BackupRoot $brokenGeneration -RecoverySource (Split-Path (Split-Path $brokenSource -Parent) -Parent) } catch { $brokenThrew=$true }
    Assert-False $brokenThrew 'a missing dependency is reported, not thrown as a crash'
    if($null -ne $broken) {
        Assert-False $broken.Installed 'a package missing Backup.ps1 is never reported as installed'
        Assert-Contains $broken.Error 'Backup.ps1' 'the failure names the missing module'
    }
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $brokenGeneration -Directory).Count 'a refused package writes no recovery folder'

    $absolute=Install-PitrRecoveryPackage -BackupRoot $packageRoot -RecoverySource (Join-Path $treeRoot 'does-not-exist')
    Assert-False $absolute.Installed 'an unavailable application source never yields a usable package'
    Assert-True (-not [string]::IsNullOrWhiteSpace($absolute.Error)) 'the unavailable source is explained'

    # The launcher path resolution itself, exercised on the real end of the package contract.
    $manifestRelative=Join-Path $recoveryFolder '..'
    Assert-True ([IO.File]::Exists((Join-Path $manifestRelative 'manifest.json'))) 'the launcher target manifest.json sits next to the recovery folder'
    if(-not $realWindows) {
        Assert-Skip $false 'actual CMD launcher execution (cmd.exe), fixed-drive-letter absence at runtime and Windows PowerShell 5.1 execution are pending real Windows CI' | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Platform validation must keep working through the engine's use of it.
# ---------------------------------------------------------------------------
Assert-Equal 'PITR-Backups' (Split-Path (Get-PitrBackupDestinationRoot -Destination $destination) -Leaf) 'the destination root resolves to PITR-Backups'
$windowsOnlyChecks=@(
    'native volume identity (volume GUID + serial) and drive-letter semantics',
    'a destination on the operating system volume refused through a real drive letter',
    'reparse points, junctions and directory symlinks encountered in a real profile tree',
    'EFS encryption and cloud placeholder attributes on real files',
    'alternate data streams, hardlinks, sparse files, long paths and denied ACLs',
    'real Windows PowerShell 5.1 execution of the engine and the whole suite',
    'actual CMD execution of Start-Recovery.cmd from an extracted portable folder'
)
if(-not $realWindows) {
    foreach($reason in $windowsOnlyChecks) {
        Assert-Skip $false ($reason+' (pending real Windows CI)') | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Managed fixtures are removed; nothing outside the test GUID roots is touched.
# ---------------------------------------------------------------------------
foreach($origin in $script:Origins) {
    if($origin -and [IO.Directory]::Exists($origin) -and (Split-Path $origin -Leaf).StartsWith('pitr-backup-')) {
        try { [IO.Directory]::Delete($origin,$true) } catch { }
    }
}
if($script:Skips.Count -gt 0) { foreach($skip in $script:Skips) { Write-Output ('SKIP (pending real Windows CI): '+$skip) } }
Write-Output ('Backup assertions passed: '+$script:Passed+' checks, '+$script:Skips.Count+' skipped. Real Windows host: '+$realWindows+'. Forced Windows host: '+($hostIsWindows -and -not $realWindows)+'.')
if($script:Failures.Count -gt 0) {
    foreach($failure in $script:Failures) { [Console]::Error.WriteLine('FAIL '+$failure) }
    throw ('Backup tests failed: '+$script:Failures.Count+' of '+($script:Failures.Count+$script:Passed)+' assertions.')
}