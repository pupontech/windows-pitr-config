$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Ui.ps1')
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/backup/Ui.ps1'),[ref]$t,[ref]$e)
function Assert($ok,[string]$why) { if(-not $ok) { throw $why } }
function Assigned([string]$name) {
    $n=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $name},$true)
    Assert ($null -ne $n) ('RED: missing production operation '+$name)
    $s=$n.Right.Extent.Text.Trim(); [scriptblock]::Create($s.Substring(1,$s.Length-2))
}
function Handler([string]$name) {
    $n=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith($name)},$true)
    Assert ($null -ne $n) ('RED: missing production handler '+$name)
    $s=$n.Arguments[0].ScriptBlock.Extent.Text.Trim(); [scriptblock]::Create($s.Substring(1,$s.Length-2))
}
$prepare=Assigned '$prepare'
$controls=@{ManifestPath=[pscustomobject]@{Text='fixture-manifest'}; Status=[pscustomobject]@{Text=''}; MappingsApproved=[pscustomobject]@{IsChecked=$false}}
$view=@{PreviewContext=$null;Mappings=@()}
$script:launch=$null
$start={param($kind,$operation,$argumentsObject) $script:launch=@{Kind=$kind;Operation=$operation;Args=$argumentsObject}}
& $prepare
Assert ($script:launch.Kind -eq 'Prepare') 'Opening a backup must start preparation.'
$script:order=New-Object Collections.ArrayList
function Test-PitrBackup {param($ManifestPath,$Mode,$Cancellation,$Progress) $null=$script:order.Add('verify'); Assert ($Mode -eq 'Full') 'Prepare must fully verify.'; [pscustomobject]@{State='Verified';Sources=@()} }
function Get-PitrProfiles { $null=$script:order.Add('profiles'); return @() }
$state=@{Cancelled=$false;Result=$null;Progress=$null}
& $script:launch.Operation $state $script:launch.Args
Assert ($script:order[0] -eq 'verify' -and $state.Result.Verification.State -eq 'Verified') 'Prepare must verify before suggesting folders.'
$compare=Assigned '$compare'
$findMissing=Handler '$controls.FindMissing.Add_Click('
$getMappings={ return @{one='current-root'} }
$controls.MappingsApproved.IsChecked=$false; $script:launch=$null
& $findMissing
Assert ($null -eq $script:launch) 'Unapproved destinations must not compare.'
$controls.MappingsApproved.IsChecked=$true
$view.Mappings=@([pscustomobject]@{SourceId='one';TargetRoot='current-root'},[pscustomobject]@{SourceId='two';TargetRoot=''})
& $findMissing
Assert ($null -eq $script:launch) 'Missing source mappings must not look like a complete comparison.'
$view.Mappings=@($view.Mappings[0])
& $findMissing
Assert ($script:launch.Kind -eq 'Compare') 'Approved complete mappings must start comparison.'
$script:launch=$null
$recover=Assigned '$recover'
$view.SelectedIds=@{file=$true};$view.PreviewContext=$null
$controls.ConflictPolicy=[pscustomobject]@{SelectedItem=[pscustomobject]@{Content='Skip'}}
$controls.AlternateRoot=[pscustomobject]@{Text=''};$controls.AllowAdvanced=[pscustomobject]@{IsChecked=$false}
& $recover $true
Assert ($null -eq $script:launch -and $controls.Status.Text -match 'Preview') 'Execution without a matching successful preview must be refused before opening confirmation.'
& $recover $false
Assert ($script:launch.Kind -eq 'Recovery' -and -not $script:launch.Args.Execute) 'Preview must stay dry-run.'
$first=$view.PendingPreviewContext
$view.PreviewContext=$first # Simulate a successfully completed preview of exactly this context.
$controls.AlternateRoot.Text='changed-target'
& $recover $true
Assert ($controls.Status.Text -match 'Preview') 'A changed destination must require another preview.'
Assert (-not [string]::IsNullOrWhiteSpace($first)) 'Preview must capture the exact operation context.'
Write-Output 'Simple production actions passed: full verify, explicit approved mappings, missing-map refusal, preview-first and context-change refusal.'
