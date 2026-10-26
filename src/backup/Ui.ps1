# Presentation helpers load without WPF so worker orchestration is testable offline.
function Get-PitrBackupXaml {
@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Backup and Recovery" Width="980" Height="740" MinWidth="680" MinHeight="520" WindowStartupLocation="CenterScreen">
 <DockPanel Margin="12">
  <StackPanel DockPanel.Dock="Top">
   <TextBlock x:Name="ApplicationWarning" TextWrapping="Wrap" FontWeight="Bold" Margin="0,0,0,8" Text="Warning: rollback can remove or revert apps, drivers and updates installed since the restore point. You may need to reinstall or repair apps. A file backup does not preserve installed apps or reinstall them. Close apps before live backup."/>
   <TextBlock TextWrapping="Wrap" Margin="0,0,0,8" Text="Live copies are not application-consistent. Close applications first. Review cloud placeholders and EFS limitations. Keep BitLocker keys separately. Reports contain private filenames. This tool never starts PITR."/>
   <TextBlock x:Name="Status" Text="Restore readiness: not assessed" TextWrapping="Wrap" Margin="0,0,0,8"/>
  </StackPanel>
  <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
  <Button x:Name="CancelWork" Content="Cancel operation" Padding="12,5" IsEnabled="False"/>
  <ComboBox x:Name="ExportFormat" SelectedIndex="0" Width="90" Margin="8,0"><ComboBoxItem Content="Json"/><ComboBoxItem Content="Csv"/><ComboBoxItem Content="Text"/></ComboBox>
  <Button x:Name="ExportReport" Content="Export local report" Padding="12,5" Margin="0,0,8,0"/>
  </StackPanel>
  <TabControl x:Name="Tabs">
   <TabItem Header="Backup Before Restore"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
    <TextBlock Text="1. All discovered user folders are included by default" FontWeight="Bold"/>
    <TextBlock Text="Click a selected folder to exclude it. Complete includes the profile tree and AppData where readable. Unreadable profiles must be resolved or explicitly excluded." TextWrapping="Wrap"/>
    <ListBox x:Name="Profiles" Height="130" SelectionMode="Multiple" DisplayMemberPath="Path"/>
    <ComboBox x:Name="Scope" SelectedIndex="0" Margin="0,8"><ComboBoxItem Content="Complete"/><ComboBoxItem Content="Personal"/><ComboBoxItem Content="Custom"/></ComboBox>
    <TextBlock Text="Custom folders (one absolute path per line). Review redirected personal folders explicitly." TextWrapping="Wrap"/>
    <TextBox x:Name="CustomPaths" Height="60" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
    <TextBlock Text="2. Choose destination outside the OS volume; external media recommended" FontWeight="Bold" Margin="0,12,0,4"/>
    <DockPanel><Button x:Name="BrowseDestination" Content="Browse..." DockPanel.Dock="Right" Padding="12,3"/><TextBox x:Name="Destination"/></DockPanel>
    <TextBlock Text="3. Backup and 4. Full verification run in the background. Each generation remains separate." TextWrapping="Wrap" Margin="0,12,0,4"/>
    <Button x:Name="StartBackup" Content="Backup and verify" HorizontalAlignment="Left" Padding="12,6"/>
   </StackPanel></ScrollViewer></TabItem>
   <TabItem Header="Verify / Compare and Recover"><DockPanel Margin="12">
    <StackPanel DockPanel.Dock="Top">
     <DockPanel><Button x:Name="BrowseManifest" Content="Browse manifest..." DockPanel.Dock="Right"/><TextBox x:Name="ManifestPath"/></DockPanel>
     <StackPanel Orientation="Horizontal" Margin="0,8"><Button x:Name="VerifyBackup" Content="Full verification" Padding="8,4"/><Button x:Name="LoadMappings" Content="Load mapping rows" Padding="8,4" Margin="8,0"/><Button x:Name="CompareBackup" Content="Deep comparison" Padding="8,4"/></StackPanel>
     <TextBlock Text="Approve each SourceId mapping by entering its CURRENT root. Blank roots are not guessed. AppData is advanced; prefer alternate recovery." TextWrapping="Wrap"/>
     <DataGrid x:Name="Mappings" Height="100" AutoGenerateColumns="False" CanUserAddRows="False"><DataGrid.Columns><DataGridTextColumn Header="SourceId" Binding="{Binding SourceId}" IsReadOnly="True" Width="*"/><DataGridTextColumn Header="Original root (reference only)" Binding="{Binding OriginalPath}" IsReadOnly="True" Width="*"/><DataGridTextColumn Header="Approved current root" Binding="{Binding TargetRoot}" Width="*"/></DataGrid.Columns></DataGrid>
     <DockPanel Margin="0,8"><TextBlock DockPanel.Dock="Left" Text="Search path: "/><TextBox x:Name="Search"/><TextBlock DockPanel.Dock="Left" Text="Classification: " Margin="8,0,0,0"/><ComboBox x:Name="ClassificationFilter" SelectedIndex="0" Width="130"><ComboBoxItem Content="All"/><ComboBoxItem Content="Missing"/><ComboBoxItem Content="Different"/><ComboBoxItem Content="Identical"/><ComboBoxItem Content="LikelyIdentical"/><ComboBoxItem Content="CurrentOnly"/><ComboBoxItem Content="Unknown"/></ComboBox></DockPanel>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom">
     <TextBlock Text="Select files explicitly. Missing personal files only is the default selection. Existing files are kept (conflict: Skip). Executable/startup recovery into live profiles is refused." TextWrapping="Wrap"/>
     <DockPanel Margin="0,6"><TextBlock DockPanel.Dock="Left" Text="Conflict when destination exists: "/><ComboBox x:Name="ConflictPolicy" SelectedIndex="0" Width="130"><ComboBoxItem Content="Skip"/><ComboBoxItem Content="Alongside"/><ComboBoxItem Content="Replace"/></ComboBox></DockPanel>
     <DockPanel Margin="0,6"><TextBlock DockPanel.Dock="Left" Text="Alternate recovery root (recommended): "/><TextBox x:Name="AlternateRoot"/></DockPanel>
     <CheckBox x:Name="AllowAdvanced" Content="I explicitly approve advanced AppData recovery; applications must be closed"/>
     <StackPanel Orientation="Horizontal" Margin="0,6"><Button x:Name="PreviewRecovery" Content="Preview selected recovery" Padding="10,5"/><Button x:Name="RecoverFiles" Content="Execute selected recovery..." Padding="10,5" Margin="8,0"/></StackPanel>
    </StackPanel>
    <DataGrid x:Name="Results" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Extended" SelectionUnit="FullRow" EnableRowVirtualization="True" EnableColumnVirtualization="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" CanUserAddRows="False"><DataGrid.Columns><DataGridTextColumn Header="Status" Binding="{Binding Classification}"/><DataGridTextColumn Header="Relative path" Binding="{Binding RelativePath}" Width="*"/><DataGridTextColumn Header="Advanced" Binding="{Binding IsAdvanced}"/><DataGridTextColumn Header="Error" Binding="{Binding Error}" Width="*"/></DataGrid.Columns></DataGrid>
   </DockPanel></TabItem>
  </TabControl>
 </DockPanel>
</Window>
'@
}

function Show-PitrBackupUi {
    [CmdletBinding()]
    param([ValidateSet('Backup','Verify','Recover')][string]$Mode='Backup',[string]$ApplicationRoot,[string]$ManifestPath,[string]$Language='en')
    if ($env:OS -ne 'Windows_NT') { throw 'The graphical interface requires Windows with WPF.' }
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Windows.Forms
    [xml]$xml=Get-PitrBackupXaml
    $reader=New-Object Xml.XmlNodeReader($xml)
    try { $window=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
    $controls=@{}
    foreach($node in $xml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        $controls[$name]=$window.FindName($name)
    }
    . (Join-Path $ApplicationRoot 'src/backup/Localization.ps1')
    $labels=Get-PitrBackupLabels -Language $Language
    foreach($key in $labels.Keys) { if($controls.ContainsKey($key)) { $controls[$key].Content=$labels[$key] } }
    $view=@{Job=$null;Shared=$null;Kind='';Report=$null;Rows=@();Mappings=@();SelectedIds=@{};Filtering=$false;Generation=0}
    $buttons=@('StartBackup','VerifyBackup','LoadMappings','CompareBackup','PreviewRecovery','RecoverFiles')
    $start={ param($kind,$operation,$argumentsObject)
        if($null -ne $view.Job) { return }
        $view.Shared=[hashtable]::Synchronized(@{Cancelled=$false;Result=$null;Error=$null;Progress=$null})
        $view.Kind=$kind
        $view.Job=Start-PitrUiWorker -ApplicationRoot $ApplicationRoot -Operation $operation -Arguments $argumentsObject -State $view.Shared
        $view.Job | Add-Member -NotePropertyName Generation -NotePropertyValue $view.Generation
        foreach($name in $buttons) { $controls[$name].IsEnabled=$false }
        $controls.CancelWork.IsEnabled=$true
        $controls.Status.Text=$kind+' running; restore readiness not assessed.'
    }
    $getMappings={
        $null=$controls.Mappings.CommitEdit()
        $null=$controls.Mappings.CommitEdit()
        $map=@{}
        foreach($row in $view.Mappings) {
            if(-not [string]::IsNullOrWhiteSpace($row.TargetRoot)) { $map[[string]$row.SourceId]=[string]$row.TargetRoot }
        }
        return $map
    }
    $controls.BrowseDestination.Add_Click({
        $dialog=New-Object Windows.Forms.FolderBrowserDialog
        try { if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $controls.Destination.Text=$dialog.SelectedPath } } finally { $dialog.Dispose() }
    })
    $controls.ManifestPath.Add_TextChanged({
        $view.Generation++
        if($view.Shared) { $view.Shared.Cancelled=$true }
        $view.Rows=@(); $view.Mappings=@(); $view.Report=$null; $view.SelectedIds=@{}
        $controls.Results.SelectedItems.Clear()
        $controls.Results.ItemsSource=@()
        $controls.Mappings.ItemsSource=@()
        $controls.Status.Text='Manifest changed. Load mappings and compare again before recovery.'
    })
    $controls.BrowseManifest.Add_Click({
        $dialog=New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter='Backup manifest|manifest.json|JSON|*.json'
        if($dialog.ShowDialog()) { $controls.ManifestPath.Text=$dialog.FileName }
    })
    $controls.CancelWork.Add_Click({ if($view.Shared) { $view.Shared.Cancelled=$true; $controls.Status.Text='Cancellation requested; completed files are retained.' } })
    $controls.StartBackup.Add_Click({
        $profiles=@($controls.Profiles.SelectedItems)
        $scopeValue=[string]$controls.Scope.SelectedItem.Content
        $paths=@($controls.CustomPaths.Text -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if($scopeValue -ne 'Custom' -and $profiles.Count -eq 0) { $controls.Status.Text='Select profiles explicitly.'; return }
        & $start 'Backup' {
            param($state,$a)
            $sources=@(Get-PitrSourceRoots -Profiles $a.Profiles -Scope $a.Scope -CustomPaths $a.Paths)
            $progress={param($p) $state.Progress=$p}.GetNewClosure()
            $state.Result=New-PitrBackup -Sources $sources -Destination $a.Destination -Scope $a.Scope -RecoverySource $a.Root -Cancellation $state -Progress $progress
            if($state.Result.State -eq 'CopyCompleted' -and -not $state.Cancelled) {
                $state.Result=Test-PitrBackup -ManifestPath $state.Result.ManifestPath -Mode Full -Cancellation $state -Progress $progress
            }
        } @{Profiles=$profiles;Scope=$scopeValue;Paths=$paths;Destination=$controls.Destination.Text;Root=$ApplicationRoot}
    })
    $controls.VerifyBackup.Add_Click({
        & $start 'Verify' {param($state,$a) $progress={param($p) $state.Progress=$p}.GetNewClosure(); $state.Result=Test-PitrBackup -ManifestPath $a.Path -Mode Full -Cancellation $state -Progress $progress} @{Path=$controls.ManifestPath.Text}
    })
    $controls.LoadMappings.Add_Click({
        & $start 'Mappings' {param($state,$a) $manifest=Read-PitrManifest -ManifestPath $a.Path; $state.Result=@($manifest.Sources | ForEach-Object { [pscustomobject]@{SourceId=$_.Id;OriginalPath=$_.Path;TargetRoot=''} })} @{Path=$controls.ManifestPath.Text}
    })
    $controls.CompareBackup.Add_Click({
        $map=& $getMappings
        & $start 'Compare' {param($state,$a) $progress={param($p) $state.Progress=$p}.GetNewClosure(); $state.Result=Compare-PitrBackup -ManifestPath $a.Path -Mappings $a.Map -Deep -Cancellation $state -Progress $progress} @{Path=$controls.ManifestPath.Text;Map=$map}
    })
    $recover={param([bool]$execute)
        $ids=@($view.SelectedIds.Keys)
        if($ids.Count -eq 0) { $controls.Status.Text='Select files explicitly after comparison.'; return }
        $policy=[string]$controls.ConflictPolicy.SelectedItem.Content
        if($policy -notin @('Skip','Alongside','Replace')) { $policy='Skip' }
        if($execute) {
            $message='Write selected backup files? Conflict policy: '+$policy+'.'
            if($policy -eq 'Replace') { $message+=' Replace preserves the current file in a unique conflict store before writing the backup copy.' }
            $message+=' AppData requires explicit approval. Review the preview first.'
            if([Windows.MessageBox]::Show($message,'Confirm recovery',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning,[Windows.MessageBoxResult]::No) -ne [Windows.MessageBoxResult]::Yes) { return }
        }
        $map=& $getMappings
        & $start 'Recovery' {
            param($state,$a)
            $progress={param($p) $state.Progress=$p}.GetNewClosure()
            $state.Result=Restore-PitrFiles -ManifestPath $a.Path -Mappings $a.Map -EntryIds $a.Ids -AlternateRoot $a.Alternate -Conflict $a.Conflict -Execute:([bool]$a.Execute) -AllowAdvanced:([bool]$a.Advanced) -Cancellation $state -Progress $progress
        } @{Path=$controls.ManifestPath.Text;Map=$map;Ids=$ids;Alternate=$controls.AlternateRoot.Text;Conflict=$policy;Execute=$execute;Advanced=[bool]$controls.AllowAdvanced.IsChecked}
    }
    $controls.PreviewRecovery.Add_Click({ & $recover $false })
    $controls.RecoverFiles.Add_Click({ & $recover $true })
    $filterRows={
        $query=$controls.Search.Text
        $classification=[string]$controls.ClassificationFilter.SelectedItem.Content
        $visible=@($view.Rows | Where-Object {
            ($classification -eq 'All' -or $_.Classification -eq $classification) -and
            ([string]::IsNullOrEmpty($query) -or $_.RelativePath.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0)
        })
        $view.Filtering=$true
        try {
            $controls.Results.ItemsSource=$visible
            foreach($row in $visible) { if($view.SelectedIds.ContainsKey([string]$row.Id)) { $null=$controls.Results.SelectedItems.Add($row) } }
        } finally { $view.Filtering=$false }
    }
    $controls.Search.Add_TextChanged({ & $filterRows })
    $controls.ClassificationFilter.Add_SelectionChanged({ & $filterRows })
    $controls.Results.Add_SelectionChanged({
        if($view.Filtering) { return }
        $visibleIds=@{}; foreach($row in @($controls.Results.ItemsSource)) { $visibleIds[[string]$row.Id]=$true }
        foreach($id in @($visibleIds.Keys)) { if(@($controls.Results.SelectedItems | ForEach-Object { [string]$_.Id }) -notcontains $id) { $view.SelectedIds.Remove($id) } }
        foreach($row in $controls.Results.SelectedItems) { $view.SelectedIds[[string]$row.Id]=$true }
    })
    $controls.ExportReport.Add_Click({
        if($null -eq $view.Report) { return }
        $format=[string]$controls.ExportFormat.SelectedItem.Content
        if($format -notin @('Json','Csv','Text')) { $format='Json' }
        $extensions=@{Json='json';Csv='csv';Text='txt'}
        $extension=$extensions[$format]
        $dialog=New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter=($format+' report|*.'+$extension); $dialog.FileName=('pitr-report.'+$extension)
        if($dialog.ShowDialog()) {
            & $start 'Export' {param($state,$a) Export-PitrReport -Report $a.Report -Path $a.Path -Format $a.Format; $state.Result='Local report exported; filenames may be private.'} @{Report=$view.Report;Path=$dialog.FileName;Format=$format}
        }
    })
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[timespan]::FromMilliseconds(250)
    $timer.Add_Tick({
        if($null -eq $view.Job) { return }
        $p=$view.Shared.Progress
        if($p -and $view.Job.Generation -eq $view.Generation) { $controls.Status.Text=('{0}: {1} | {2} files | {3} bytes | errors {4}' -f $p.Phase,$p.File,$p.FilesProcessed,$p.BytesProcessed,$p.ErrorCount) }
        if(-not $view.Job.Handle.IsCompleted) { return }
        try {
            $null=$view.Job.PowerShell.EndInvoke($view.Job.Handle)
            if($view.Job.Generation -ne $view.Generation) { return }
            if($view.Shared.Error) { throw $view.Shared.Error }
            $result=$view.Shared.Result
            switch($view.Kind) {
                'Discover' { $controls.Profiles.ItemsSource=@($result); $controls.Profiles.SelectAll(); $controls.Status.Text='All discovered profiles selected. Click a folder to exclude it. Unreadable profiles block backup until resolved or explicitly excluded. Restore readiness not assessed.' }
                'Mappings' { $view.Mappings=@($result); $controls.Mappings.ItemsSource=$view.Mappings; $controls.Status.Text='Enter approved current roots before comparison.' }
                'Compare' {
                    $view.Report=$result; $view.Rows=@($result.Entries); $view.SelectedIds=@{}
                    $controls.Results.ItemsSource=$view.Rows
                    foreach($row in $view.Rows) {
                        if($row.Classification -eq 'Missing' -and -not $row.IsAdvanced -and -not $row.IsSensitive) {
                            $view.SelectedIds[[string]$row.Id]=$true
                        }
                    }
                    & $filterRows
                    $controls.Status.Text='Comparison finished. Scan complete: '+$result.ScanComplete+'. Review errors before recovery.'
                }
                'Backup' { $controls.ManifestPath.Text=$result.ManifestPath; $view.Report=$result; $controls.Status.Text='Backup state: '+$result.State+'. Restore readiness NOT assessed: verify package, restore point and media access; retain BitLocker key separately.' }
                'Verify' { $view.Report=$result; $controls.Status.Text='Verification state: '+$result.State+'. Integrity does not prove application consistency or restore readiness.' }
                'Recovery' { $view.Report=$result; $controls.Status.Text='Recovery complete: '+$result.Complete+'; dry run: '+$result.DryRun+'. Inspect/export results.' }
                'Export' { $controls.Status.Text=[string]$result }
            }
        } catch { if($view.Job.Generation -eq $view.Generation) { $controls.Status.Text='Operation failed: '+$_.Exception.Message } }
        finally {
            $view.Job.PowerShell.Dispose(); $view.Job.Runspace.Dispose(); $view.Job=$null
            foreach($name in $buttons) { $controls[$name].IsEnabled=$true }
            $controls.CancelWork.IsEnabled=$false
        }
    })
    $window.Add_Closing({param($sender,$eventArgs) if($view.Job) { $eventArgs.Cancel=$true; $view.Shared.Cancelled=$true; $controls.Status.Text='Waiting for safe cancellation. Close after operation stops.' } })
    if($ManifestPath) { $controls.ManifestPath.Text=$ManifestPath }
    if($Mode -ne 'Backup') { $controls.Tabs.SelectedIndex=1 }
    $window.Add_ContentRendered({ & $start 'Discover' {param($state,$a) $state.Result=@(Get-PitrProfiles)} @{} })
    $timer.Start()
    try { $null=$window.ShowDialog() } finally { $timer.Stop() }
}

function Start-PitrUiWorker {
    [CmdletBinding()]
    param([string]$ApplicationRoot,[scriptblock]$Operation,$Arguments,[hashtable]$State)
    $runspace=[runspacefactory]::CreateRunspace()
    $runspace.ApartmentState='STA'
    $runspace.ThreadOptions='ReuseThread'
    $runspace.Open()
    $ps=[powershell]::Create()
    $ps.Runspace=$runspace
    $bootstrap={
        param($root,$operationText,$shared,$argumentsObject)
        $ErrorActionPreference='Stop'
        try {
            foreach($module in @('Platform','Manifest','Backup','Recovery')) {
                . (Join-Path $root ('src/backup/'+$module+'.ps1'))
            }
            # Only an application-owned scriptblock is serialized by the caller, never manifest content.
            & ([scriptblock]::Create($operationText)) $shared $argumentsObject
        } catch { $shared.Error=$_.Exception.ToString(); throw }
    }
    try {
        $null=$ps.AddScript($bootstrap.ToString()).AddArgument($ApplicationRoot).AddArgument($Operation.ToString()).AddArgument($State).AddArgument($Arguments)
        $handle=$ps.BeginInvoke()
        return [pscustomobject]@{PowerShell=$ps;Runspace=$runspace;Handle=$handle}
    } catch { $ps.Dispose(); $runspace.Dispose(); throw }
}
