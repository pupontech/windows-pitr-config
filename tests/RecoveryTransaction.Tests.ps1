$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Manifest.ps1')
. (Join-Path $root 'src/backup/Recovery.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# Isolated real engine fixture. Use a scratch location, never an application/data path.
$base = [IO.Path]::GetTempPath()
if ($env:TMPDIR) { $base=$env:TMPDIR }
if (-not [IO.Directory]::Exists($base)) { $null = [IO.Directory]::CreateDirectory($base) }
$fixture = Join-Path $base ('pitr-transaction-' + [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $fixture 'backup'
$payload = Join-Path $backupRoot 'profiles/src-1'
$currentRoot = Join-Path $fixture 'current'
$destination = Join-Path $currentRoot 'document.txt'
$backupFile = Join-Path $payload 'document.txt'
$manifestPath = Join-Path $backupRoot 'manifest.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$null = [IO.Directory]::CreateDirectory($payload)
$null = [IO.Directory]::CreateDirectory($currentRoot)
[IO.File]::WriteAllText($backupFile, 'restored version', $utf8)
[IO.File]::WriteAllText($destination, 'original current bytes', $utf8)

try {
    # Compose a valid real manifest using the existing public manifest APIs.
    $manifest = New-PitrManifest -BackupId ([guid]::NewGuid().ToString()) -Scope Complete -ApplicationVersion 'transaction-test'
    $manifest.Sources = @([pscustomobject]@{ Id='src-1'; Path='C:\Users\Fixture'; ProfileSid='S-1-5-21-1-1-1-1001'; SourceVolumeId='fixture'; Category='Profile'; DisplayName='Fixture' })
    $manifest.Entries = @((New-PitrManifestEntry -Id 'entry-document' -SourceId 'src-1' -RelativePath 'document.txt' -Type File -BackupRelativePath 'profiles/src-1/document.txt' -Length ([IO.FileInfo]$backupFile).Length -CopyStatus Copied -VerificationStatus FullVerified -Sha256 (Get-PitrHash -Path $backupFile)))
    $manifest = Set-PitrManifestState -Manifest $manifest -State Running
    $manifest = Set-PitrManifestState -Manifest $manifest -State CopyCompleted
    $manifest = Set-PitrManifestState -Manifest $manifest -State Verifying
    $manifest = Set-PitrManifestState -Manifest $manifest -State Verified
    $null = Write-PitrManifest -ManifestPath $manifestPath -Manifest $manifest

    # Override only this test process's hash function. The deep comparison and staged
    # temp verification succeed; the first hash of the swapped-in target throws.
    $script:RealGetPitrHash = (Get-Command Get-PitrHash -CommandType Function).ScriptBlock
    $script:InjectedTargetFailure = $false
    function Get-PitrHash {
        [CmdletBinding()]
        param([Parameter(Mandatory=$true)][string]$Path)
        if ([IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($script:TransactionDestination) -and -not $script:InjectedTargetFailure) {
            $bytes = [IO.File]::ReadAllText($Path)
            if ($bytes -eq 'restored version') {
                $script:InjectedTargetFailure = $true
                if ($script:ObstructRollback) {
                    [IO.File]::Delete($Path)
                    $null=[IO.Directory]::CreateDirectory($Path)
                }
                throw 'Injected post-swap target hash failure.'
            }
        }
        return (& $script:RealGetPitrHash -Path $Path)
    }
    $script:TransactionDestination = $destination

    $result = Restore-PitrFiles -ManifestPath $manifestPath -Mappings @{ 'src-1'=$currentRoot } -EntryIds @('entry-document') -Conflict Replace -Execute
    $action = @($result.Actions)[0]
    Assert-True $script:InjectedTargetFailure 'injected post-swap verification failure was reached'
    Assert-True (([IO.File]::ReadAllText($destination)) -eq 'original current bytes') 'original bytes must be back at the original destination after failure'
    Assert-True ($action.Result -ne 'Succeeded') 'failed transaction must not report Succeeded'
    Assert-True (-not $result.Complete) 'failed transaction must report Complete=false'
    Assert-True ($action.Result -eq 'Failed' -and $action.Error) 'failure bookkeeping must preserve an error'
    Assert-True ($action.PreservedPath -and -not [IO.File]::Exists([string]$action.PreservedPath)) 'successful rollback consumes the conflict-preserved copy'
    $tmpFiles = @(Get-ChildItem -LiteralPath $fixture -Recurse -File | Where-Object { $_.Name -like '*.tmp' })
    Assert-True ($tmpFiles.Count -eq 0) 'no orphan temporary restore file remains'
    Assert-True ($action.RollbackStatus -eq 'Restored') 'successful rollback is explicit'
    Assert-True ($action.FailedPath -and [IO.File]::Exists($action.FailedPath)) 'unverified replacement retained separately'
    # A competing directory blocks rollback; the preserved original must survive.
    $script:InjectedTargetFailure=$false
    $script:ObstructRollback=$true
    $blocked=Restore-PitrFiles -ManifestPath $manifestPath -Mappings @{ 'src-1'=$currentRoot } -EntryIds @('entry-document') -Conflict Replace -Execute
    $blockedAction=@($blocked.Actions)[0]
    Assert-True $script:InjectedTargetFailure 'rollback obstruction injection was reached'
    Assert-True (-not $blocked.Complete -and $blockedAction.Result -eq 'Failed') 'rollback failure cannot claim success'
    Assert-True ($blockedAction.RollbackStatus -eq 'Failed') 'rollback failure reported explicitly'
    Assert-True ([IO.File]::Exists($blockedAction.PreservedPath)) 'original preserved copy must remain when rollback fails'
    Assert-True (([IO.File]::ReadAllText($blockedAction.PreservedPath)) -eq 'original current bytes') 'original bytes recoverable after rollback failure'
    Assert-True ($blockedAction.Error.Contains($destination) -and $blockedAction.Error.Contains($blockedAction.PreservedPath)) 'rollback error identifies both original destination and preserved copy'
    # A missing historical hash cannot be manufactured from the bytes just observed.
    [IO.Directory]::Delete($destination)
    [IO.File]::WriteAllText($destination,'keep unhashed current',$utf8)
    $unhashed=Read-PitrManifest -ManifestPath $manifestPath
    $unhashed.Entries[0].Sha256=$null
    $null=Write-PitrManifest -ManifestPath $manifestPath -Manifest $unhashed
    $script:InjectedTargetFailure=$true;$script:ObstructRollback=$false
    $unverified=Restore-PitrFiles -ManifestPath $manifestPath -Mappings @{'src-1'=$currentRoot} -EntryIds @('entry-document') -Conflict Replace -Execute
    Assert-True (([IO.File]::ReadAllText($destination)) -eq 'keep unhashed current') 'RED: a payload without recorded provenance hash must not be restored'
    Assert-True (-not $unverified.Complete) 'missing historical hash must report incomplete'
    Write-Output 'Recovery transaction assertions passed: rollback, obstruction preservation and missing-hash refusal.'
} finally {
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}
