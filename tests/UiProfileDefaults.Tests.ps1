$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Ui.ps1')
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/backup/Ui.ps1'),[ref]$tokens,[ref]$errors)
$switch=$ast.Find({param($n) $n -is [Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -eq '$view.Kind'},$true)
$clause=@($switch.Clauses | Where-Object { $_.Item1.Value -eq 'Discover' })[0]
$discover=[scriptblock]::Create($clause.Item2.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}'))
$selected=New-Object Collections.ArrayList
$list=[pscustomobject]@{ItemsSource=@();SelectedItems=$selected}
$list | Add-Member -MemberType ScriptMethod -Name SelectAll -Value { $this.SelectedItems.Clear(); foreach($item in $this.ItemsSource) { $null=$this.SelectedItems.Add($item) } }
$controls=@{Profiles=$list;Status=[pscustomobject]@{Text=''}}
$result=@(
    [pscustomobject]@{Sid='user-one';Path='C:\Users\One';Inaccessible=$false;Reason=$null},
    [pscustomobject]@{Sid='user-two';Path='C:\Users\Two';Inaccessible=$false;Reason=$null},
    [pscustomobject]@{Sid='unreadable';Path='C:\Users\Locked';Inaccessible=$true;Reason='Access denied'}
)
& $discover
if($list.SelectedItems.Count -ne 3) { throw 'Every discovered profile must be included by default, not just the signed-in user; inaccessible registrations must not disappear.' }
foreach($profile in $result) { if($list.SelectedItems -notcontains $profile) { throw ('Missing default profile: '+$profile.Sid) } }
$list.SelectedItems.Remove($result[1]) | Out-Null
if($list.SelectedItems.Count -ne 2 -or $list.SelectedItems -contains $result[1]) { throw 'The user must be able to remove a default profile.' }
[xml]$xml=Get-PitrBackupXaml
$node=$xml.SelectSingleNode('//*[@*[local-name()="Name"]="Profiles"]')
if($node.GetAttribute('DisplayMemberPath') -ne 'Path') { throw 'Show the actual user folder, not a missing DisplayName property.' }
if($node.GetAttribute('SelectionMode') -ne 'Multiple') { throw 'Removing a profile must not clear all other default selections.' }
# Run the real backup click handler and capture the profile selection it forwards.
$handler=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.StartsWith('$controls.StartBackup.Add_Click(')},$true)
$click=[scriptblock]::Create($handler.Arguments[0].ScriptBlock.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}'))
$controls.Scope=[pscustomobject]@{SelectedItem=[pscustomobject]@{Content='Complete'}}
$controls.CustomPaths=[pscustomobject]@{Text=''}; $controls.Destination=[pscustomobject]@{Text='E:\Backup'}
$ApplicationRoot=$root
$script:forwarded=@()
$start={param($kind,$operation,$argumentsObject) $script:forwarded=@($argumentsObject.Profiles)}
& $click
if($script:forwarded.Count -ne 2 -or $script:forwarded -contains $result[1]) { throw 'Backup must respect the removed profile, not re-add all profiles.' }
$list.SelectedItems.Clear(); $script:forwarded=@()
& $click
if($script:forwarded.Count -ne 0 -or $controls.Status.Text -notmatch 'Select profiles') { throw 'Removing every profile must refuse backup, not silently fall back to all users.' }
$result=@(); & $discover
if($list.SelectedItems.Count -ne 0) { throw 'Empty discovery must not invent a profile.' }
Write-Output 'UI profile defaults passed: all discovered profiles selected; actual folder paths displayed; exclusions forwarded; empty selection refused. Production discovery and backup handler executed with inert controls.'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Output 'SKIP: native WPF profile selection requires Windows.'
    return
}
$rs=[runspacefactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.Open()
$ps=[powershell]::Create(); $ps.Runspace=$rs
try {
    $probe={param($xaml,$discovery)
        $ErrorActionPreference='Stop'
        Add-Type -AssemblyName PresentationFramework
        [xml]$xml=$xaml; $reader=New-Object Xml.XmlNodeReader($xml)
        try { $window=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
        $controls=@{Profiles=$window.FindName('Profiles');Status=$window.FindName('Status')}
        $result=@([pscustomobject]@{Path='C:\Users\One'},[pscustomobject]@{Path='C:\Users\Two'})
        & ([scriptblock]::Create($discovery))
        if($controls.Profiles.SelectedItems.Count -ne 2) { throw 'Native WPF did not select every profile.' }
        $container=[Windows.Controls.ListBoxItem]::new()
        $container.DataContext=$result[0]
        $binding=[Windows.Data.Binding]::new('Path')
        $null=$container.SetBinding([Windows.Controls.ContentControl]::ContentProperty,$binding)
        if([string]$container.Content -ne 'C:\Users\One') { throw 'Native folder path binding failed.' }
        $controls.Profiles.SelectedItems.Remove($result[0])
        if($controls.Profiles.SelectedItems.Count -ne 1 -or $controls.Profiles.SelectedItems[0].Path -ne 'C:\Users\Two') { throw 'Native WPF exclusion cleared the wrong selections.' }
        $window.Close()
        'Native WPF profile defaults and single-profile exclusion passed.'
    }
    $null=$ps.AddScript($probe.ToString()).AddArgument((Get-PitrBackupXaml)).AddArgument($discover.ToString())
    $output=$ps.Invoke()
    if($ps.HadErrors) { throw ($ps.Streams.Error | Out-String) }
    $output | Write-Output
} finally { $ps.Dispose(); $rs.Dispose() }
