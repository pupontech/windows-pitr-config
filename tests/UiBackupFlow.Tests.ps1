$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/backup/Ui.ps1'),[ref]$tokens,[ref]$errors)
$handler=$ast.Find({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Extent.Text.StartsWith('$controls.StartBackup.Add_Click(')},$true)
if(-not $handler) { throw 'Production backup click handler not found' }
$click=[scriptblock]::Create($handler.Arguments[0].ScriptBlock.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}'))
$controls=@{Profiles=[pscustomobject]@{SelectedItems=@('profile')};Scope=[pscustomobject]@{SelectedItem=[pscustomobject]@{Content='Complete'}};CustomPaths=[pscustomobject]@{Text=''};Destination=[pscustomobject]@{Text='backup-target'}}
$ApplicationRoot=$root
$script:copyState='CopyCompleted'; $script:verified=$false
function Get-PitrSourceRoots { param($Profiles,$Scope,$CustomPaths) return 'source' }
function New-PitrBackup { param($Sources,$Destination,$Scope,$RecoverySource,$Cancellation,$Progress) return [pscustomobject]@{State=$script:copyState;ManifestPath='fixture-manifest'} }
function Test-PitrBackup {
    param($ManifestPath,$Mode,$Cancellation,$Progress)
    if($ManifestPath -ne 'fixture-manifest' -or $Mode -ne 'Full') { throw 'Verification must use the created manifest and Full mode' }
    $script:verified=$true
    return [pscustomobject]@{State='Verified';ManifestPath=$ManifestPath}
}
$script:result=$null
$start={param($kind,$operation,$argumentsObject) $state=@{Cancelled=$false;Result=$null}; & $operation $state $argumentsObject; $script:result=$state.Result}
& $click
if(-not $script:verified -or $script:result.State -ne 'Verified') { throw 'Backup and verify click did not run full verification after copy completion' }
$script:copyState='Interrupted'; $script:verified=$false
& $click
if($script:verified -or $script:result.State -ne 'Interrupted') { throw 'Interrupted copies must not start verification or claim verification success' }
Write-Output 'Production UI backup click orchestration passed: copy completion verifies; interruption remains interrupted. Engine boundaries stubbed; real engine covered by BackupCli suite.'
