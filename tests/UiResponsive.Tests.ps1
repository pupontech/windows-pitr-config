$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Ui.ps1')
function Assert($ok,[string]$why) { if(-not $ok) { throw $why } }
# Physical 1080p with a 40px taskbar; dimensions supplied in WPF logical units.
foreach($scale in @(1.0,1.25,1.5,1.75,2.0,2.5)) {
    $workWidth=1920/$scale; $workHeight=1040/$scale
    $b=Get-PitrUiWindowBounds -WorkWidth $workWidth -WorkHeight $workHeight
    Assert ($b.Width -le $workWidth -and $b.Height -le $workHeight) ('RED: startup window exceeds a 1080p work area at scale '+$scale)
    Assert ($b.MinWidth -le $b.Width -and $b.MinHeight -le $b.Height -and $b.MaxWidth -le $workWidth -and $b.MaxHeight -le $workHeight) 'Minimum/maximum constraints must not force a window off screen.'
    $m=Get-PitrUiWindowBounds -WorkWidth $workWidth -WorkHeight $workHeight -PreferredWidth 900 -PreferredHeight 800
    Assert ($m.Width -le $workWidth -and $m.Height -le $workHeight) 'Main window also needs bounded dimensions.'
}
[xml]$xml=Get-PitrBackupXaml
$scroll=$xml.SelectSingleNode('//*[@*[local-name()="Name"]="MainScroll"]')
Assert ($null -ne $scroll -and $scroll.LocalName -eq 'ScrollViewer') 'All tall backup/restore content must share a bounded scroll viewport.'
foreach($name in @('ApplicationWarning','Status','Tabs','DetailsPanel')) {
    $node=$xml.SelectSingleNode('//*[@*[local-name()="Name"]="'+$name+'"]')
    Assert ($null -ne $node.SelectSingleNode('ancestor::*[@*[local-name()="Name"]="MainScroll"]')) ('Tall region is outside the responsive viewport: '+$name)
}
$footer=$xml.SelectSingleNode('//*[@*[local-name()="Name"]="ActionFooter"]')
Assert ($null -ne $footer -and $footer.LocalName -eq 'WrapPanel') 'Persistent bottom actions must wrap on narrow windows.'
Assert ($null -eq $footer.SelectSingleNode('ancestor::*[local-name()="ScrollViewer"]')) 'Cancel/details must remain reachable outside the scrolling content.'
$cmd=[IO.File]::ReadAllText((Join-Path $root 'pitr-config.cmd'))
Assert ($cmd.Contains('Get-PitrUiWindowBounds')) 'Main window must use the same tested work-area sizing policy.'
$mainHelper=[regex]::Match($cmd,'(?ms)^function Get-PitrUiWindowBounds \{.*?^\}').Value
$t=$null;$e=$null
$uiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/backup/Ui.ps1'),[ref]$t,[ref]$e)
$backupHelper=$uiAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PitrUiWindowBounds'},$true).Extent.Text
Assert ($mainHelper.Replace("`r`n","`n") -ceq $backupHelper.Replace("`r`n","`n")) 'Standalone and backup sizing policies must not drift.'
Assert ($cmd.Contains('x:Name="MainActions"')) 'Main action row must have a responsive wrapping layout.'
$detailsHandler=$uiAst.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$controls.ShowDetails.Add_Click(')},$true)
$text=$detailsHandler.Arguments[0].ScriptBlock.Extent.Text.Trim();$click=[scriptblock]::Create($text.Substring(1,$text.Length-2))
$script:detailsReached=$false
$panel=[pscustomobject]@{IsExpanded=$false};$panel | Add-Member ScriptMethod BringIntoView { $script:detailsReached=$true }
$window=[pscustomobject]@{};$window | Add-Member ScriptMethod UpdateLayout {}
$view=@{Report=$null};$controls=@{DetailsText=[pscustomobject]@{Text=''};DetailsPanel=$panel;Status=[pscustomobject]@{Text='Backup verified'}}
& $click
Assert ($panel.IsExpanded -and $script:detailsReached) 'Opening details must scroll it into view, not silently expand it below the fold.'
Write-Output '1080p logical work-area sizing (100/125/150/175/200/250%) and scroll/wrap contracts passed.'
