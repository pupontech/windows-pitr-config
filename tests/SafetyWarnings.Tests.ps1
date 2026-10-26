$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$text=[IO.File]::ReadAllText((Join-Path $root 'pitr-config.cmd'))
$marker=[regex]::Match($text,'(?m)^#___PSCODE___\r?$')
$code=$text.Substring($marker.Index+$marker.Length)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
if($errors.Count) { throw $errors[0] }
function Assert($Condition,$Message) { if(-not $Condition) { throw $Message };$script:checks++ }
$script:checks=0
foreach($name in @('Show-PitrApplicationWarning','Confirm-PitrRecoveryHandoff')) {
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Assert ($null -ne $fn) ('RED: missing safety function '+$name)
    . ([scriptblock]::Create($fn.Extent.Text))
}
# Use actual English warning strings and translation function, not test-owned prose.
$lang=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$LangText'},$true)
Assert ($null -ne $lang) 'Language table not found'
. ([scriptblock]::Create($lang.Extent.Text))
$script:Lang='en'
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'T'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$script:dialogs=New-Object Collections.Generic.List[object]
$script:answers=New-Object Collections.Generic.Queue[string]
$script:opened=0;$script:started=0
function Show-PitrSafetyMessage { param($Text,$Title,[switch]$Confirmation)
    $script:dialogs.Add([pscustomobject]@{Text=$Text;Confirmation=[bool]$Confirmation})
    if($Confirmation) { return $script:answers.Dequeue() }
}
function Open-PitrBackupWindow { param($Mode) Assert ($Mode -eq 'Backup') 'Wrong backup mode';$script:opened++ }
function Write-Log { param($Text) }
function Update-Ui { }
function Start-Process { param($FilePath,$ArgumentList,$WindowStyle)
    Assert ($FilePath -eq 'shutdown.exe') 'Unexpected process requested'
    Assert (($ArgumentList -join ' ') -eq '/r /o /t 3') 'Unexpected reboot arguments'
    $script:started++
}
Show-PitrApplicationWarning
Show-PitrApplicationWarning
Assert ($script:dialogs.Count -eq 2) 'Application warning was suppressed on subsequent run'
Assert ($script:dialogs[0].Text -match 'apps' -and $script:dialogs[0].Text -match 'reinstall' -and $script:dialogs[0].Text -match 'Close') 'Application consequences/live backup warning absent'
# Verify every WinRE click executes the real gate before any reboot request.
$click=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$ctl.BtnWinRE' -and $n.Member.Value -eq 'Add_Click'},$true)
Assert ($null -ne $click) 'WinRE click handler not found'
$handler=[scriptblock]::Create($click.Arguments[0].ScriptBlock.Extent.Text.Trim('{','}'))
foreach($answer in @('Cancel','No','Yes')) {
    $script:answers.Enqueue($answer)
    if($answer -eq 'Yes') { $script:answers.Enqueue('No') }
    & $handler
    Assert ($script:started -eq 0) 'Declining warning or restart still rebooted'
}
Assert ($script:opened -eq 1) 'No must offer backup instead of proceeding'
$script:answers.Enqueue('Yes');$script:answers.Enqueue('Yes')
& $handler
Assert ($script:started -eq 1) 'Explicitly acknowledged warnings did not reach inert reboot boundary'
$backupWarnings=@($script:dialogs | Where-Object {$_.Text -match 'No current verified data backup'})
Assert ($backupWarnings.Count -eq 4) 'Backup warning must reappear on every recovery attempt'
Assert ($backupWarnings[0].Text -match 'lose' -and $backupWarnings[0].Text -match 'Backup Before Restore') 'Skipping backup consequences/action not explained'
# Real top-level launch wiring: a dead helper is not a startup warning.
$launch=$ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Show-PitrApplicationWarning'},$true)
Assert (@($launch).Count -ge 1) 'Application warning is not wired to launch'
$show=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$window' -and $n.Member.Value -eq 'ShowDialog'},$true)
Assert ($launch[-1].Extent.StartOffset -lt $show.Extent.StartOffset) 'Launch warning occurs after main window closes'
$wrapper=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-PitrSafetyMessage'},$true)
Assert ($wrapper.Extent.Text -match 'MessageBoxResult\]::No') 'Confirmation must default to No'
# Legacy headless entry paths must also display the app warning without prompting.
$legacy=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains("[Console]::Error.WriteLine((T 'warnApps'))")},$true)
Assert ($null -ne $legacy) 'RED: legacy CLI modes lack application warning'
$oldError=[Console]::Error
try {
    foreach($mode in @('Apply','Snapshot','AutoStart','Idle')) {
        $Apply=$false;$Snapshot=$false;$AutoStart=$false;$Idle=$false
        Set-Variable -Name $mode -Value $true
        $capturedError=New-Object IO.StringWriter
        [Console]::SetError($capturedError)
        & ([scriptblock]::Create($legacy.Extent.Text))
        Assert ($capturedError.ToString() -match 'reinstall') ('Legacy '+$mode+' launch warning absent')
    }
} finally { [Console]::SetError($oldError) }
# The independently launched backup/recovery window must carry the same app warning.
. (Join-Path $root 'src/backup/Ui.ps1')
[xml]$backupXaml=Get-PitrBackupXaml
$banner=$backupXaml.SelectSingleNode('//*[@*[local-name()="Name"]="ApplicationWarning"]')
Assert ($null -ne $banner) 'RED: independently launched backup UI has no persistent application warning'
Assert ($banner.Text -match 'apps' -and $banner.Text -match 'reinstall' -and $banner.Text -match 'Close') 'Backup window application warning incomplete'
# Real CLI child: warning on every invocation, stderr only, stdout remains valid JSON.
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('pitr-warning-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try {
    foreach($attempt in 1..2) {
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=(Get-Process -Id $PID).Path
        $info.Arguments='-NoProfile -File "'+(Join-Path $root 'src/backup/Entry.ps1')+'" backup list --destination "'+$fixture+'" --format json'
        $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $child=[Diagnostics.Process]::Start($info)
        $stdout=$child.StandardOutput.ReadToEnd();$stderr=$child.StandardError.ReadToEnd()
        $child.WaitForExit()
        Assert ($child.ExitCode -eq 0) 'Read-only list failed'
        $result=$stdout | ConvertFrom-Json
        Assert ($result.Complete) 'CLI stdout JSON damaged by warning'
        Assert ($stderr -match 'apps' -and $stderr -match 'reinstall' -and $stderr -match 'Close') 'RED: CLI application warning absent'
        $child.Dispose()
    }
} finally { [IO.Directory]::Delete($fixture,$true) }
Write-Output ('Safety warnings: '+$script:checks+' assertions passed; actual WPF rendering/Windows restart not exercised.')
