$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Platform.ps1')
. (Join-Path $root 'src/backup/Manifest.ps1')
. (Join-Path $root 'src/backup/Backup.ps1')
. (Join-Path $root 'src/backup/Recovery.ps1')

$script:Passed=0
$script:Failures=New-Object 'Collections.Generic.List[string]'
$script:Skips=New-Object 'Collections.Generic.List[string]'
$script:Scratch=[IO.Path]::GetTempPath()
if ($env:TMPDIR) { $script:Scratch=$env:TMPDIR }
$script:FixtureRoots=New-Object 'Collections.Generic.List[string]'
function Assert-True($Value,[string]$Message) {
    if($Value) { $script:Passed++ } else { $script:Failures.Add($Message) }
}
function Assert-Equal($Expected,$Actual,[string]$Message) {
    if($Expected -eq $Actual) { $script:Passed++ } else { $script:Failures.Add($Message+' expected ['+$Expected+'] actual ['+$Actual+']') }
}
function New-PayloadFixture([string]$Kind) {
    $base=Join-Path $script:Scratch ('pitr-payload-boundary-'+$Kind+'-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($base)
    $script:FixtureRoots.Add($base)
    $backup=Join-Path $base 'generation'
    $outside=Join-Path $base 'outside'
    $source=Join-Path $base 'source'
    $current=Join-Path $base 'approved-current'
    foreach($directory in @($backup,$outside,$source,$current)) { $null=[IO.Directory]::CreateDirectory($directory) }
    $relative='payload/item.txt'
    $outsideFile=Join-Path $outside 'item.txt'
    $sourceFile=Join-Path $source 'payload/item.txt'
    $currentFile=Join-Path $current 'payload/item.txt'
    $null=[IO.Directory]::CreateDirectory((Split-Path $sourceFile -Parent))
    $null=[IO.Directory]::CreateDirectory((Split-Path $currentFile -Parent))
    [IO.File]::WriteAllText($outsideFile,'external-content',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($sourceFile,'external-content',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($currentFile,'approved-current-bytes',(New-Object Text.UTF8Encoding($false)))
    $payloadParent=Join-Path $backup 'profiles/src-1/payload'
    $null=[IO.Directory]::CreateDirectory((Split-Path $payloadParent -Parent))
    if($Kind -in @('leaf','hardlink')) {
        $null=[IO.Directory]::CreateDirectory($payloadParent)
        $link=Join-Path $payloadParent 'item.txt'
        $linkType=if($Kind -eq 'hardlink'){'HardLink'}else{'SymbolicLink'}
        New-Item -ItemType $linkType -Path $link -Target $outsideFile -ErrorAction Stop | Out-Null
        $backupRelative='profiles/src-1/payload/item.txt'
    } else {
        $null=[IO.Directory]::CreateDirectory((Split-Path $payloadParent -Parent))
        New-Item -ItemType SymbolicLink -Path $payloadParent -Target $outside -ErrorAction Stop | Out-Null
        $backupRelative='profiles/src-1/payload/item.txt'
    }
    $manifestPath=Join-Path $backup 'manifest.json'
    $manifest=New-PitrManifest -BackupId ([guid]::NewGuid().ToString()) -Scope 'Custom' -ApplicationVersion 'boundary-test'
    $manifest.Sources=@([pscustomobject]@{ Id='src-1'; Path=$source; ProfileSid=$null; SourceVolumeId='fixture'; Category='Profile'; DisplayName='fixture' })
    $entry=New-PitrManifestEntry -Id ('entry-'+$Kind) -SourceId 'src-1' -RelativePath $relative -BackupRelativePath $backupRelative -Type 'File' -Length (New-Object IO.FileInfo($outsideFile)).Length -CopyStatus 'Copied' -VerificationStatus 'Pending' -Sha256 (Get-PitrHash -Path $outsideFile)
    $manifest.Entries=@($entry)
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'Running'
    $manifest=Set-PitrManifestState -Manifest $manifest -State 'CopyCompleted'
    $null=Write-PitrManifest -ManifestPath $manifestPath -Manifest $manifest
    return [pscustomobject]@{ Root=$base; Backup=$backup; Outside=$outsideFile; Source=$source; Current=$current; ManifestPath=$manifestPath; EntryId=$entry.Id; Payload=(Join-Path $backup $backupRelative) }
}

if(-not [IO.Directory]::Exists($script:Scratch)) {
    $script:Skips.Add('required isolated scratch directory is unavailable: '+$script:Scratch)
} else {
    $realWindowsHost=($env:OS -eq 'Windows_NT')
    # Attempt the same disposable link fixtures on Windows; skip only explicit
    # link-privilege/support failures, never arbitrary manifest/setup errors.
    foreach($kind in @('leaf','parent-directory','hardlink')) {
            $fixture=$null
            try {
                try { $fixture=New-PayloadFixture $kind }
                catch {
                    if ($realWindowsHost -and $_.Exception.Message -match '(?i)privilege|not supported|requires elevation|access.*denied') {
                        $script:Skips.Add($kind+' Windows link fixture unavailable: '+$_.Exception.Message)
                        continue
                    }
                    throw
                }
                $verify=Test-PitrBackup -ManifestPath $fixture.ManifestPath -Mode Full
                Assert-True ($verify.State -ne 'Verified') ($kind+': Full verification must not claim Verified for external linked payload bytes')
                # Reverification must also degrade previously full-verified entries in Quick mode.
                $quickManifest=Read-PitrManifest -ManifestPath $fixture.ManifestPath
                $quickManifest.Entries[0].VerificationStatus='FullVerified'
                $quickManifest.State='Verified'
                $null=Write-PitrManifest -ManifestPath $fixture.ManifestPath -Manifest $quickManifest
                $quick=Test-PitrBackup -ManifestPath $fixture.ManifestPath -Mode Quick
                Assert-Equal 'Failed' $quick.Entries[0].VerificationStatus ($kind+': Quick verification must degrade a previously verified linked payload')
                Assert-True ($quick.State -ne 'Verified') ($kind+': Quick verification must not retain strongest state for a linked payload')
                $comparison=Compare-PitrBackup -ManifestPath $fixture.ManifestPath -Mappings @{ 'src-1'=$fixture.Current } -Deep
                $comparisonEntry=@($comparison.Entries | Where-Object { $_.Id -eq $fixture.EntryId })[0]
                Assert-Equal 'Unknown' $comparisonEntry.Classification ($kind+': deep comparison must mark linked payload Unknown')
                Assert-True (-not $comparison.ScanComplete) ($kind+': deep comparison must be incomplete for a linked payload')
                Assert-True (-not $comparison.Complete) ($kind+': complete must reflect the linked-payload boundary failure')
                $restore=Restore-PitrFiles -ManifestPath $fixture.ManifestPath -Mappings @{ 'src-1'=$fixture.Current } -EntryIds @($fixture.EntryId) -Conflict Replace -Execute
                $action=@($restore.Actions)[0]
                Assert-True (($action.Action -like 'Refused*') -or $action.Result -eq 'Failed') ($kind+': selected restore must explicitly refuse linked payload bytes, got '+$action.Action+'/'+$action.Result)
                Assert-Equal 'approved-current-bytes' ([IO.File]::ReadAllText((Join-Path $fixture.Current 'payload/item.txt'))) ($kind+': approved destination must remain untouched')
                Assert-Equal 'external-content' ([IO.File]::ReadAllText($fixture.Outside)) ($kind+': outside bytes must remain untouched by restore')
            } catch {
                $script:Failures.Add($kind+': unexpected test error: '+$_.Exception.Message)
            }
        }

        # Resume must not trust a linked payload even if its bytes happen to hash to the manifest.
        $resumeFixture=$null
        try {
            $resumeFixture=New-PayloadFixture 'resume-leaf'
            $manifest=Read-PitrManifest -ManifestPath $resumeFixture.ManifestPath
            # Build the interrupted on-disk state directly; the fixture is intentionally minimal.
            $manifest.State='Interrupted'
            $null=Write-PitrManifest -ManifestPath $resumeFixture.ManifestPath -Manifest $manifest
            # Resume's destination gate is stubbed only to isolate the real resume/payload logic
            # from unrelated platform volume policy. No source or backup filesystem operation is stubbed.
            function Test-PitrDestination {
                param([string]$Destination,[string[]]$Sources,[long]$RequiredBytes=0)
                return [pscustomobject]@{ VolumeId='fixture-destination'; Kind='Local'; CanonicalPath=$Destination; FileSystem='fixture'; Warnings=@() }
            }
            $resumed=Resume-PitrBackup -ManifestPath $resumeFixture.ManifestPath
            $resumedEntry=@($resumed.Entries | Where-Object { $_.SourceId -eq 'src-1' -and $_.RelativePath -eq 'payload/item.txt' })[0]
            $linkDamaged=($null -ne $resumedEntry) -and ($resumedEntry.CopyStatus -ne 'Copied' -or $resumedEntry.VerificationStatus -eq 'Failed' -or $resumedEntry.Error -match '(?i)reparse|symbolic|link|boundary')
            Assert-True $linkDamaged 'resume must refuse or explicitly record the linked payload as damaged, not adopt matching outside bytes'
            Assert-Equal 'external-content' ([IO.File]::ReadAllText($resumeFixture.Outside)) 'resume must not modify outside bytes'
        } catch {
            if ($realWindowsHost -and $_.Exception.Message -match '(?i)privilege|not supported|requires elevation|access.*denied') {
                $script:Skips.Add('Windows resume link fixture unavailable: '+$_.Exception.Message)
            } else { $script:Failures.Add('resume boundary: unexpected test error: '+$_.Exception.Message) }
        }
}
foreach($fixtureRoot in $script:FixtureRoots) {
    if([IO.Directory]::Exists($fixtureRoot)) { try { [IO.Directory]::Delete($fixtureRoot,$true) } catch { $script:Failures.Add('fixture cleanup failed: '+$fixtureRoot+' : '+$_.Exception.Message) } }
}
foreach($skip in $script:Skips) { Write-Output ('SKIP: '+$skip) }
Write-Output ('Payload boundary assertions passed: '+$script:Passed+'; skipped: '+$script:Skips.Count+'.')
if($script:Failures.Count -gt 0) {
    foreach($failure in $script:Failures) { [Console]::Error.WriteLine('FAIL '+$failure) }
    throw ('Payload boundary tests failed: '+$script:Failures.Count+' of '+($script:Failures.Count+$script:Passed)+' assertions.')
}
