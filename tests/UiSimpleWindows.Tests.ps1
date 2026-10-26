$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Output 'SKIP: interactive simple workflow requires Windows WPF and separate runner storage.'; return }
if(-not $env:RUNNER_TEMP) { throw 'Simple workflow proof requires RUNNER_TEMP on separate media.' }
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Ui.ps1')
$source=Join-Path ([IO.Path]::GetTempPath()) ('pitr-ui-source-'+[guid]::NewGuid().ToString('N'))
$media=Join-Path $env:RUNNER_TEMP ('pitr-ui-media-'+[guid]::NewGuid().ToString('N'))
$profile=Join-Path $source 'Alice';$public=Join-Path $source 'Public'
foreach($p in @((Join-Path $profile 'Documents'),(Join-Path $profile 'AppData'),$public,$media)) { $null=[IO.Directory]::CreateDirectory($p) }
$missing=Join-Path $profile 'Documents/missing.txt';$changed=Join-Path $profile 'Documents/current.txt'
[IO.File]::WriteAllText($missing,'backed-up missing document')
[IO.File]::WriteAllText($changed,'old document')
[IO.File]::WriteAllText((Join-Path $profile 'AppData/settings.ini'),'old settings')
[IO.File]::WriteAllText((Join-Path $profile 'launch.ps1'),'do not auto-restore scripts')
[IO.File]::WriteAllText((Join-Path $public 'shared.txt'),'shared file')
$fixture=Join-Path $source 'profiles.csv'
@([pscustomobject]@{Sid='S-1-5-21-111-222-333-1001';Path=$profile},[pscustomobject]@{Sid='S-1-5-32-545';Path=$public}) | Export-Csv -LiteralPath $fixture -NoTypeInformation
$previous=$env:PITR_PROFILELIST_FIXTURE_PATH
$env:PITR_PROFILELIST_FIXTURE_PATH=$fixture
$proof=Join-Path $env:RUNNER_TEMP 'pitr-ui-proof';$null=[IO.Directory]::CreateDirectory($proof)
$state=[hashtable]::Synchronized(@{Done=$false;Error=$null;Confirmed=$false;Stage='not started';Status=''})
$rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.Open()
$ps=[powershell]::Create();$ps.Runspace=$rs
try {
    $operation={param($root,$media,$profile,$missing,$changed,$proof,$shared)
        $ErrorActionPreference='Stop'
        foreach($m in @('Platform','Manifest','Backup','Recovery','Ui')) { . (Join-Path $root ('src/backup/'+$m+'.ps1')) }
        Add-Type -AssemblyName PresentationFramework
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PitrSimpleDialogProbe {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr window,int id);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window,uint msg,IntPtr w,IntPtr l);
}
'@
        # Inject ONLY an automation timer before ShowDialog. All product handlers,
        # real workers, engines and the native final confirmation remain unchanged.
        $automation=@'
        $proofState=@{Stage=0;Started=[Diagnostics.Stopwatch]::StartNew()}
        $proofTimer=New-Object Windows.Threading.DispatcherTimer
        $proofTimer.Interval=[timespan]::FromMilliseconds(150)
        $proofTimer.Add_Tick({
            try {
                $shared.Stage=[string]$proofState.Stage; $shared.Status=$controls.Status.Text
                if($proofState.Started.Elapsed.TotalSeconds -gt 90) { throw ('Simple UI timed out at stage '+$proofState.Stage+'; '+$controls.Status.Text) }
                if($view.Job) { return }
                switch($proofState.Stage) {
                    0 {
                        if($controls.Profiles.SelectedItems.Count -ne 2) { throw 'Default GUI did not select both fixture profiles.' }
                        $controls.Destination.Text=$media
                        $proofState.Stage=1
                        $controls.StartBackup.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    }
                    1 {
                        if($view.Report.State -ne 'Verified') { throw ('Real GUI backup failed: '+$controls.Status.Text) }
                        if($controls.BackupFolders.IsExpanded) { throw 'User list is not initially collapsed.' }
                        $button=$controls.StartBackup.TranslatePoint([Windows.Point]::new(0,0),$window)
                        if($button.Y -lt 0 -or $button.Y+$controls.StartBackup.ActualHeight -gt $window.ActualHeight) { throw 'Primary backup action is below the default viewport.' }
                        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
                        $bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                        $stream=[IO.File]::Create((Join-Path $proof 'simple-backup.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
                        [IO.File]::Delete($missing);[IO.File]::Delete((Join-Path $profile 'AppData/settings.ini'));[IO.File]::Delete((Join-Path $profile 'launch.ps1'))
                        [IO.File]::WriteAllText($changed,'newer document must survive')
                        $controls.Tabs.SelectedIndex=1
                        $proofState.Stage=2
                        & $prepare
                    }
                    2 {
                        if($view.Mappings.Count -ne 2 -or @($view.Mappings | Where-Object { -not $_.TargetRoot }).Count -ne 0) { throw ('Exact-identity suggestions missing: '+$controls.Status.Text) }
                        $controls.MappingsApproved.IsChecked=$true
                        $proofState.Stage=3
                        $controls.FindMissing.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    }
                    3 {
                        if(-not $view.Report.ScanComplete -or $view.SelectedIds.Count -ne 1 -or $controls.Results.Items.Count -ne 1) { throw ('Simple view must show and select only the missing safe document: '+$controls.Status.Text) }
                        $selected=@($view.Rows | Where-Object { $view.SelectedIds.ContainsKey([string]$_.Id) })
                        if($selected.Count -ne 1 -or $selected[0].RelativePath -notmatch 'missing.txt$') { throw 'Wrong automatic file selection.' }
                        $proofState.Stage=4
                        $controls.PreviewRecovery.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    }
                    4 {
                        if(-not $view.Report.DryRun -or -not $view.Report.Complete -or -not $view.PreviewContext -or [IO.File]::Exists($missing)) { throw ('Preview wrote files or failed: '+$controls.Status.Text) }
                        $controls.RecoverFiles.BringIntoView();$window.UpdateLayout()
                        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
                        $bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                        $stream=[IO.File]::Create((Join-Path $proof 'simple-restore.png'));try{$encoder.Save($stream)}finally{$stream.Dispose()}
                        $proofState.Stage=6
                        $controls.RecoverFiles.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    }
                    6 {
                        if($view.Report.DryRun -or -not $view.Report.Complete) { throw ('Confirmed restore failed: '+$controls.Status.Text) }
                        if([IO.File]::ReadAllText($missing) -ne 'backed-up missing document') { throw 'Missing file was not restored by the real UI/engine.' }
                        if([IO.File]::ReadAllText($changed) -ne 'newer document must survive') { throw 'Existing newer file was overwritten.' }
                        if([IO.File]::Exists((Join-Path $profile 'launch.ps1')) -or [IO.File]::Exists((Join-Path $profile 'AppData/settings.ini'))) { throw 'Sensitive or advanced file restored without selection.' }
                        $shared.Done=$true;$proofTimer.Stop();$window.Close()
                    }
                }
            } catch {
                $shared.Error=$_.Exception.ToString();$proofTimer.Stop()
                if($view.Shared) { $view.Shared.Cancelled=$true }
                $window.Close()
            }
        })
        $proofTimer.Start()
'@
        $text=${function:Show-PitrBackupUi}.ToString().Replace('    $timer.Start()',($automation+"`n    `$timer.Start()"))
        Set-Item Function:\Show-PitrBackupUi ([scriptblock]::Create($text))
        Show-PitrBackupUi -ApplicationRoot $root
    }
    $null=$ps.AddScript($operation.ToString()).AddArgument($root).AddArgument($media).AddArgument($profile).AddArgument($missing).AddArgument($changed).AddArgument($proof).AddArgument($state)
    $async=$ps.BeginInvoke()
    # A DispatcherTimer does not re-enter its own Tick while a clicked button
    # holds a modal confirmation. Drive that native dialog from this OUTSIDE
    # thread instead of waiting for the automation timer to click itself.
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not $async.AsyncWaitHandle.WaitOne(100)) {
        if($clock.Elapsed.TotalSeconds -gt 120) { $ps.Stop(); throw ('Simple UI proof exceeded 120s. Stage='+$state.Stage+'; Status='+$state.Status+'; Error='+$state.Error+'; Streams='+($ps.Streams.Error | Out-String)) }
        if(-not $state.Confirmed -and ('PitrSimpleDialogProbe' -as [type])) {
            $dialog=[PitrSimpleDialogProbe]::FindWindow('#32770','Confirm recovery')
            if($dialog -ne [IntPtr]::Zero) {
                $yes=[PitrSimpleDialogProbe]::GetDlgItem($dialog,6)
                if($yes -eq [IntPtr]::Zero) { throw 'Real restore confirmation lacks Yes.' }
                $state.Confirmed=$true
                $null=[PitrSimpleDialogProbe]::SendMessage($yes,245,[IntPtr]::Zero,[IntPtr]::Zero)
            }
        }
    }
    $null=$ps.EndInvoke($async)
    if($ps.HadErrors -or $state.Error -or -not $state.Done -or -not $state.Confirmed) { throw ('Simple UI failed: '+$state.Error+' '+($ps.Streams.Error | Out-String)) }
    Write-Output 'Real simple WPF workflow passed: default all profiles -> backup/full verify -> exact-SID folder review -> find missing -> dry-run -> native Yes confirmation -> real restore. Newer file preserved; AppData/script not auto-restored. Five small synthetic files; no live-user data or PITR.'
} finally {
    $ps.Dispose();$rs.Dispose();$env:PITR_PROFILELIST_FIXTURE_PATH=$previous
    foreach($p in @($source,$media)) { if([IO.Directory]::Exists($p)) { [IO.Directory]::Delete($p,$true) } }
}
