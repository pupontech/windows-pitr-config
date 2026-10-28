$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Ui.ps1')
if(-not (Get-Command Select-PitrUnifiedTab -ErrorAction SilentlyContinue)) { throw 'RED: original workflow shortcuts need same-window tab navigation, not another backup window.' }
$tabs=[pscustomobject]@{SelectedIndex=2}
$window=[pscustomobject]@{Tag=@{PitrTabs=$tabs}}
foreach($case in @(@('Backup',0),@('Recover',1),@('Verify',1),@('RestorePoints',2))) {
    if(-not (Select-PitrUnifiedTab -Window $window -Mode $case[0]) -or $tabs.SelectedIndex -ne $case[1]) { throw ('Wrong in-place tab route: '+$case[0]) }
}
$window.Tag['PitrView']=@{Job=[pscustomobject]@{Running=$true}}
$tabs.SelectedIndex=0
if(Select-PitrUnifiedTab -Window $window -Mode RestorePoints) { throw 'RED: restore-points actions must not be made available while file work is active.' }
if($tabs.SelectedIndex -ne 0) { throw 'Busy restore-points navigation changed the selected step.' }
$window.Tag.PitrView.Job=$null
if(-not (Select-PitrUnifiedTab -Window $window -Mode RestorePoints)) { throw 'Restore-points navigation did not recover after file work ended.' }
$classic=[pscustomobject]@{Tag=$null}
if(Select-PitrUnifiedTab -Window $classic -Mode Backup) { throw 'Standalone legacy host was mistaken for a unified shell.' }
$show=Get-Command Show-PitrBackupUi
foreach($parameter in @('HostWindow','RestorePointsContent')) {
    if(-not $show.Parameters.ContainsKey($parameter)) { throw ('RED: backup UI cannot compose into original host: missing '+$parameter) }
}
$main=[IO.File]::ReadAllText((Join-Path $root 'pitr-config.cmd'),[Text.Encoding]::UTF8)
if($main -notmatch '\[switch\]\$Unified' -or $main -notmatch 'Show-PitrBackupUi -HostWindow \$window -RestorePointsContent') { throw 'RED: original PITR UI does not hand its existing window/content to the three-tab shell.' }
$start=[IO.File]::ReadAllText((Join-Path $root 'START-HERE.cmd'))
if($start -notmatch 'pitr-config\.cmd') { throw 'RED: START-HERE must open the unified main application, not the standalone backup-only UI.' }
Write-Output 'Unified navigation, host composition and main-launch contracts passed; real WPF ownership/state requires Windows proof.'
