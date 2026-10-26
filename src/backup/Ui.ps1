# Presentation helpers load without WPF so worker orchestration is testable offline.
function Get-PitrBackupXaml {
@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Backup and Recovery" Width="980" Height="740" MinWidth="680" MinHeight="520" WindowStartupLocation="CenterScreen">
 <DockPanel Margin="16">
  <DockPanel.Resources>
   <Style TargetType="Button"><Setter Property="Margin" Value="0,4,8,4"/><Setter Property="Padding" Value="12,6"/></Style>
   <Style TargetType="Expander"><Setter Property="Margin" Value="0,8,0,4"/></Style>
  </DockPanel.Resources>
  <StackPanel DockPanel.Dock="Top">
   <TextBlock x:Name="ApplicationWarning" TextWrapping="Wrap" FontWeight="Bold" Margin="0,0,0,8" Text="Warning: rollback can remove or revert apps, drivers and updates installed since the restore point. You may need to reinstall or repair apps. A file backup does not preserve installed apps or reinstall them. Close apps before live backup."/>
   <TextBlock TextWrapping="Wrap" Margin="0,0,0,8" Text="Live copies are not application-consistent. Close applications first. Review cloud placeholders and EFS limitations. Keep BitLocker keys separately. Reports contain private filenames. This tool never starts PITR."/>
   <TextBlock x:Name="Status" Text="Restore readiness: not assessed" TextWrapping="Wrap" Margin="0,0,0,8"/>
  </StackPanel>
  <StackPanel DockPanel.Dock="Bottom">
   <StackPanel Orientation="Horizontal"><Button x:Name="CancelWork" Content="Cancel operation" IsEnabled="False"/><Button x:Name="ShowDetails" Content="View details"/></StackPanel>
   <Expander x:Name="DetailsPanel" Header="Details and reports" IsExpanded="False">
    <StackPanel><TextBox x:Name="DetailsText" Height="100" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
     <StackPanel Orientation="Horizontal"><ComboBox x:Name="ExportFormat" SelectedIndex="0" Width="90"><ComboBoxItem Content="Json"/><ComboBoxItem Content="Csv"/><ComboBoxItem Content="Text"/></ComboBox><Button x:Name="ExportReport" Content="Save report"/></StackPanel>
    </StackPanel>
   </Expander>
  </StackPanel>
  <TabControl x:Name="Tabs">
   <TabItem Header="Back up files"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
    <TextBlock Text="Back up every user's files" FontSize="20" FontWeight="Bold"/>
    <TextBlock Text="All discovered user folders are included, with AppData where readable. Close apps before starting. Verification runs automatically." TextWrapping="Wrap" Margin="0,8"/>
    <TextBlock Text="1. Where should the backup be saved?" FontWeight="Bold"/>
    <TextBlock Text="Choose separate storage, preferably an external drive. The Windows drive is not allowed." TextWrapping="Wrap"/>
    <DockPanel><Button x:Name="BrowseDestination" Content="Choose folder..." DockPanel.Dock="Right"/><TextBox x:Name="Destination" VerticalContentAlignment="Center"/></DockPanel>
    <Expander x:Name="BackupFolders" Header="Change folders (all users included by default)" IsExpanded="False"><StackPanel>
     <TextBlock Text="Click a selected user folder to exclude it. Unreadable profiles must be resolved or explicitly excluded. Review redirected and cloud folders separately." TextWrapping="Wrap"/>
     <ListBox x:Name="Profiles" Height="130" SelectionMode="Multiple" DisplayMemberPath="Path"/>
    </StackPanel></Expander>
    <Expander Header="Advanced backup options" IsExpanded="False"><StackPanel>
     <TextBlock Text="Complete: entire profiles. Personal: conventional personal folders only. Custom: only the explicit paths below." TextWrapping="Wrap"/>
     <ComboBox x:Name="Scope" SelectedIndex="0"><ComboBoxItem Content="Complete"/><ComboBoxItem Content="Personal"/><ComboBoxItem Content="Custom"/></ComboBox>
     <TextBlock Text="Additional folders (one absolute path per line); Custom uses only these paths." TextWrapping="Wrap"/>
     <TextBox x:Name="CustomPaths" Height="60" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
    </StackPanel></Expander>
    <TextBlock Text="2. Start the backup" FontWeight="Bold" Margin="0,12,0,4"/>
    <Button x:Name="StartBackup" Content="Start backup" HorizontalAlignment="Left"/>
   </StackPanel></ScrollViewer></TabItem>
   <TabItem Header="Restore files"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12">
    <TextBlock Text="Restore missing files" FontSize="20" FontWeight="Bold"/>
    <TextBlock Text="Existing files are kept. No files are written until you review a preview and confirm restoration." TextWrapping="Wrap" Margin="0,8"/>
    <TextBlock Text="1. Choose the dated backup folder" FontWeight="Bold"/>
    <Button x:Name="ChooseBackup" Content="Choose backup folder..." HorizontalAlignment="Left"/>
    <TextBlock x:Name="BackupLocation" Text="No backup selected" TextWrapping="Wrap"/>
    <TextBlock Text="2. Review where files will be restored" FontWeight="Bold" Margin="0,12,0,4"/>
    <TextBlock Text="Suggestions use the Windows account identity, never just its name. If a folder is blank, enter its correct current location. Each source needs a location." TextWrapping="Wrap"/>
    <DataGrid x:Name="Mappings" Height="100" AutoGenerateColumns="False" CanUserAddRows="False"><DataGrid.Columns><DataGridTextColumn Header="Backed-up folder" Binding="{Binding OriginalPath}" IsReadOnly="True" Width="*"/><DataGridTextColumn Header="Restore into this folder" Binding="{Binding TargetRoot}" Width="*"/></DataGrid.Columns></DataGrid>
    <CheckBox x:Name="MappingsApproved" Content="These are the correct folders for these users" Margin="0,8"/>
    <Button x:Name="FindMissing" Content="Find missing files" HorizontalAlignment="Left"/>
    <TextBlock x:Name="RestoreSummary" Text="Choose a backup to get started." TextWrapping="Wrap" Margin="0,8"/>
    <TextBlock Text="3. Review the selected files, preview, then restore" FontWeight="Bold"/>
    <TextBlock Text="Missing personal files are selected automatically. AppData and executable/startup files are not selected automatically." TextWrapping="Wrap"/>
    <DataGrid x:Name="Results" Height="160" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Extended" SelectionUnit="FullRow" EnableRowVirtualization="True" EnableColumnVirtualization="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" CanUserAddRows="False"><DataGrid.Columns><DataGridTextColumn Header="Status" Binding="{Binding Classification}"/><DataGridTextColumn Header="File" Binding="{Binding RelativePath}" Width="*"/><DataGridTextColumn Header="Advanced" Binding="{Binding IsAdvanced}"/><DataGridTextColumn Header="Problem" Binding="{Binding Error}" Width="*"/></DataGrid.Columns></DataGrid>
    <StackPanel Orientation="Horizontal"><Button x:Name="PreviewRecovery" Content="Preview restore"/><Button x:Name="RecoverFiles" Content="Restore selected files..."/></StackPanel>
    <Expander Header="Advanced restore options" IsExpanded="False"><StackPanel>
     <TextBlock Text="Existing files: Skip keeps them, Alongside makes a separate copy, Replace preserves the current file before replacing it. Preview again after changes." TextWrapping="Wrap"/>
     <ComboBox x:Name="ConflictPolicy" SelectedIndex="0" Width="130" HorizontalAlignment="Left"><ComboBoxItem Content="Skip"/><ComboBoxItem Content="Alongside"/><ComboBoxItem Content="Replace"/></ComboBox>
     <TextBlock Text="Optional alternate recovery folder (must already exist):"/><TextBox x:Name="AlternateRoot"/>
     <CheckBox x:Name="AllowAdvanced" Content="I explicitly approve advanced AppData recovery; applications must be closed"/>
     <DockPanel><TextBlock Text="Search files: "/><TextBox x:Name="Search"/></DockPanel>
     <ComboBox x:Name="ClassificationFilter" SelectedIndex="0" Width="130" HorizontalAlignment="Left"><ComboBoxItem Content="All"/><ComboBoxItem Content="Missing"/><ComboBoxItem Content="Different"/><ComboBoxItem Content="Identical"/><ComboBoxItem Content="LikelyIdentical"/><ComboBoxItem Content="CurrentOnly"/><ComboBoxItem Content="Unknown"/></ComboBox>
     <TextBlock Text="Advanced: open a manifest directly, recheck a backup, or reload folder suggestions." TextWrapping="Wrap"/>
     <DockPanel><Button x:Name="BrowseManifest" Content="Open manifest..." DockPanel.Dock="Right"/><TextBox x:Name="ManifestPath"/></DockPanel>
     <WrapPanel><Button x:Name="VerifyBackup" Content="Check backup again"/><Button x:Name="LoadMappings" Content="Reload folders"/><Button x:Name="CompareBackup" Content="Compare all files"/></WrapPanel>
    </StackPanel></Expander>
   </StackPanel></ScrollViewer></TabItem>
  </TabControl>
 </DockPanel>
</Window>
'@
}

function Resolve-PitrUiBackupFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not [IO.Directory]::Exists($Path)) { throw 'Choose an existing dated backup folder.' }
    $manifest=Join-Path ([IO.Path]::GetFullPath($Path)) 'manifest.json'
    if(-not [IO.File]::Exists($manifest)) { throw 'Choose the dated backup folder containing manifest.json, not its parent or recovery folder.' }
    return $manifest
}

function Get-PitrUiMappingSuggestions {
    [CmdletBinding()]
    param($Manifest,[AllowEmptyCollection()][object[]]$Profiles=@())
    foreach($source in $Manifest.Sources) {
        $target=''
        if($source.Category -eq 'Profile' -and -not [string]::IsNullOrWhiteSpace([string]$source.ProfileSid)) {
            $matches=@($Profiles | Where-Object { $_.Sid -eq $source.ProfileSid })
            if($matches.Count -eq 1 -and -not $matches[0].Inaccessible -and [IO.Directory]::Exists([string]$matches[0].Path)) {
                $target=[string]$matches[0].Path
            }
        }
        [pscustomobject]@{SourceId=[string]$source.Id;OriginalPath=[string]$source.Path;TargetRoot=$target}
    }
}

function Get-PitrUiReportDetails {
    [CmdletBinding()]
    param($Report,[string]$Status)
    $lines=New-Object 'Collections.Generic.List[string]'
    $lines.Add($Status)
    if($null -eq $Report) { return $Status }
    foreach($field in @('ManifestPath','State','ScanComplete','Complete','DryRun','Summary','Counts','Warnings')) {
        $property=$Report.PSObject.Properties[$field]
        if($null -ne $property) { $lines.Add($field+': '+($property.Value | ConvertTo-Json -Depth 4 -Compress)) }
    }
    $actions=$Report.PSObject.Properties['Actions']; $entries=$Report.PSObject.Properties['Entries']
    $rows=@()
    if($null -ne $actions) { $rows=@($actions.Value) }
    elseif($null -ne $entries) { $rows=@($entries.Value | Where-Object {
        ($null -ne $_.PSObject.Properties['Error'] -and $_.Error) -or
        ($null -ne $_.PSObject.Properties['CopyStatus'] -and $_.CopyStatus -ne 'Copied') -or
        ($null -ne $_.PSObject.Properties['Classification'] -and $_.Classification -eq 'Unknown')
    }) }
    $problems=@($rows | Where-Object {
        ($null -ne $_.PSObject.Properties['Error'] -and $_.Error) -or
        ($null -ne $_.PSObject.Properties['Result'] -and $_.Result -eq 'Failed')
    })
    if($problems.Count -gt 0) { $lines.Add('Problems (all):') }
    foreach($problem in $problems) { $lines.Add(($problem | ConvertTo-Json -Depth 3 -Compress)) }
    $routine=@($rows | Where-Object {
        -not (($null -ne $_.PSObject.Properties['Error'] -and $_.Error) -or
        ($null -ne $_.PSObject.Properties['Result'] -and $_.Result -eq 'Failed'))
    })
    $limit=[Math]::Min(200,$routine.Count)
    for($i=0;$i -lt $limit;$i++) { $lines.Add(($routine[$i] | ConvertTo-Json -Depth 3 -Compress)) }
    if($routine.Count -gt $limit) { $lines.Add('Showing first 200 routine rows; all problem rows are above. Save the full report for every row.') }
    return ($lines -join [Environment]::NewLine)
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
    $view=@{Job=$null;Shared=$null;Kind='';Report=$null;Rows=@();Mappings=@();SelectedIds=@{};Filtering=$false;Generation=0;PreviewContext=$null;PendingPreviewContext=$null;PendingPrepare=([bool]$ManifestPath);PublishingBackup=$false}
    $buttons=@('StartBackup','VerifyBackup','LoadMappings','CompareBackup','FindMissing','ChooseBackup','PreviewRecovery','RecoverFiles','BrowseManifest','ExportReport')
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
    $prepare={
        if([string]::IsNullOrWhiteSpace($controls.ManifestPath.Text)) { $controls.Status.Text='Choose a backup folder first.'; return }
        $controls.MappingsApproved.IsChecked=$false
        $view.PreviewContext=$null
        & $start 'Prepare' {
            param($state,$a)
            $progress={param($p) $state.Progress=$p}.GetNewClosure()
            $verified=Test-PitrBackup -ManifestPath $a.Path -Mode Full -Cancellation $state -Progress $progress
            $profiles=@(); $discoveryWarning=''
            if(-not $state.Cancelled) {
                try { $profiles=@(Get-PitrProfiles) } catch { $discoveryWarning='Account discovery unavailable. Enter and approve current folders manually.' }
            }
            $rows=@(Get-PitrUiMappingSuggestions -Manifest $verified -Profiles $profiles)
            $state.Result=[pscustomobject]@{Verification=$verified;Mappings=$rows;DiscoveryWarning=$discoveryWarning}
        } @{Path=$controls.ManifestPath.Text}
    }
    $controls.ChooseBackup.Add_Click({
        $dialog=New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description='Choose the dated backup folder, not the drive or recovery subfolder.'
        try {
            if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                $controls.ManifestPath.Text=Resolve-PitrUiBackupFolder -Path $dialog.SelectedPath
                & $prepare
            }
        } catch { $controls.Status.Text=$_.Exception.Message } finally { $dialog.Dispose() }
    })
    $controls.ShowDetails.Add_Click({
        $controls.DetailsText.Text=Get-PitrUiReportDetails -Report $view.Report -Status $controls.Status.Text
        $controls.DetailsPanel.IsExpanded=$true
    })
    $controls.BrowseDestination.Add_Click({
        $dialog=New-Object Windows.Forms.FolderBrowserDialog
        try { if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $controls.Destination.Text=$dialog.SelectedPath } } finally { $dialog.Dispose() }
    })
    $controls.ManifestPath.Add_TextChanged({
        if(-not $view.PublishingBackup) {
            $view.Generation++
            if($view.Shared) { $view.Shared.Cancelled=$true }
        }
        $view.Rows=@(); $view.Mappings=@(); $view.Report=$null; $view.SelectedIds=@{}; $view.PreviewContext=$null; $view.PendingPreviewContext=$null
        if($controls.ContainsKey('MappingsApproved')) { $controls.MappingsApproved.IsChecked=$false }
        if($controls.ContainsKey('BackupLocation')) { $controls.BackupLocation.Text=$controls.ManifestPath.Text }
        if($controls.ContainsKey('RestoreSummary')) { $controls.RestoreSummary.Text='Open the backup, then review its destination folders.' }
        $controls.Results.SelectedItems.Clear()
        $controls.Results.ItemsSource=@()
        $controls.Mappings.ItemsSource=@()
        $controls.Status.Text='Manifest changed. Load mappings and compare again before recovery.'
    })
    $controls.BrowseManifest.Add_Click({
        $dialog=New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter='Backup manifest|manifest.json|JSON|*.json'
        if($dialog.ShowDialog()) { $controls.ManifestPath.Text=$dialog.FileName; & $prepare }
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
    $controls.LoadMappings.Add_Click({ & $prepare })
    $compare={
        if(-not $controls.MappingsApproved.IsChecked) { $controls.Status.Text='Review the destination folders and tick the approval box first.'; return }
        $map=& $getMappings
        if($view.Mappings.Count -eq 0 -or $map.Count -ne $view.Mappings.Count) { $controls.Status.Text='Enter a current folder for every backed-up folder before continuing.'; return }
        $view.PreviewContext=$null
        & $start 'Compare' {param($state,$a) $progress={param($p) $state.Progress=$p}.GetNewClosure(); $state.Result=Compare-PitrBackup -ManifestPath $a.Path -Mappings $a.Map -Deep -Cancellation $state -Progress $progress} @{Path=$controls.ManifestPath.Text;Map=$map}
    }
    $controls.FindMissing.Add_Click({ & $compare })
    $controls.CompareBackup.Add_Click({ & $compare })
    $recover={param([bool]$execute)
        $ids=@($view.SelectedIds.Keys)
        if($ids.Count -eq 0) { $controls.Status.Text='Select files explicitly after comparison.'; return }
        $policy=[string]$controls.ConflictPolicy.SelectedItem.Content
        if($policy -notin @('Skip','Alongside','Replace')) { $policy='Skip' }
        $map=& $getMappings
        $context=([ordered]@{Manifest=$controls.ManifestPath.Text;Mappings=@($map.Keys | Sort-Object | ForEach-Object { [ordered]@{Id=$_;Root=$map[$_]} });Ids=@($ids | Sort-Object);Conflict=$policy;Alternate=$controls.AlternateRoot.Text;Advanced=[bool]$controls.AllowAdvanced.IsChecked} | ConvertTo-Json -Depth 6 -Compress)
        if($execute -and ([string]::IsNullOrWhiteSpace([string]$view.PreviewContext) -or $view.PreviewContext -cne $context)) { $controls.Status.Text='Preview this selection and these destinations first. Preview again after any change.'; return }
        if(-not $execute) { $view.PreviewContext=$null; $view.PendingPreviewContext=$context }
        if($execute) {
            $message='Restore '+$ids.Count+' selected file(s)? Existing files: '+$policy+'.'
            if($policy -eq 'Replace') { $message+=' Replace preserves the current file in a unique conflict store before writing the backup copy.' }
            $message+=' AppData requires explicit approval. Review the preview first.'
            if([Windows.MessageBox]::Show($message,'Confirm recovery',[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning,[Windows.MessageBoxResult]::No) -ne [Windows.MessageBoxResult]::Yes) { return }
        }
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
                'Prepare' {
                    $view.Report=$result.Verification; $view.Mappings=@($result.Mappings); $controls.Mappings.ItemsSource=$view.Mappings
                    $controls.MappingsApproved.IsChecked=$false
                    $controls.RestoreSummary.Text='Review the destination folders, tick approval, then find missing files. '+$result.DiscoveryWarning
                    if($view.Shared.Cancelled) { $controls.Status.Text='Backup check cancelled. Do not assume this backup is verified.' }
                    elseif($result.Verification.State -eq 'Verified') { $controls.Status.Text='Backup verified. Review the restore folders below.' }
                    else { $controls.Status.Text='Backup has problems. View details before attempting to recover any readable files.' }
                }
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
                    if($result.ScanComplete -and -not $view.Shared.Cancelled) {
                        $controls.Status.Text='Scan finished. '+$view.SelectedIds.Count+' missing personal file(s) selected. Existing files will be kept.'
                    } else {
                        $view.SelectedIds=@{}; & $filterRows
                        $controls.Status.Text='Scan incomplete or cancelled. View details and resolve problems before restoring.'
                    }
                    if($controls.ContainsKey('RestoreSummary')) { $controls.RestoreSummary.Text=$controls.Status.Text }
                }
                'Backup' {
                    $view.PublishingBackup=$true
                    try { $controls.ManifestPath.Text=$result.ManifestPath } finally { $view.PublishingBackup=$false }
                    $view.Report=$result
                    if($view.Shared.Cancelled -or $result.State -in @('Interrupted','Verifying')) { $controls.Status.Text='Backup cancelled or interrupted. Do not assume all files are protected.' }
                    elseif($result.State -eq 'Verified') { $controls.Status.Text='Backup verified. Keep the backup folder and recovery launcher together. PITR readiness is not assessed.' }
                    else { $controls.Status.Text='Backup finished with problems. View details; some files may not be protected.' }
                }
                'Verify' { $view.Report=$result; $controls.Status.Text='Backup check: '+$result.State+'. View details for warnings. This does not prove application consistency or PITR readiness.' }
                'Recovery' {
                    $view.Report=$result
                    if($result.DryRun -and $result.Complete -and -not $view.Shared.Cancelled) {
                        $view.PreviewContext=$view.PendingPreviewContext
                        $controls.Status.Text='Preview ready. No files were written. View details, then restore the selected files.'
                    } elseif($result.DryRun) {
                        $view.PreviewContext=$null
                        $controls.Status.Text='Preview has problems or was cancelled. No files were written. View details.'
                    } else {
                        $view.PreviewContext=$null
                        if($result.Complete) { $controls.Status.Text='Restore finished. View details for restored and skipped files.' }
                        else { $controls.Status.Text='Restore finished with problems or was cancelled. View details.' }
                    }
                }
                'Export' { $controls.Status.Text=[string]$result }
            }
        } catch { if($view.Job.Generation -eq $view.Generation) { $controls.Status.Text='Operation failed: '+$_.Exception.Message } }
        finally {
            $view.Job.PowerShell.Dispose(); $view.Job.Runspace.Dispose(); $view.Job=$null
            foreach($name in $buttons) { $controls[$name].IsEnabled=$true }
            $controls.CancelWork.IsEnabled=$false
        }
        if($view.PendingPrepare) { $view.PendingPrepare=$false; & $prepare }
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
            foreach($module in @('Platform','Manifest','Backup','Recovery','Ui')) {
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
