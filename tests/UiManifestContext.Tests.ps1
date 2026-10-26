$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/backup/Ui.ps1'),[ref]$tokens,[ref]$errors)
function Get-Handler([string]$prefix) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith($prefix)},$true)
    if(-not $node) { throw ('Missing production handler: '+$prefix) }
    $text=$node.Arguments[0].ScriptBlock.Extent.Text.Trim()
    return [scriptblock]::Create($text.Substring(1,$text.Length-2))
}
# Two manifests can carry the same entry IDs. Old selections must not survive a switch.
$selected=New-Object 'Collections.Generic.List[object]'
$selected.Add([pscustomobject]@{Id='same-id';RelativePath='old-private.txt'})
$view=@{Rows=@($selected.ToArray());Mappings=@('old-mapping');Report='old-report';Generation=0;Job=$null}
$controls=@{
    Results=[pscustomobject]@{ItemsSource=$view.Rows;SelectedItems=$selected}
    Mappings=[pscustomobject]@{ItemsSource=$view.Mappings}
    Status=[pscustomobject]@{Text='old comparison'}
}
$changed=Get-Handler '$controls.ManifestPath.Add_TextChanged('
& $changed
if($view.Rows.Count -ne 0 -or $selected.Count -ne 0 -or $controls.Results.ItemsSource.Count -ne 0) { throw 'Old backup rows or selected entry IDs survived manifest replacement' }
if($view.Mappings.Count -ne 0 -or $controls.Mappings.ItemsSource.Count -ne 0 -or $null -ne $view.Report) { throw 'Old mapping or export report survived manifest replacement' }
if($view.Generation -ne 1) { throw 'Manifest replacement must invalidate outstanding asynchronous work' }
Write-Output 'Production manifest replacement invalidates prior rows, selections, mappings, report and generation.'
# Release an old completion after replacement, using the real timer callback.
$tick=Get-Handler '$timer.Add_Tick('
$ps=[pscustomobject]@{Disposed=$false}
$ps | Add-Member ScriptMethod EndInvoke { param($handle) return $null }
$ps | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
$rs=[pscustomobject]@{Disposed=$false}
$rs | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
$handle=[pscustomobject]@{IsCompleted=$false}
$view.Job=[pscustomobject]@{PowerShell=$ps;Runspace=$rs;Handle=$handle;Generation=0}
$view.Kind='Compare'
$view.Shared=@{Cancelled=$false;Error=$null;Result=[pscustomobject]@{Entries=@([pscustomobject]@{Id='same-id';RelativePath='old-private.txt';Classification='Missing';IsAdvanced=$false;IsSensitive=$false});ScanComplete=$true};Progress=[pscustomobject]@{Phase='OLD';File='old-private.txt';FilesProcessed=1;BytesProcessed=1;ErrorCount=0}}
$buttons=@('StartBackup')
$controls.StartBackup=[pscustomobject]@{IsEnabled=$false}
$controls.CancelWork=[pscustomobject]@{IsEnabled=$true}
$before=$controls.Status.Text
& $tick
if($controls.Status.Text -ne $before) { throw 'Obsolete progress replaced active manifest status' }
$handle.IsCompleted=$true
& $tick
if($null -ne $view.Report -or $view.Rows.Count -ne 0 -or $selected.Count -ne 0) { throw 'Obsolete completion repopulated another manifest with old selected file IDs' }
if($null -ne $view.Job -or -not $ps.Disposed -or -not $rs.Disposed) { throw 'Discarded completion did not release its runspace' }
if(-not $controls.StartBackup.IsEnabled -or $controls.CancelWork.IsEnabled) { throw 'Single-flight cleanup failed after stale completion' }
Write-Output 'Production timer rejects obsolete progress and completion and disposes the old worker.'
$ps.Disposed=$false; $rs.Disposed=$false
$ps | Add-Member ScriptMethod EndInvoke { param($handle) throw 'obsolete worker fault' } -Force
$view.Job=[pscustomobject]@{PowerShell=$ps;Runspace=$rs;Handle=$handle;Generation=0}
$before=$controls.Status.Text
& $tick
if($controls.Status.Text -ne $before) { throw 'Obsolete exception replaced active manifest status' }
if(-not $ps.Disposed -or -not $rs.Disposed) { throw 'Faulted obsolete worker leaked resources' }
Write-Output 'Obsolete worker exceptions cannot overwrite the replacement status.'
# Active results still publish, and a new backup's own manifest change must not erase its report.
# Comparison now delegates selection publication through the production filter callback.
$filterNode=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$filterRows'},$true)
$filterText=$filterNode.Right.Extent.Text.Trim()
$filterRows=[scriptblock]::Create($filterText.Substring(1,$filterText.Length-2))
$controls.Search=[pscustomobject]@{Text=''}
$controls.ClassificationFilter=[pscustomobject]@{SelectedItem=[pscustomobject]@{Content='All'}}
$ps | Add-Member ScriptMethod EndInvoke { param($handle) return $null } -Force
$view.Job=[pscustomobject]@{PowerShell=$ps;Runspace=$rs;Handle=$handle;Generation=$view.Generation}
$view.Shared.Progress=$null
& $tick
if($view.Report -ne $view.Shared.Result -or $selected.Count -ne 1) { throw 'Active comparison was not published and selected' }
$manifestControl=New-Object psobject
$manifestControl | Add-Member ScriptProperty Text { return 'old-manifest' } { param($value) & $changed }
$controls.ManifestPath=$manifestControl
$view.Kind='Backup'
$view.Shared.Result=[pscustomobject]@{ManifestPath='new-manifest';State='Verified'}
$view.Job=[pscustomobject]@{PowerShell=$ps;Runspace=$rs;Handle=$handle;Generation=$view.Generation}
$generationBeforePublication=$view.Generation
& $tick
if($view.Report -ne $view.Shared.Result) { throw 'Publishing a backup manifest erased the newly completed backup report' }
if($view.Shared.Cancelled -or $controls.Status.Text -notmatch '^Backup verified' -or $view.Generation -ne $generationBeforePublication) { throw 'RED: publishing a verified backup must not cancel itself, change generation, or claim interruption.' }
Write-Output 'Active comparison and new-backup report publication remain functional.'
# Exercise production launch capture rather than constructing every job by hand.
$startNode=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$start'},$true)
$text=$startNode.Right.Extent.Text.Trim()
$start=[scriptblock]::Create($text.Substring(1,$text.Length-2))
$script:starts=0
function Start-PitrUiWorker { param($ApplicationRoot,$Operation,$Arguments,$State) $script:starts++; return [pscustomobject]@{Handle=$handle;PowerShell=$ps;Runspace=$rs} }
$ApplicationRoot=$root
& $start 'Compare' {} @{}
if($view.Job.Generation -ne $view.Generation) { throw 'Worker launch did not capture the active manifest generation' }
& $start 'Compare' {} @{}
if($script:starts -ne 1) { throw 'Replacement work bypassed single-flight ownership' }
Write-Output 'Production launch captures generation and preserves single-flight ownership.'
