$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Output 'SKIP: unified single-window navigation/state proof requires Windows WPF.'; return }
$root=Split-Path $PSScriptRoot -Parent
$proof=Join-Path $env:RUNNER_TEMP 'pitr-ui-proof';$null=[IO.Directory]::CreateDirectory($proof)
$shared=[hashtable]::Synchronized(@{Done=$false;Error=$null;Stage='initial';CloseCancelled=$false})
$rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.Open()
$ps=[powershell]::Create();$ps.Runspace=$rs
try {
    $operation={param($root,$proof,$shared)
        $ErrorActionPreference='Stop'
        $env:PITR_SELF=Join-Path $root 'pitr-config.cmd'
        $env:PITR_NOUPDATE='1'
        $unifiedAutomation=@'
    function Save-UnifiedCapture([string]$name) {
        $window.UpdateLayout()
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Create((Join-Path $proof $name));try{$encoder.Save($stream)}finally{$stream.Dispose()}
    }
    $proofState=@{Stage=0;Failed=$false;Clock=[Diagnostics.Stopwatch]::StartNew()}
    $proofTimer=New-Object Windows.Threading.DispatcherTimer
    $proofTimer.Interval=[timespan]::FromMilliseconds(150)
    $proofTimer.Add_Tick({
        try {
            $shared.Stage=[string]$proofState.Stage
            if($proofState.Clock.Elapsed.TotalSeconds -gt 75) { throw ('Unified navigation timeout: '+$controls.Status.Text) }
            if($proofState.Failed) {
                if($view.Job) { $view.Shared.Cancelled=$true;return }
                $proofTimer.Stop();$window.Close();return
            }
            if($view.Job) { return }
            switch($proofState.Stage) {
                0 {
                    if(-not [object]::ReferenceEquals($window,$HostWindow) -or -not $window.IsVisible) { throw 'Composition opened a different host window.' }
                    $tabs=$controls.Tabs
                    if($tabs.Items.Count -ne 3 -or [string]$tabs.Items[0].Header -cne 'Backup' -or [string]$tabs.Items[1].Header -cne 'Restore files' -or [string]$tabs.Items[2].Header -cne 'Restore points') { throw 'Exactly three distinct workflow tabs are required.' }
                    if($controls.Status.Text -notlike 'All discovered profiles selected.*') { throw ('Initial file discovery failed: '+$controls.Status.Text) }
                    $controls.Destination.Text=Join-Path $proof 'unused-backup-destination'
                    $controls.ManifestPath.Text=Join-Path $proof 'not-opened-manifest.json'
                    $proofState.Destination=$controls.Destination.Text;$proofState.Manifest=$controls.ManifestPath.Text
                    foreach($index in @(0,1,2)) {
                        $tabs.SelectedIndex=$index;$window.UpdateLayout()
                        if(-not [object]::ReferenceEquals([Windows.Window]::GetWindow($tabs.Items[$index].Content),$window)) { throw 'Tab content belongs to another window.' }
                        if($index -eq 0) { $controls.StartBackup.BringIntoView() }
                        if($index -eq 1) { $controls.RecoverFiles.BringIntoView() }
                        if($index -eq 2) { $ctl.BtnRefresh.BringIntoView() }
                        Save-UnifiedCapture ('unified-tab'+$index+'.png')
                    }
                    if(-not [object]::ReferenceEquals([Windows.Window]::GetWindow($ctl.BtnRefresh),$window)) { throw 'Original PITR controls lost their host.' }
                    # The original Refresh handler is read-only. No Apply, snapshot,
                    # task change, recovery/reboot, or language mutation is invoked.
                    $ctl.BtnRefresh.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    $ctl.BtnBackupBefore.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    if($tabs.SelectedIndex -ne 0) { throw 'Backup shortcut opened another window or did not navigate.' }
                    $tabs.SelectedIndex=2
                    $ctl.BtnBackupRecover.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    if($tabs.SelectedIndex -ne 1) { throw 'Restore shortcut did not navigate within the existing window.' }
                    if($controls.Destination.Text -cne $proofState.Destination -or $controls.ManifestPath.Text -cne $proofState.Manifest) { throw 'Tab navigation discarded entered state.' }
                    if($controls.MappingsApproved.IsChecked -or $view.PreviewContext -or $controls.ConflictPolicy.SelectedIndex -ne 0) { throw 'Tab navigation granted recovery consent or changed safe defaults.' }
                    $proofState.Stage=1
                    & $start 'NavigationProof' {param($state,$a) while(-not $state.Cancelled) {Start-Sleep -Milliseconds 50};$state.Result='cancelled-no-files-written'} @{}
                    if($restorePointsTab.IsEnabled -or (Select-PitrUnifiedTab -Window $window -Mode RestorePoints)) { throw 'Restore-points actions remain accessible during file work.' }
                    $window.Close()
                    if(-not $window.IsVisible -or -not $view.Shared.Cancelled) { throw 'Closing during file work did not wait for safe cancellation.' }
                    $shared.CloseCancelled=$true
                }
                1 {
                    if(-not $restorePointsTab.IsEnabled -or -not $shared.CloseCancelled) { throw 'Cancelled file work did not restore tab access.' }
                    if($controls.Destination.Text -cne $proofState.Destination -or $controls.ManifestPath.Text -cne $proofState.Manifest) { throw 'Cancellation discarded selected paths.' }
                    if($ctl.TxtLog.Text -match 'Error:') { throw ('Original PITR handler failed after composition: '+$ctl.TxtLog.Text) }
                    $shared.Done=$true;$proofTimer.Stop();$window.Close()
                }
            }
        } catch {
            $shared.Error=$_.Exception.ToString();$proofState.Failed=$true
            if($view.Job) { $view.Shared.Cancelled=$true } else { $proofTimer.Stop();$window.Close() }
        }
    })
    $proofTimer.Start()
'@
        # Insert only an observer timer at the composed function boundary. Keep
        # the actual original handlers, UI, runspace worker and close policy.
        $text=[IO.File]::ReadAllText($env:PITR_SELF,[Text.Encoding]::UTF8).Replace("`r`n","`n")
        $marker='#___PSCODE___';$text=$text.Substring($text.LastIndexOf($marker)+$marker.Length)
        $needle='    Show-PitrBackupUi -HostWindow'
        if(-not $text.Contains($needle)) { throw 'RED: production unified handoff is missing.' }
        $injection=@'
    $functionText=${function:Show-PitrBackupUi}.ToString()
    if(-not $functionText.Contains('    $timer.Start()')) { throw 'Observer seam missing.' }
    $functionText=$functionText.Replace('    $timer.Start()',($unifiedAutomation+"`n    `$timer.Start()"))
    Set-Item Function:\Show-PitrBackupUi ([scriptblock]::Create($functionText))
'@
        $text=$text.Replace($needle,($injection+"`n"+$needle))
        # Native CMD proof separately observes the real informational dialog;
        # suppress only that modal here, never a recovery confirmation handler.
        $text=$text.Replace("Show-PitrApplicationWarning`nif(`$Unified)","if(`$Unified)")
        & ([scriptblock]::Create($text)) -Unified
    }
    $null=$ps.AddScript($operation.ToString()).AddArgument($root).AddArgument($proof).AddArgument($shared)
    $async=$ps.BeginInvoke()
    if(-not $async.AsyncWaitHandle.WaitOne(120000)) { $ps.Stop();throw ('Unified proof exceeded 120s at '+$shared.Stage+'; '+$shared.Error) }
    $null=$ps.EndInvoke($async)
    if(-not $shared.Done -or $shared.Error) { throw ('Unified proof failed at '+$shared.Stage+': '+$shared.Error) }
    Write-Output 'PASS: real original host + three tabs, retained paths, original read-only Refresh/shortcuts, no implicit restore consent, file-job exclusion and safe close cancellation. Screenshots saved.'
} finally { $ps.Dispose();$rs.Dispose() }
