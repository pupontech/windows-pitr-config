$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$text=[IO.File]::ReadAllText((Join-Path $root 'pitr-config.cmd'),[Text.Encoding]::UTF8)
foreach($command in @('backup','recover')) {
    $route='if /i "%~1"=="'+$command+'"'
    $index=$text.IndexOf($route,[StringComparison]::OrdinalIgnoreCase)
    if($index -lt 0 -or $index -gt $text.IndexOf('net session')) { throw ('RED: missing pre-UAC '+$command+' CLI route') }
}
if($text -notmatch '(?m)^:backuprecovery\r?$') { throw 'Backup CLI branch missing' }
if($text -notmatch '-File "%PITR_BACKUP_ENTRY%" %\*') { throw 'New CLI must pass native args, not executable PowerShell expressions' }
foreach($name in @('GrpBackup','BtnBackupBefore','BtnBackupVerify','BtnBackupRecover','BtnBackupOpen')) {
    if($text -notmatch ('x:Name="'+$name+'"')) { throw ('Missing compact UI control '+$name) }
}
foreach($locale in @('en','de','nl','fr','es','pt','it','pl','uk','cs')) {
    $match=[regex]::Match($text,'(?ms)^'+$locale+' = @\{(?<table>.*?)^\}')
    if(-not $match.Success) { throw ('Original locale table missing '+$locale) }
    foreach($key in @('backupSection','backupBefore','backupVerify','backupRecover','backupOpen')) {
        if($match.Groups['table'].Value -notmatch ('(?m)^\s*'+$key+'\s*=')) { throw ('New compact UI key missing '+$locale+':'+$key) }
    }
}
foreach($command in @('selftest','apply','snapshot','autostart','idle')) {
    if($text -notmatch ('(?m)^:'+ $command +'\r?$')) { throw ('Original CLI branch removed '+$command) }
}
Write-Output 'Main CLI and localized compact backup section contracts passed.'
