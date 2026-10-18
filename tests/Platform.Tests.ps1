$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Platform.ps1')

# This suite is dependency-free: plain assertion functions, no Pester, no modules, no network.
# Two host concepts are tracked separately so a Linux run never reports a Windows behavior:
#   $realWindows  - the process really runs on a Windows OS ($env:OS -eq 'Windows_NT').
#   $hostIsWindows - Get-PitrWindowsHost: true on real Windows, or when the test-only hook
#                    PITR_FORCE_WINDOWS_HOST=1 forces the Windows code branches to run.
# Assertions on Windows CODE PATHS run under $hostIsWindows (so a Windows CI host exercises them
# through fixtures). Assertions on Windows KERNEL SEMANTICS (native volume identity, real drive
# letters, real reparse junctions/mount points, UNC path form) run under $realWindows and are
# otherwise SKIPPED with an explicit pending-real-Windows-CI reason, never failed and never
# claimed as verified.
$script:Passed=0
$script:Failures=New-Object 'Collections.Generic.List[string]'
$script:Skips=New-Object 'Collections.Generic.List[string]'
function Assert-True($Value,$Message) {
    if($Value) { $script:Passed++ } else { $script:Failures.Add('expected true: '+$Message) }
}
function Assert-Equal($Expected,$Actual,$Message) {
    if($Expected -eq $Actual) { $script:Passed++ } else { $script:Failures.Add('expected ['+$Expected+'] actual ['+$Actual+']: '+$Message) }
}
# Every refusal assertion also proves the negative control: the same call shape is exercised with
# a benign input that must NOT throw, so a broken probe cannot pass by refusing everything.
function Assert-Rejected($ScriptBlock,$Message,$ControlScriptBlock=$null) {
    $threw=$false
    try { $null=& $ScriptBlock } catch { $threw=$true }
    if($threw) {
        $script:Passed++
        if($null -ne $ControlScriptBlock) {
            $controlThrew=$false
            try { $null=& $ControlScriptBlock } catch { $controlThrew=$true }
            if($controlThrew) { $script:Failures.Add('negative control also refused: '+$Message) } else { $script:Passed++ }
        }
    } else {
        $script:Failures.Add('expected refusal: '+$Message)
    }
}
function Assert-Accepted($ScriptBlock,$Message) {
    try { $null=& $ScriptBlock; $script:Passed++ } catch { $script:Failures.Add('unexpected refusal ('+$_.Exception.Message+'): '+$Message) }
}
function Assert-Skip($Condition,[string]$Reason) {
    if(-not $Condition) { $script:Skips.Add($Reason) }
    return $Condition
}
function New-TestRoot([string]$Label) {
    $base=$env:TMPDIR
    if(-not $base) { $base=[IO.Path]::GetTempPath() }
    $path=Join-Path $base ('pitr-platform-'+$Label+'-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($path)
    return $path
}
function New-DestinationTestRoot([string]$Label) {
    # Test-PitrDestination must refuse the OS volume, and the default temp tree is on the OS
    # volume on a real Windows host, so destination fixtures use the runner's other disk.
    if((-not $env:TMPDIR) -and $env:OS -eq 'Windows_NT' -and $env:RUNNER_TEMP) {
        $path=Join-Path $env:RUNNER_TEMP ('pitr-dest-'+$Label+'-'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($path)
        return $path
    }
    return (New-TestRoot $Label)
}
function New-TestFile([string]$Path,[string]$Content) {
    $parent=Split-Path $Path -Parent
    if($parent -and -not [IO.Directory]::Exists($parent)) { $null=[IO.Directory]::CreateDirectory($parent) }
    $utf8=New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path,$Content,$utf8)
}
$origins=New-Object 'Collections.Generic.List[string]'
function Add-Origin([string]$Path) { $script:origins.Add($Path) }

$realWindows=($env:OS -eq 'Windows_NT')
$hostIsWindows=(Get-PitrWindowsHost)

# ---------------------------------------------------------------------------
# Test-PitrSafePath (platform independent; Windows name rules enforced on any host)
# ---------------------------------------------------------------------------
$safeRoot=New-TestRoot 'safe'
Add-Origin $safeRoot
$null=[IO.Directory]::CreateDirectory((Join-Path $safeRoot 'inner'))
New-TestFile (Join-Path $safeRoot 'inner/file.txt') 'x'
Assert-Equal 'inner/file.txt' (Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/file.txt') 'ordinary relative path accepted'
Assert-Equal 'inner' (Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/') 'trailing separator normalized'
Assert-Equal 'inner/file.txt' (Test-PitrSafePath -Root $safeRoot -RelativePath 'inner\\.\\file.txt') 'dot segment normalized'
Assert-Equal 'a/b' (Test-PitrSafePath -Root $safeRoot -RelativePath 'a//b') 'duplicate separators collapsed'
Assert-Equal 'inner/file.txt' (Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/file.txt') 'negative control: the accepted baseline still succeeds'
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath (' /file.txt') } 'leading space before a rooted relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'file.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '..' } 'parent segment itself' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '../escape.txt' } 'traversal above root' { Test-PitrSafePath -Root $safeRoot -RelativePath 'escape.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/../../escape.txt' } 'traversal escape below root' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/file.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'a/../../../etc/passwd' } 'deep traversal' { Test-PitrSafePath -Root $safeRoot -RelativePath 'a/b' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '.' } 'single dot relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '' } 'empty relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '   ' } 'whitespace relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '..\\secret.txt' } 'backslash traversal' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner\\file.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '\\absolute\\child.txt' } 'rooted relative name with backslash' { Test-PitrSafePath -Root $safeRoot -RelativePath 'absolute\\child.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'C:\\Windows\\System32\\cmd.exe' } 'drive rooted relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'Windows/System32/cmd.exe' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '/etc/passwd' } 'rooted unix relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'etc/passwd' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '\\\\.\\PhysicalDrive0' } 'device path relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/file.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '\\??\\C:\\Windows' } 'verbatim device path relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/file.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '\\\\server\\share\\file.txt' } 'UNC relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'server/share/file.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath '\\\\?\\C:\\file.txt' } 'extended length path relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/file.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'file.txt:ads' } 'alternate data stream' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/file.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner:stream' } 'alternate data stream on directory' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'safe:Zone.Identifier' } 'zone identifier stream' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'CON' } 'device name CON' { Test-PitrSafePath -Root $safeRoot -RelativePath 'console.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/NUL.txt' } 'device name NUL with extension' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/nul-ish.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'com1' } 'device name COM1 lower case' { Test-PitrSafePath -Root $safeRoot -RelativePath 'com1 0' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'LPT9' } 'device name LPT9' { Test-PitrSafePath -Root $safeRoot -RelativePath 'LPT9a' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'PRN.cmd' } 'device name with extension' { Test-PitrSafePath -Root $safeRoot -RelativePath 'printer.cmd' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'AUX' } 'device name AUX' { Test-PitrSafePath -Root $safeRoot -RelativePath 'aux-a' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath ('CLOCK' + [char]36) } 'device name CLOCK$ rejected by the ordinary illegal-character rule' { Test-PitrSafePath -Root $safeRoot -RelativePath 'CLOCKX' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/na<me.txt' } 'invalid character <' { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/name.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/na>me.txt' } 'invalid character >' { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/name.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/na|me.txt' } 'invalid character |' { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/name.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/na?me.txt' } 'invalid character ?' { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/name.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/na*me.txt' } 'invalid character *' { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/name.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/na"me.txt' } 'invalid character quote' { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/name.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath ('bad/na' + [char]1 + 'me.txt') } 'control character' { Test-PitrSafePath -Root $safeRoot -RelativePath 'bad/name.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath ('inner/'+('x'*300)+'.txt') } 'component longer than 255 characters' { Test-PitrSafePath -Root $safeRoot -RelativePath ('inner/'+('x'*200)+'.txt') }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'trailing. /file.txt' } 'component ending in dot' { Test-PitrSafePath -Root $safeRoot -RelativePath 'trailing/file.txt' }
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath 'trailing /file.txt' } 'component ending in space' { Test-PitrSafePath -Root $safeRoot -RelativePath 'trailing/file.txt' }
Assert-Accepted { Test-PitrSafePath -Root $safeRoot -RelativePath 'Dokumente/UEbersicht 2026.txt' } 'Unicode-safe path accepted'
Assert-Accepted { Test-PitrSafePath -Root $safeRoot -RelativePath 'com0/com1 0/console.txt' } 'device-like names that are not device names'
Assert-Accepted { Test-PitrSafePath -Root $safeRoot -RelativePath 'COM10/x' } 'two digit COM10 accepted'

# Existing reparse ancestors must be refused. Real symlink/junction creation is a Windows kernel
# capability: it succeeds on a Windows host (including Windows CI) and is not available to an
# unprivileged Linux process for the fixture shapes used here. Where creation fails the assertion
# is SKIPPED pending real Windows CI, never passed by assumption.
$escapeRoot=New-TestRoot 'escape'
Add-Origin $escapeRoot
$outsideRoot=New-TestRoot 'outside'
Add-Origin $outsideRoot
New-TestFile (Join-Path $outsideRoot 'secret.txt') 'secret'
$linked=$false
try { $null=New-Item -ItemType SymbolicLink -Path (Join-Path $escapeRoot 'link') -Target $outsideRoot -ErrorAction Stop; $linked=$true } catch {
    try { $null=New-Item -ItemType Junction -Path (Join-Path $escapeRoot 'link') -Target $outsideRoot -ErrorAction Stop; $linked=$true } catch { $linked=$false }
}
if(Assert-Skip $linked 'reparse ancestor escape refusal requires real symlink/junction creation (pending real Windows CI)') {
    Assert-Rejected { Test-PitrSafePath -Root $escapeRoot -RelativePath 'link/secret.txt' } 'reparse ancestor escape via symlink' { Test-PitrSafePath -Root $escapeRoot -RelativePath 'no-link/secret.txt' }
}
Assert-Rejected { Test-PitrSafePath -Root (Join-Path $safeRoot 'no-such-root') -RelativePath 'a/b.txt' } 'root that does not exist' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner/file.txt' }
$rootLink=Join-Path $escapeRoot 'rootlink'
$rootLinked=$false
try { $null=New-Item -ItemType SymbolicLink -Path $rootLink -Target $outsideRoot -ErrorAction Stop; $rootLinked=$true } catch { $rootLinked=$false }
if(Assert-Skip $rootLinked 'existing reparse root refusal requires real symlink creation (pending real Windows CI)') {
    Assert-Rejected { Test-PitrSafePath -Root $rootLink -RelativePath 'secret.txt' } 'existing root that is a reparse point' { Test-PitrSafePath -Root $outsideRoot -RelativePath 'secret.txt' }
}
Assert-Rejected { Test-PitrSafePath -Root $safeRoot -RelativePath $null } 'null relative name' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner' }
Assert-Rejected { Test-PitrSafePath -Root '' -RelativePath 'a' } 'empty root' { Test-PitrSafePath -Root $safeRoot -RelativePath 'inner' }

# ---------------------------------------------------------------------------
# Get-PitrVolumeIdentity
# ---------------------------------------------------------------------------
$identity=Get-PitrVolumeIdentity -Path $safeRoot
Assert-True ($identity.Kind -in @('Local','Network')) 'identity Kind is Local or Network'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$identity.VolumeId)) 'identity VolumeId present'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$identity.CanonicalPath)) 'identity CanonicalPath present'
Assert-True ($null -ne $identity.Warnings) 'identity Warnings present'
Assert-True ($identity.PSObject.Properties.Name -contains 'FileSystem') 'identity exposes FileSystem'
Assert-True ($identity.PSObject.Properties.Name -contains 'AvailableBytes') 'identity exposes AvailableBytes'
Assert-True ($identity.PSObject.Properties.Name -contains 'Kind') 'identity exposes Kind'

# Native volume identity (volume GUID + serial through the kernel) only exists on a real Windows
# host. A forced-branch run on Linux cannot produce it, so the assertion is skipped with the exact
# reason and only a real Windows CI host reports it as proven.
if(Assert-Skip $realWindows 'native stable Windows volume identity (volume GUID + serial) pending real Windows CI') {
    Assert-Equal 'local-' (([string]$identity.VolumeId).Substring(0,6)) 'Windows local volume identity is a native namespaced identity'
    # The hook must not change real-host behavior: a forced run reports the same namespacing.
    $env:PITR_FORCE_WINDOWS_HOST='1'
    $forcedIdentity=Get-PitrVolumeIdentity -Path $safeRoot
    Remove-Item Env:PITR_FORCE_WINDOWS_HOST -ErrorAction SilentlyContinue
    Assert-Equal 'local-' (([string]$forcedIdentity.VolumeId).Substring(0,6)) 'forced host also uses the native namespaced identity'
}
if ($hostIsWindows) {
    Assert-Rejected { Get-PitrVolumeIdentity -Path ($safeRoot + [IO.Path]::DirectorySeparatorChar) } 'trailing separator refused on Windows' { Get-PitrVolumeIdentity -Path $safeRoot }
} else {
    Assert-Equal 'host-path:' (([string]$identity.VolumeId).Substring(0,10)) 'non-Windows fallback identity is explicitly namespaced'
    Assert-True (@($identity.Warnings) -join ' ') -match 'never a Windows volume identity' 'non-Windows warning states the identity is not a Windows volume identity'
}

$sameIdentity=Get-PitrVolumeIdentity -Path $safeRoot
Assert-Equal $identity.VolumeId $sameIdentity.VolumeId 'identity is stable across calls'
$missingIdentity=Get-PitrVolumeIdentity -Path ($safeRoot + [IO.Path]::DirectorySeparatorChar + 'not-created-yet/deeper')
Assert-Equal ([IO.Path]::GetFullPath((Join-Path $safeRoot 'not-created-yet/deeper'))) $missingIdentity.CanonicalPath 'canonical path is the final requested path, not the ancestor'
Assert-Equal $safeRoot $missingIdentity.ResolvedPath 'identity reports the ancestor it actually measured'
# "A missing descendant has the same volume identity as its nearest existing ancestor" is a
# Windows-branch property: on Windows the identity is the volume that holds the ancestor. On Linux
# there is no volume abstraction, so the documented fallback keys on the canonical path and the
# two identities legitimately differ. Real Windows CI verifies the ancestor property; here we
# assert the honest Linux fallback and that the forced Windows branch fails closed when no native
# identity is available.
if ($hostIsWindows) {
    $descendantIdentity=$null
    $descendantRefused=$false
    try { $descendantIdentity=Get-PitrVolumeIdentity -Path ($safeRoot + [IO.Path]::DirectorySeparatorChar + 'not-created-yet/deeper') } catch { $descendantRefused=$true }
    if ($descendantRefused) {
        Assert-Skip $false 'forced Windows host on a non-Windows kernel has no native volume identity, so the branch fails closed (ancestor identity pending real Windows CI)' | Out-Null
    } else {
        Assert-Equal $identity.VolumeId $descendantIdentity.VolumeId 'on a native Windows host a missing descendant resolves through its nearest existing ancestor volume'
    }
} else {
    Assert-True (@($missingIdentity.Warnings) -join ' ') -match 'not a Windows volume identity' 'the missing-descendant fallback states it is not a Windows volume identity'
    Assert-True ($missingIdentity.VolumeId -ne $identity.VolumeId) 'Linux fallback keys on the canonical path, so a missing descendant identity is explicitly distinct'
}
$identityAgain=Get-PitrVolumeIdentity -Path $safeRoot
Assert-Equal $identity.VolumeId $identityAgain.VolumeId 'repeated resolution does not change identity'
$relativeIdentity=Get-PitrVolumeIdentity -Path '.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$relativeIdentity.CanonicalPath)) 'relative path canonicalized'
Assert-Rejected { Get-PitrVolumeIdentity -Path ' ' } 'whitespace path refused' { Get-PitrVolumeIdentity -Path $safeRoot }
if($hostIsWindows) {
    # Under a forced Windows host an unresolvable POSIX relative name is refused fail-closed by
    # the drive-qualified name requirement, so this exercises the Windows branch too.
    Assert-Rejected { Get-PitrVolumeIdentity -Path 'missing-relative-volume-probe' } 'unresolvable relative identity fails closed' { Get-PitrVolumeIdentity -Path $safeRoot }
}

# Fixed-drive failure modes need a real Windows drive table; on Linux there is no Z: to be
# missing, so these are skipped pending real Windows CI.
if(Assert-Skip $realWindows 'unresolvable fixed-drive identity refusal requires a real Windows host (pending real Windows CI)') {
    Assert-Rejected { Get-PitrVolumeIdentity -Path 'Z:\pitr-no-such-volume-9f3a' } 'unresolvable local identity fails closed' { Get-PitrVolumeIdentity -Path $safeRoot }
    Assert-Rejected { Get-PitrVolumeIdentity -Path ('Z:\pitr-no-such-volume-9f3a'+[IO.Path]::DirectorySeparatorChar+'deeper') } 'unresolvable identity with descendant fails closed' { Get-PitrVolumeIdentity -Path $safeRoot }
    Assert-Rejected { Test-PitrDestination -Destination 'Z:\pitr-no-such-volume-9f3a' -Sources @() } 'unresolvable destination refused' { Test-PitrDestination -Destination $destRoot -Sources @() }
    Assert-Rejected { Get-PitrVolumeIdentity -Path 'C:\' } 'drive root trailing-separator path-form refusal requires a real Windows host' { Get-PitrVolumeIdentity -Path $safeRoot }
}

# ---------------------------------------------------------------------------
# Test-PitrDestination
# ---------------------------------------------------------------------------
$destRoot=New-DestinationTestRoot 'dest'
Add-Origin $destRoot
$dest=mkdir (Join-Path $destRoot 'target')
$destIdentity=Test-PitrDestination -Destination (Join-Path $destRoot 'target') -Sources @() -RequiredBytes 0
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$destIdentity.VolumeId)) 'safe destination returns identity'
Assert-Rejected { Test-PitrDestination -Destination '' -Sources @() } 'empty destination refused' { Test-PitrDestination -Destination $destRoot -Sources @() }
Assert-Rejected { Test-PitrDestination -Destination (Join-Path $destRoot 'target/../target') -Sources @() -RequiredBytes -1 } 'negative required bytes refused' { Test-PitrDestination -Destination (Join-Path $destRoot 'target') -Sources @() -RequiredBytes 0 }
Assert-Rejected { Test-PitrDestination -Destination $destRoot -Sources @($destRoot) } 'destination identical to source refused' { Test-PitrDestination -Destination $destRoot -Sources @($safeRoot) }
Assert-Rejected { Test-PitrDestination -Destination (Join-Path $destRoot 'target') -Sources @($destRoot) } 'destination nested inside a source refused' { Test-PitrDestination -Destination (Join-Path $destRoot 'target') -Sources @($safeRoot) }
Assert-Rejected { Test-PitrDestination -Destination $destRoot -Sources @((Join-Path $destRoot 'target')) } 'destination that is an ancestor of a source refused' { Test-PitrDestination -Destination $destRoot -Sources @($safeRoot) }
Assert-Rejected { Test-PitrDestination -Destination (Join-Path $destRoot 'target') -Sources @(' ') } 'empty source entry refused' { Test-PitrDestination -Destination (Join-Path $destRoot 'target') -Sources @($safeRoot) }

# Exact ancestor semantics use canonical path boundaries, not naive string prefixes.
$boundaryRoot=New-DestinationTestRoot 'boundary'
Add-Origin $boundaryRoot
$null=[IO.Directory]::CreateDirectory((Join-Path $boundaryRoot 'Data'))
$null=[IO.Directory]::CreateDirectory((Join-Path $boundaryRoot 'Data-old'))
$null=[IO.Directory]::CreateDirectory((Join-Path $boundaryRoot 'Data/dest'))
Assert-Accepted { Test-PitrDestination -Destination (Join-Path $boundaryRoot 'Data-old') -Sources @((Join-Path $boundaryRoot 'Data')) } 'sibling with shared name prefix is not nested'
Assert-Rejected { Test-PitrDestination -Destination (Join-Path $boundaryRoot 'Data/dest') -Sources @((Join-Path $boundaryRoot 'Data')) } 'real child is nested' { Test-PitrDestination -Destination (Join-Path $boundaryRoot 'Data-old') -Sources @((Join-Path $boundaryRoot 'Data')) }

# Volume identity fixtures. PITR_VOLUME_IDENTITY_FIXTURE makes two independent volumes
# distinguishable on a synthetic host, exactly as two real volumes would be on Windows.
$volumeFixtureFile=Join-Path $destRoot 'volume-identity-fixture.json'
New-TestFile $volumeFixtureFile ('{"'+$identity.CanonicalComparisonPath.Replace('\','\\')+'":"local-testvol-a|serial:AAAAAAAA","'+$boundaryRoot.Replace('\','\\')+'":"local-testvol-b|serial:BBBBBBBB"}')
$env:PITR_VOLUME_IDENTITY_FIXTURE=$volumeFixtureFile
$fixtureIdentity=Get-PitrVolumeIdentity -Path $identity.CanonicalComparisonPath
Assert-Equal 'local-testvol-a|serial:aaaaaaaa' $fixtureIdentity.VolumeId 'fixture overrides the synthetic identity (test-only hook)'
Assert-Accepted { Test-PitrDestination -Destination $identity.CanonicalComparisonPath -Sources @($boundaryRoot) } 'independent destination volume accepted'
Assert-Rejected { Test-PitrDestination -Destination $identity.CanonicalComparisonPath -Sources @($identity.CanonicalComparisonPath) } 'destination that is also a source refused' { Test-PitrDestination -Destination $identity.CanonicalComparisonPath -Sources @($boundaryRoot) }
$osVolumeFixture=Join-Path $destRoot 'os-volume-fixture.json'
New-TestFile $osVolumeFixture ('{"'+$identity.CanonicalComparisonPath.Replace('\','\\')+'":"local-osvol|serial:CCCCCCCC","'+$boundaryRoot.Replace('\','\\')+'":"local-othervol|serial:DDDDDDDD"}')
$env:PITR_VOLUME_IDENTITY_FIXTURE=$osVolumeFixture
$env:SystemRoot=$identity.CanonicalComparisonPath
# Get-PitrWindowsHost gates the OS-volume branch. Forcing it here exercises the branch on any host
# that can supply an identity fixture; the run is only reported as a real Windows verification when
# $realWindows is true. The control is a destination on a *different* fixture volume, which must be
# accepted, proving the rejection is the OS-volume identity check and not a blanket refusal.
$env:PITR_FORCE_WINDOWS_HOST='1'
Assert-Rejected { Test-PitrDestination -Destination $identity.CanonicalComparisonPath -Sources @($boundaryRoot) } 'OS volume destination rejected without assuming C:' { Test-PitrDestination -Destination $boundaryRoot -Sources @($identity.CanonicalComparisonPath) }
Remove-Item Env:PITR_FORCE_WINDOWS_HOST -ErrorAction SilentlyContinue
Remove-Item Env:PITR_VOLUME_IDENTITY_FIXTURE -ErrorAction SilentlyContinue
Remove-Item Env:SystemRoot -ErrorAction SilentlyContinue

# UNC path form is a Windows path syntax. On Linux, '\\\\server\\share' is a relative POSIX name and
# cannot be classified as a network share, so the UNC assertions require a real Windows host.
# A hosted runner has no SMB share, so an unreachable UNC destination must be refused fail-closed
# rather than classified from a guess; that refusal is pinned on Windows and the classification
# assertions run only when the name actually resolves.
if($realWindows) {
    $uncPath='\\server\share\PITR-Backups'
    $uncIdentity=$null
    $uncError=$null
    try { $uncIdentity=Get-PitrVolumeIdentity -Path $uncPath } catch { $uncError=$_.Exception.Message }
    if($null -ne $uncIdentity) {
        Assert-Equal 'Network' $uncIdentity.Kind 'UNC destination classified as Network'
        Assert-Equal 'unc:server\share' $uncIdentity.VolumeId 'UNC identity is server/share based, not letter based'
        Assert-True (@($uncIdentity.Warnings) -join ' ') -match 'credentials' 'network warning states that no credentials are used'
        Assert-True (@($uncIdentity.Warnings) -join ' ') -match 'cannot be verified' 'network warning states that independence cannot be verified'
        Assert-Rejected { Get-PitrVolumeIdentity -Path '\\localhost\c$\Users' } 'loopback share rejected as not independent' { Get-PitrVolumeIdentity -Path $uncPath }
        Assert-Rejected { Get-PitrVolumeIdentity -Path '\\127.0.0.1\backup' } '127.0.0.1 share rejected as not independent' { Get-PitrVolumeIdentity -Path $uncPath }
    } else {
        Assert-True ($uncError -match 'cannot be resolved') ('an unreachable UNC destination is refused fail-closed instead of guessed, got: '+$uncError)
        Assert-Skip $false 'UNC share classification (Network kind, server/share identity, credential warnings, loopback refusal) needs an existing reachable SMB share; the hosted runner has none' | Out-Null
    }
} else {
    Assert-Skip $false 'UNC path form is Windows-only; a POSIX relative name cannot be classified as a network share' | Out-Null
}

# ---------------------------------------------------------------------------
# Get-PitrProfiles
# ---------------------------------------------------------------------------
$profileFixture=Join-Path $destRoot 'profiles.csv'
$profilesRoot=Join-Path $destRoot 'profiles'
$null=[IO.Directory]::CreateDirectory((Join-Path $profilesRoot 'alice'))
$null=[IO.Directory]::CreateDirectory((Join-Path $profilesRoot 'Public'))
$standardSid='S-1-5-21-1111111111-2222222222-3333333333-1001'
$nonstandardSid='S-1-5-21-1111111111-2222222222-3333333333-1002'
$publicSid='S-1-5-32-545'
# Exactly two usable profiles (standard + Public) so Complete yields 4 roots, matching the contract.
# The nonstandard-path registration points at a directory this fixture never creates, so it is
# exposed as inaccessible (the "profile path does not exist on this host" branch) instead of adding
# a third usable profile.
$content=@(
    ('Sid,Path'),
    ($standardSid+','+(Join-Path $profilesRoot 'alice')),
    ($nonstandardSid+','+(Join-Path $profilesRoot 'bob-on-D-not-created')),
    ($publicSid+',"%PITR_PUBLIC_ROOT%"'),
    ('S-1-5-21-1111111111-2222222222-3333333333-1003,'),
    ('S-1-5-21-1111111111-2222222222-3333333333-1004,relative\path')
) -join "`n"
New-TestFile $profileFixture ($content+"`n")
# The refusal is only meaningful against the same call succeeding once a fixture exists, so the
# positive control runs after the fixture is in place (the count assertions below).
$profilesRefused=$false
try { $null=Get-PitrProfiles } catch { $profilesRefused=$true }
Assert-True $profilesRefused 'profile discovery refuses to run without a ProfileList or fixture'
$env:PITR_PROFILELIST_FIXTURE_PATH=$profileFixture
$env:PITR_PUBLIC_ROOT=(Join-Path $profilesRoot 'Public')
$profiles=@(Get-PitrProfiles)
Assert-Equal 5 $profiles.Count 'negative control: with a fixture, every registration is exposed, including inaccessible ones'
Assert-Equal 1 @($profiles | Where-Object { $_.IsPublic }).Count 'Public is identified without a special-cased path'
Assert-Equal 3 @($profiles | Where-Object { $_.Inaccessible }).Count 'inaccessible profiles are exposed, not silently omitted (three unresolvable registrations)'
Assert-True (@($profiles | Where-Object { $_.Sid -eq $nonstandardSid })[0].Path) -match 'bob-on-D-not-created' 'nonstandard profile path is preserved on the exposed registration'
Assert-Equal (Join-Path $profilesRoot 'Public') (@($profiles | Where-Object { $_.Sid -eq $publicSid })[0].Path) 'environment placeholders are expanded for real profiles'
# Contract: ProfileList exposes Public on the default OS volume only; the fixture registers exactly
# two resolvable profiles (standard + Public) and three rows that resolve to nothing, which are
# exposed as inaccessible rather than counted as usable.
Assert-Equal 2 @($profiles | Where-Object { -not $_.Inaccessible }).Count 'only resolvable registrations are usable (standard + Public)'

# ---------------------------------------------------------------------------
# Get-PitrSourceRoots
# ---------------------------------------------------------------------------
# Complete selects a single tree per usable profile, including Public.
# Personal selects conventional personal subfolders, never AppData or the whole profile.
$usableProfiles=@($profiles | Where-Object { -not $_.Inaccessible })
$sources=@(Get-PitrSourceRoots -Profiles $usableProfiles -Scope Complete -CustomPaths @())
Assert-Equal 2 $sources.Count 'Complete selects one nonoverlapping tree for each usable profile'
Assert-Equal 2 @($sources | Where-Object { $_.Category -eq 'Profile' }).Count 'Profile category present for each usable profile'
Assert-Equal 0 @($sources | Where-Object { $_.Category -eq 'Personal' }).Count 'Complete does not duplicate personal files'
Assert-Equal 1 @($sources | Where-Object { $_.ProfileSid -eq $publicSid }).Count 'Public contributes its own single complete source'
Assert-Equal $sources.Count @($sources | ForEach-Object { $_.Id } | Sort-Object -Unique).Count 'source ids are unique'
Assert-True (@($sources | Where-Object { $_.ProfileSid -eq $standardSid })[0].Id -like 'profile-*') 'ids are stable profile-derived strings, never random GUIDs'

foreach ($profile in $usableProfiles) {
    $null = [IO.Directory]::CreateDirectory((Join-Path $profile.Path 'Documents'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $profile.Path 'AppData'))
}
$personal=@(Get-PitrSourceRoots -Profiles $usableProfiles -Scope Personal -CustomPaths @())
Assert-True (@($personal | Where-Object { (Split-Path $_.Path -Leaf) -ne 'Documents' }).Count -eq 0) 'Personal selects actual personal subfolders, never whole profiles or AppData'
Assert-Equal 2 $personal.Count 'Personal scope excludes complete-profile selection'
Assert-Equal 2 @($personal | Where-Object { $_.Category -eq 'Personal' }).Count 'Personal scope keeps only personal data'
$scopeRefused=$false
try { $null=Get-PitrSourceRoots -Profiles $profiles -Scope Custom -CustomPaths @() } catch { $scopeRefused=$true }
Assert-True $scopeRefused 'Custom scope without an explicit folder is refused'

$customFolder=Join-Path $destRoot 'extra'
$null=[IO.Directory]::CreateDirectory($customFolder)
Assert-Accepted { Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @($customFolder) } 'negative control: Custom with an explicit folder is accepted'

$inaccessible=@($profiles | Where-Object { $_.Inaccessible })
$inaccessibleRefused=$false
try { $null=Get-PitrSourceRoots -Profiles $inaccessible -Scope Complete -CustomPaths @() } catch { $inaccessibleRefused=$true }
Assert-True $inaccessibleRefused 'an inaccessible selected profile fails closed instead of being skipped'

$customSingle=@(Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @($customFolder))
Assert-Equal 1 $customSingle.Count 'Custom selects only the folder that was named'
Assert-Equal 'Extra' $customSingle[0].Category 'Custom sources use the Extra category'
Assert-Equal $null $customSingle[0].ProfileSid 'Custom sources are not attributed to a profile'
$customTwo=@(Get-PitrSourceRoots -Profiles $usableProfiles -Scope Custom -CustomPaths @($customFolder,(Join-Path $destRoot 'profiles')))
Assert-Equal 2 $customTwo.Count 'Custom never silently includes all profiles'
Assert-Equal 2 @($customTwo | ForEach-Object { $_.Id } | Sort-Object -Unique).Count 'distinct custom folders get distinct ids'
Assert-Rejected { Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @('') } 'empty custom folder refused' { Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @($customFolder) }
Assert-Rejected { Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @((Join-Path $destRoot 'no-such-extra')) } 'missing custom folder refused' { Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @($customFolder) }
# Contract (IMPLEMENTATION-CONTRACT.md + TEST-PLAN.md): Test-Plan lists user-selected files, so a
# custom source that is an existing Explorer-readable FILE is allowed.
$customFileSource=Join-Path $destRoot 'extra-file.txt'
New-TestFile $customFileSource 'selected-file-source'
$customFile=@(Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @($customFileSource))
Assert-Equal 1 $customFile.Count 'a custom source that is an existing readable file is accepted by the contract'
Assert-Equal 'Extra' $customFile[0].Category 'file custom source uses the Extra category'
Assert-Rejected { Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @($customFolder + '/inside-missing-file.txt') } 'missing custom file refused' { Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @($customFileSource) }
Remove-Item Env:PITR_PROFILELIST_FIXTURE_PATH -ErrorAction SilentlyContinue
Remove-Item Env:PITR_PUBLIC_ROOT -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Forced Windows host fixture class (test-only hook PITR_FORCE_WINDOWS_HOST)
#
# On a real Windows host these branches run natively. On any host the hook forces
# Get-PitrWindowsHost to report true so the Windows branches of Get-PitrVolumeIdentity,
# Test-PitrDestination and Get-PitrSourceRoots execute against identity fixtures. This class is
# reported as verified only on a real Windows host; on Linux the same fixtures are exercised but
# the outcome is recorded as branch-coverage evidence, not a claim of Windows behavior.
# ---------------------------------------------------------------------------
$forcedDualFixture=Join-Path $destRoot 'forced-dual-fixture.json'
$forcedPathA=New-TestRoot 'forced-a'
Add-Origin $forcedPathA
$forcedPathB=New-TestRoot 'forced-b'
Add-Origin $forcedPathB
New-TestFile $forcedDualFixture ('{"'+$identity.CanonicalComparisonPath.Replace('\','\\')+'":"local-volA|serial:AAAA1111","'+$forcedPathA.Replace('\','\\')+'":"local-volA|serial:AAAA1111","'+$forcedPathB.Replace('\','\\')+'":"local-volB|serial:BBBB2222"}')
$env:PITR_FORCE_WINDOWS_HOST='1'
$env:PITR_VOLUME_IDENTITY_FIXTURE=$forcedDualFixture
$forcedIdentityA=Get-PitrVolumeIdentity -Path $forcedPathA
$forcedIdentityB=Get-PitrVolumeIdentity -Path $forcedPathB
Assert-Equal 'local-vola|serial:aaaa1111' $forcedIdentityA.VolumeId 'forced Windows host maps destination to a fixture volume identity'
Assert-Equal 'local-volb|serial:bbbb2222' $forcedIdentityB.VolumeId 'forced Windows host maps a second path to a distinct fixture volume identity'
Assert-True ($forcedIdentityA.VolumeId -ne $forcedIdentityB.VolumeId) 'forced Windows host keeps two fixture volumes distinguishable'
Assert-Rejected { Test-PitrDestination -Destination $identity.CanonicalComparisonPath -Sources @($forcedPathA) } 'forced Windows host refuses a destination on the same fixture volume as the source' { Test-PitrDestination -Destination $identity.CanonicalComparisonPath -Sources @($forcedPathB) }
Assert-Accepted { Test-PitrDestination -Destination $forcedPathA -Sources @($forcedPathB) } 'forced Windows host accepts a destination on a distinct fixture volume'
# Without a fixture the forced Windows branch must not guess: it uses the native kernel identity
# when one is obtainable and fails closed when it is not. Which of the two happens depends on the
# kernel under test, so the assertion is that exactly one of the two holds and neither is a silent
# host-path fallback.
Remove-Item Env:PITR_VOLUME_IDENTITY_FIXTURE -ErrorAction SilentlyContinue
$forcedUnfixturedThrew=$false
$forcedUnfixtured=$null
try { $forcedUnfixtured=Get-PitrVolumeIdentity -Path $identity.CanonicalComparisonPath } catch { $forcedUnfixturedThrew=$true }
if($forcedUnfixturedThrew) {
    Assert-True $true 'forced Windows host fails closed when no native identity is available, never guessing'
    Assert-Skip $false 'forced Windows host native volume identity query is unavailable on this kernel (pending real Windows CI)' | Out-Null
} else {
    Assert-True ([string]$forcedUnfixtured.VolumeId).StartsWith('local-') 'forced Windows host without a fixture uses a native local identity, never a host-path fallback'
}
Remove-Item Env:PITR_FORCE_WINDOWS_HOST -ErrorAction SilentlyContinue
Assert-Equal ($env:OS -eq 'Windows_NT') (Get-PitrWindowsHost) 'removing the hook restores real host detection'
# Get-PitrSourceRoots must scope the same way under the forced Windows host, including file sources.
# The forced branch refuses a local path with no resolvable identity, so the file source is given a
# fixture volume identity for this check.
$forcedRootsFixture=Join-Path $destRoot 'forced-roots-fixture.json'
New-TestFile $forcedRootsFixture ('{"'+([IO.Path]::GetFullPath($customFileSource)).Replace('\','\\')+'":"local-filevol|serial:E1E1E1E1"}')
$env:PITR_FORCE_WINDOWS_HOST='1'
$env:PITR_VOLUME_IDENTITY_FIXTURE=$forcedRootsFixture
$forcedRoots=@(Get-PitrSourceRoots -Profiles @() -Scope Custom -CustomPaths @($customFileSource))
Assert-Equal 1 $forcedRoots.Count 'forced Windows host scopes an explicit file source without duplicating it'
Assert-Equal 'Extra' $forcedRoots[0].Category 'forced Windows host keeps the Extra category for file sources'
Remove-Item Env:PITR_VOLUME_IDENTITY_FIXTURE -ErrorAction SilentlyContinue
Remove-Item Env:PITR_FORCE_WINDOWS_HOST -ErrorAction SilentlyContinue
if(-not $realWindows) {
    Assert-Skip $false 'the forced Windows host fixture class exercised the Windows branches here but only a real Windows host verifies native volume identity, OS-volume aliasing and drive-letter semantics (pending real Windows CI)' | Out-Null
}

# ---------------------------------------------------------------------------
# Managed fixtures are removed; nothing outside the test GUID roots is touched.
# ---------------------------------------------------------------------------
foreach($origin in $script:origins) {
    if($origin -and [IO.Directory]::Exists($origin) -and (Split-Path $origin -Leaf).StartsWith('pitr-platform-')) {
        try { [IO.Directory]::Delete($origin,$true) } catch { }
    }
}
if($script:Skips.Count -gt 0) { foreach($skip in $script:Skips) { Write-Output ('SKIP (pending real Windows CI): '+$skip) } }
Write-Output ('Platform assertions passed: '+$script:Passed+' checks, '+$script:Skips.Count+' skipped. Real Windows host: '+$realWindows+'. Forced Windows host: '+($hostIsWindows -and -not $realWindows)+'.')
if($script:Failures.Count -gt 0) {
    foreach($failure in $script:Failures) { [Console]::Error.WriteLine('FAIL '+$failure) }
    throw ('Platform tests failed: '+$script:Failures.Count+' of '+($script:Failures.Count+$script:Passed)+' assertions.')
}