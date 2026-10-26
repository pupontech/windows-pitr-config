$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Write-Output 'SKIP: responsive WPF geometry/render proof requires Windows.'; return }
$root=Split-Path $PSScriptRoot -Parent
$rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.Open()
$ps=[powershell]::Create();$ps.Runspace=$rs
try {
    $operation={param($root)
        $ErrorActionPreference='Stop'
        . (Join-Path $root 'src/backup/Ui.ps1')
        Add-Type -AssemblyName PresentationFramework
        function Assert($ok,[string]$why) { if(-not $ok) { throw $why } }
        function Visuals($parent) {
            $stack=New-Object 'Collections.Generic.Stack[Windows.DependencyObject]'
            $stack.Push($parent)
            while($stack.Count -gt 0) {
                $node=$stack.Pop()
                Write-Output -NoEnumerate $node
                for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node);$i++) { $stack.Push([Windows.Media.VisualTreeHelper]::GetChild($node,$i)) }
            }
        }
        function Reach($window,$scroll,$target,[string]$tag) {
            Assert ($null -ne $target) ('Missing target '+$tag)
            $target.BringIntoView();$window.UpdateLayout()
            $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
            $window.UpdateLayout()
            $p=$target.TranslatePoint([Windows.Point]::new(0,0),$window)
            Assert ($target.ActualWidth -gt 0 -and $target.ActualHeight -gt 0) ('Target not laid out: '+$tag)
            Assert ($p.X -ge -1 -and $p.Y -ge -1 -and $p.X+$target.ActualWidth -le $window.ActualWidth+1 -and $p.Y+$target.ActualHeight -le $window.ActualHeight+1) ('Target outside window: '+$tag+' '+$p+' '+$target.ActualWidth+'x'+$target.ActualHeight)
            if($null -ne $scroll) {
                $s=$target.TranslatePoint([Windows.Point]::new(0,0),$scroll)
                Assert ($s.Y -ge -1 -and $s.Y+$target.ActualHeight -le $scroll.ActualHeight+1) ('Target clipped by scroll viewport: '+$tag+' y='+$s.Y+' h='+$target.ActualHeight+' viewport='+$scroll.ActualHeight)
            }
        }
        function Screenshot($window,[string]$path,[double]$scale) {
            $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($window.ActualWidth*$scale),[int][Math]::Ceiling($window.ActualHeight*$scale),96*$scale,96*$scale,[Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $stream=[IO.File]::Create($path);try{$encoder.Save($stream)}finally{$stream.Dispose()}
        }
        $cmd=[IO.File]::ReadAllText((Join-Path $root 'pitr-config.cmd'))
        $mainXaml=[regex]::Match($cmd,'(?ms)^\$xaml = @''\r?\n(?<xaml>.*?)^''@').Groups['xaml'].Value
        Assert (-not [string]::IsNullOrWhiteSpace($mainXaml)) 'Standalone main XAML could not be extracted.'
        $proof=Join-Path $env:RUNNER_TEMP 'pitr-ui-proof';$null=[IO.Directory]::CreateDirectory($proof)
        $checks=0
        foreach($scale in @(1.0,1.25,1.5,1.75,2.0,2.5)) {
            foreach($surface in @('Backup','Main')) {
                $xaml=if($surface -eq 'Backup'){Get-PitrBackupXaml}else{$mainXaml}
                [xml]$xml=$xaml;$reader=New-Object Xml.XmlNodeReader($xml)
                try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
                try {
                    $preferredWidth=if($surface -eq 'Backup'){980}else{900}
                    $preferredHeight=if($surface -eq 'Backup'){740}else{800}
                    $b=Get-PitrUiWindowBounds -WorkWidth (1920/$scale) -WorkHeight (1040/$scale) -PreferredWidth $preferredWidth -PreferredHeight $preferredHeight
                    $window.MinWidth=$b.MinWidth;$window.MinHeight=$b.MinHeight;$window.MaxWidth=$b.MaxWidth;$window.MaxHeight=$b.MaxHeight;$window.Width=$b.Width;$window.Height=$b.Height
                    if($surface -eq 'Main') {
                        # Apply real English translation assignments, without invoking
                        # startup collectors, registry/task writes or any click handler.
                        $table=[regex]::Match($cmd,'(?ms)^en = (?<table>@\{.*?)^\}').Groups['table'].Value+'}'
                        $labels=& ([scriptblock]::Create($table))
                        foreach($m in [regex]::Matches($cmd,'\$ctl\.(\w+)\.(Content|Text|Header)\s*=\s*T ''([^'']+)''')) {
                            $control=$window.FindName($m.Groups[1].Value)
                            if($null -ne $control -and $labels.ContainsKey($m.Groups[3].Value)) { $control.($m.Groups[2].Value)=$labels[$m.Groups[3].Value] }
                        }
                        $window.FindName('TxtLog').Text='Responsive layout proof: no system changes.'
                    }
                    $window.Show();$window.UpdateLayout()
                    $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
                    Assert ($window.ActualWidth -le 1920/$scale+1 -and $window.ActualHeight -le 1040/$scale+1) ('Actual startup bounds exceed 1080p logical work area: '+$surface+' scale='+$scale)
                    foreach($compact in @($false,$true)) {
                        if($compact) { $window.Width=$b.MinWidth;$window.Height=$b.MinHeight;$window.UpdateLayout() }
                        if($surface -eq 'Backup') {
                            $scroll=$window.FindName('MainScroll')
                            foreach($tab in @(0,1)) {
                                $window.FindName('Tabs').SelectedIndex=$tab;$window.UpdateLayout()
                                # Exercise expanded folders, advanced options and details;
                                # they must scroll, never squeeze the tab viewport to zero.
                                foreach($expander in @(Visuals $window | Where-Object { $_ -is [Windows.Controls.Expander] })) { $expander.IsExpanded=$true }
                                $window.UpdateLayout()
                                Assert ($scroll.ViewportHeight -gt 40) 'Expanded details consumed the whole content viewport.'
                                foreach($name in $(if($tab -eq 0){@('ApplicationWarning','StartBackup','ExportReport')}else{@('ChooseBackup','MappingsApproved','FindMissing','PreviewRecovery','RecoverFiles','ExportReport')})) {
                                    Reach $window $scroll ($window.FindName($name)) ($surface+'/'+$scale+'/'+$compact+'/'+$name);$checks++
                                }
                                foreach($name in @('CancelWork','ShowDetails')) { Reach $window $null ($window.FindName($name)) ('footer/'+$name);$checks++ }
                                if(-not $compact -and $scale -in @(1.0,1.5,2.0)) {
                                    Reach $window $scroll ($window.FindName($(if($tab -eq 0){'StartBackup'}else{'RecoverFiles'}))) 'capture'
                                    Screenshot $window (Join-Path $proof ('responsive-'+$surface+'-tab'+$tab+'-'+[int]($scale*100)+'.png')) $scale
                                }
                            }
                        } else {
                            $scroll=$window.Content
                            foreach($name in @('BtnSnapNow','BtnReset','BtnRefresh','BtnApply','BtnApplyNow','BtnBackupBefore','BtnBackupRecover','BtnCopy')) {
                                Reach $window $scroll ($window.FindName($name)) ($surface+'/'+$scale+'/'+$compact+'/'+$name);$checks++
                            }
                            if(-not $compact -and $scale -in @(1.0,1.5,2.0)) {
                                Reach $window $scroll ($window.FindName('BtnApplyNow')) 'capture'
                                Screenshot $window (Join-Path $proof ('responsive-Main-'+[int]($scale*100)+'.png')) $scale
                            }
                        }
                    }
                } finally { $window.Close() }
            }
        }
        'Responsive Windows geometry passed: '+$checks+' target reachability checks across 1080p-equivalent logical work areas at 100/125/150/175/200/250%, both main and backup/restore, startup and compact resize, all advanced/details expanded. Layout-equivalent simulation, NOT proof of native monitor-DPI switching.'
    }
    $null=$ps.AddScript($operation.ToString()).AddArgument($root)
    $async=$ps.BeginInvoke()
    if(-not $async.AsyncWaitHandle.WaitOne(180000)) { $ps.Stop();throw 'Responsive Windows proof exceeded 180s.' }
    $output=$ps.EndInvoke($async)
    if($ps.HadErrors) { throw ($ps.Streams.Error | Out-String) }
    $output | Write-Output
} finally { $ps.Dispose();$rs.Dispose() }
