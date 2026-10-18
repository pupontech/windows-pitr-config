$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$ui=Join-Path $root 'src/backup/Ui.ps1'
if(-not (Test-Path -LiteralPath $ui)) { throw 'RED: asynchronous UI worker is missing' }
. $ui
$state=[hashtable]::Synchronized(@{Cancelled=$false;Result=$null;Error=$null})
$job=Start-PitrUiWorker -ApplicationRoot $root -Operation { param($state,$argsObject) $state.Result=$argsObject.Value; return 'worker-finished' } -Arguments @{Value=42} -State $state
try {
    if(-not $job.Handle.AsyncWaitHandle.WaitOne(30000)) { throw 'Worker timed out' }
    $output=$job.PowerShell.EndInvoke($job.Handle)
    if($state.Result -ne 42 -or $output[-1] -ne 'worker-finished') { throw 'Worker did not execute real operation with shared state' }
} finally { $job.PowerShell.Dispose(); $job.Runspace.Dispose() }
Write-Output 'UI worker real runspace assertions passed.'
[xml]$xaml=Get-PitrBackupXaml
$ns=New-Object Xml.XmlNamespaceManager($xaml.NameTable)
$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
foreach($name in @('Profiles','Scope','CustomPaths','Destination','ManifestPath','Mappings','Results','StartBackup','VerifyBackup','CompareBackup','RecoverFiles','CancelWork','Status','Search')) {
    if(-not $xaml.SelectSingleNode('//*[@x:Name="'+$name+'"]',$ns)) { throw ('Missing UI control: '+$name) }
}
if(-not (Get-Command Show-PitrBackupUi -ErrorAction SilentlyContinue)) { throw 'Public UI entrypoint missing' }
Write-Output 'UI XAML contract assertions passed; Windows rendering pending.'
. (Join-Path $root 'src/backup/Localization.ps1')
foreach($language in @('en','de','nl','fr','es','pt','it','pl','uk','cs')) {
    $labels=Get-PitrBackupLabels -Language $language
    foreach($key in @('StartBackup','VerifyBackup','CompareBackup','RecoverFiles','CancelWork','PreviewRecovery','LoadMappings','ExportReport')) {
        if([string]::IsNullOrWhiteSpace($labels[$key])) { throw ('Missing localized label: '+$language+'/'+$key) }
    }
}
if((Get-PitrBackupLabels -Language unknown).StartBackup -ne (Get-PitrBackupLabels -Language en).StartBackup) { throw 'Unknown locale must fall back to English' }
Write-Output 'Ten locale primary action labels passed; narrative/status translation coverage not complete.'
if($env:OS -eq 'Windows_NT') {
    $renderState=[hashtable]::Synchronized(@{Cancelled=$false;Result=$null;Error=$null})
    $render=Start-PitrUiWorker -ApplicationRoot $root -State $renderState -Arguments @{Root=$root} -Operation {
        param($shared,$a)
        . (Join-Path $a.Root 'src/backup/Ui.ps1')
        Add-Type -AssemblyName PresentationFramework
        [xml]$document=Get-PitrBackupXaml
        $reader=New-Object Xml.XmlNodeReader($document)
        try { $window=[Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
        $window.Add_ContentRendered({$this.Close()})
        $null=$window.ShowDialog()
        $shared.Result='RenderedAndClosed'
    }
    try {
        if(-not $render.Handle.AsyncWaitHandle.WaitOne(60000)) { throw 'Windows WPF smoke timed out' }
        $null=$render.PowerShell.EndInvoke($render.Handle)
        if($renderState.Result -ne 'RenderedAndClosed') { throw ('Windows WPF failed: '+$renderState.Error) }
    } finally { $render.PowerShell.Dispose(); $render.Runspace.Dispose() }
    Write-Output 'Windows WPF XAML rendered and closed on a real STA dispatcher.'
} else { Write-Output 'SKIP: Windows WPF rendering needs the Windows CI runner.' }
