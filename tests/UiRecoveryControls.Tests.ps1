$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/backup/Ui.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count) { throw ($errors | Out-String) }
function Get-UiScript([string]$prefix,[string]$assigned='$') {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith($prefix)},$true)
    if(-not $node) { throw ('Missing production UI callback: '+$prefix) }
    $text=$node.Arguments[0].ScriptBlock.Extent.Text.Trim()
    return [scriptblock]::Create($text.Substring(1,$text.Length-2))
}
function Assert([bool]$condition,[string]$message) { if(-not $condition) { throw $message } }
. (Join-Path $root 'src/backup/Ui.ps1')
[xml]$xaml=Get-PitrBackupXaml
$conflictNode=$xaml.SelectSingleNode('//*[@*[local-name()="Name"]="ConflictPolicy"]')
$formatNode=$xaml.SelectSingleNode('//*[@*[local-name()="Name"]="ExportFormat"]')
Assert ($conflictNode.GetAttribute('SelectedIndex') -eq '0' -and $conflictNode.SelectNodes('*[local-name()="ComboBoxItem"]')[0].GetAttribute('Content') -eq 'Skip') 'Conflict control must default to Skip.'
Assert ($formatNode.GetAttribute('SelectedIndex') -eq '0' -and $formatNode.SelectNodes('*[local-name()="ComboBoxItem"]')[0].GetAttribute('Content') -eq 'Json') 'Report format control must default to JSON.'

# Exercise the actual production filtering body; hidden rows and their explicit IDs stay selected.
$filterNode=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$filterRows'},$true)
Assert ($null -ne $filterNode) 'Production result-filter body was not found.'
$filterText=$filterNode.Right.Extent.Text.Trim()
$filter=[scriptblock]::Create($filterText.Substring(1,$filterText.Length-2))
$view=@{Rows=@(
    [pscustomobject]@{Id='one';Classification='Missing';RelativePath='alpha.txt'},
    [pscustomobject]@{Id='two';Classification='Different';RelativePath='beta.txt'},
    [pscustomobject]@{Id='three';Classification='Missing';RelativePath='gamma.txt'}
); SelectedIds=@{one=$true;three=$true}; Filtering=$false}
$controls=@{
    Search=[pscustomobject]@{Text='beta'}
    Results=[pscustomobject]@{ItemsSource=@();SelectedItems=(New-Object 'Collections.Generic.List[object]')}
    ClassificationFilter=[pscustomobject]@{SelectedItem=[pscustomobject]@{Content='All'}}
}
& $filter
Assert ($controls.Results.ItemsSource.Count -eq 1 -and $controls.Results.ItemsSource[0].Id -eq 'two') 'Filter did not restrict displayed results.'
Assert ($view.SelectedIds.Count -eq 2 -and $view.SelectedIds.ContainsKey('one') -and $view.SelectedIds.ContainsKey('three')) 'Filtering broadened or discarded explicit selection IDs.'
$controls.Search.Text=''
$controls.ClassificationFilter.SelectedItem.Content='Missing'
& $filter
Assert ($controls.Results.ItemsSource.Count -eq 2 -and @($controls.Results.ItemsSource | ForEach-Object { $_.Id }) -notcontains 'two') 'Classification filter did not restrict rows.'
Assert ($view.SelectedIds.Count -eq 2) 'Classification filtering changed the explicit selection.'
$selectionChanged=Get-UiScript '$controls.Results.Add_SelectionChanged('
$view.Filtering=$false
$view.SelectedIds=@{one=$true;three=$true}
$controls.Results.ItemsSource=@($view.Rows[0],$view.Rows[1])
$controls.Results.SelectedItems=New-Object 'Collections.Generic.List[object]'
$controls.Results.SelectedItems.Add($view.Rows[1])
& $selectionChanged
Assert ($view.SelectedIds.Count -eq 2 -and $view.SelectedIds.ContainsKey('two') -and $view.SelectedIds.ContainsKey('three') -and -not $view.SelectedIds.ContainsKey('one')) 'Explicit visible selection changes were not tracked without dropping filtered selections.'

# Stale manifest replacement clears selected IDs in the production invalidation callback.
$changed=Get-UiScript '$controls.ManifestPath.Add_TextChanged('
$view.Rows=@([pscustomobject]@{Id='old';Classification='Missing';RelativePath='private.txt'})
$view.SelectedIds=@{old=$true}; $view.Mappings=@('old'); $view.Report='stale'; $view.Generation=0; $view.Shared=$null
$controls.Results.SelectedItems=New-Object 'Collections.Generic.List[object]'
$controls.Results.ItemsSource=$view.Rows
$controls.Mappings=[pscustomobject]@{ItemsSource=$view.Mappings}
$controls.Status=[pscustomobject]@{Text=''}
& $changed
Assert ($view.Generation -eq 1 -and $view.SelectedIds.Count -eq 0 -and $view.Rows.Count -eq 0 -and $null -eq $view.Report) 'Manifest invalidation retained stale selected IDs or report.'

# Exercise the production worker body, not just its command text, for all explicit policies.
$recoverNode=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$recover'},$true)
Assert ($null -ne $recoverNode) 'Production recovery worker setup was not found.'
$recoverText=$recoverNode.Right.Extent.Text.Trim()
$recover=[scriptblock]::Create($recoverText.Substring(1,$recoverText.Length-2))
$workerNode=$recoverNode.Right.FindAll({param($n) $n -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $n.Extent.Text.Contains('Restore-PitrFiles')},$true) | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1
Assert ($null -ne $workerNode) 'Production restore worker body not found inside recovery callback.'
$workerText=$workerNode.Extent.Text.Trim()
$worker=[scriptblock]::Create($workerText.Substring(1,$workerText.Length-2))
$script:captured=$null
function Restore-PitrFiles { param($ManifestPath,$Mappings,$EntryIds,$AlternateRoot,$Conflict,$Execute,$AllowAdvanced,$Cancellation,$Progress) $script:captured=@{Conflict=$Conflict;Execute=[bool]$Execute;Ids=@($EntryIds)}; return [pscustomobject]@{DryRun=(-not $Execute)} }
$view=@{Mappings=@();Generation=4;Job=$null;SelectedIds=@{picked=$true}}
$selected=New-Object 'Collections.Generic.List[object]'
$selected.Add([pscustomobject]@{Id='picked'})
$controls=@{
    Results=[pscustomobject]@{SelectedItems=$selected}
    ConflictPolicy=[pscustomobject]@{SelectedItem=[pscustomobject]@{Content='Skip'}}
    ManifestPath=[pscustomobject]@{Text='manifest.json'}
    AlternateRoot=[pscustomobject]@{Text=''}
    AllowAdvanced=[pscustomobject]@{IsChecked=$false}
    Mappings=[pscustomobject]@{CommitEdit={};}
    Status=[pscustomobject]@{Text=''}
}
$getMappings={ return @{source='root'} }
$starts=New-Object 'Collections.Generic.List[object]'
$start={param($kind,$operation,$argumentsObject) $starts.Add([pscustomobject]@{Kind=$kind;Operation=$operation;Args=$argumentsObject})}
foreach($policy in @('Skip','Alongside','Replace')) {
    $controls.ConflictPolicy.SelectedItem.Content=$policy
    & $recover $false
    $launch=$starts[$starts.Count-1]
    $state=@{Cancelled=$false;Result=$null;Error=$null;Progress=$null}
    & $launch.Operation $state $launch.Args
    Assert ($script:captured.Conflict -eq $policy -and -not $script:captured.Execute) ('Dry-run did not forward conflict policy '+$policy)
    & $worker $state $launch.Args
    Assert ($script:captured.Conflict -eq $policy -and -not $script:captured.Execute) ('Worker dry-run did not forward '+$policy)
    $executeArgs=$launch.Args.Clone(); $executeArgs.Execute=$true
    & $worker $state $executeArgs
    Assert ($script:captured.Conflict -eq $policy -and $script:captured.Execute) ('Execute worker did not forward '+$policy)
    Assert ($script:captured.Ids.Count -eq 1 -and $script:captured.Ids[0] -eq 'picked') 'Recovery worker selection changed.'
}

# Execute confirmation must describe preservation when Replace is explicitly selected.
$recoverNodeText=$recoverNode.Right.Extent.Text
Assert ($recoverNodeText -match 'MessageBoxResult\]::No') 'RED: execute recovery confirmation must explicitly default to No.'
Assert ($recoverNodeText -match 'Replace' -and $recoverNodeText -match 'preserv') 'Execute confirmation does not disclose Replace preservation.'

# Export control passes selected format and warns that filenames are private.
$exportHandler=Get-UiScript '$controls.ExportReport.Add_Click('
$exportWorkerNode=$ast.FindAll({param($n) $n -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $n.Extent.Text.Contains('Export-PitrReport')},$true) | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 1
Assert ($null -ne $exportWorkerNode) 'Production export worker body was not found.'
$exportText=$exportWorkerNode.Extent.Text.Trim()
$exportWorker=[scriptblock]::Create($exportText.Substring(1,$exportText.Length-2))
$script:exportArgs=$null
function Export-PitrReport { param($Report,$Path,$Format) $script:exportArgs=@{Report=$Report;Path=$Path;Format=$Format} }
& $exportWorker @{Result=$null} @{Report=[pscustomobject]@{Entries=@()};Path='report.csv';Format='Csv'}
Assert ($script:exportArgs.Format -eq 'Csv' -and $script:exportArgs.Path -eq 'report.csv') 'Export worker did not forward chosen format and path.'
$ui=(Get-Content (Join-Path $root 'src/backup/Ui.ps1') -Raw)
Assert ($ui -match 'Reports contain private filenames') 'UI lacks local-report privacy warning.'
Write-Output 'UI recovery controls: production filter, worker forwarding, selection, Replace disclosure, and report format assertions passed.'
