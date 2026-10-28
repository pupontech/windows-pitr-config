# Exercise unmodified CMD -> powershell.exe -STA -> Entry -> actual WPF window.
# No backup, restore, elevation, registry writes or injected production hooks.
[CmdletBinding()]
param([string]$PackageRoot)
$ErrorActionPreference='Stop'
# Windows PowerShell 5.1 -File may evaluate advanced-script defaults before
# PSScriptRoot is populated. Resolve the default inside the script body.
if(-not $PackageRoot) { $PackageRoot=Split-Path $PSScriptRoot -Parent }
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Output 'SKIP: native no-argument CMD/WPF and console failure visibility require Windows.'
    return
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PitrLauncherWindowProbe {
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
$base=$env:RUNNER_TEMP
if(-not $base) { $base=[IO.Path]::GetTempPath() }
$fixture=Join-Path $base ('pitr-startup-'+[guid]::NewGuid().ToString('N'))
$hostile=Join-Path $fixture "PITR (download 1) O'Brien & A!"
$null=[IO.Directory]::CreateDirectory($hostile)
$proof=Join-Path $base 'pitr-ui-proof'
$null=[IO.Directory]::CreateDirectory($proof)
$events=New-Object 'Collections.Generic.List[object]'
$events.Add([pscustomobject]@{PackageRoot=$PackageRoot;HarnessEngine=$PSVersionTable.PSVersion.ToString()})
function Copy-LauncherPackage([string]$From,[string]$To) {
    $null=[IO.Directory]::CreateDirectory($To)
    foreach($name in @('START-HERE.cmd','pitr-backup.cmd','pitr-config.cmd')) { [IO.File]::Copy((Join-Path $From $name),(Join-Path $To $name)) }
    Copy-Item -LiteralPath (Join-Path $From 'src') -Destination $To -Recurse
}
function Start-Launcher([string]$Path,[string]$Tail='') {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$env:ComSpec
    # Match Explorer's ordinary command processor; no shell is allowed to
    # reinterpret the launcher path before the batch can read it.
    $info.Arguments='/d /v:off /s /c ""'+$Path+'"'+$(if($Tail) {' '+$Tail})+'"'
    $info.WorkingDirectory=$env:SystemRoot
    $info.UseShellExecute=$false
    $info.RedirectStandardInput=$true
    # Modern .NET supports a per-process input encoding; .NET Framework does
    # not. Its StreamWriter uses Console.InputEncoding and AutoFlush can send
    # an inherited UTF-8 BOM, accidentally satisfying PAUSE before we answer.
    $inputEncoding=New-Object Text.UTF8Encoding($false)
    if($info.PSObject.Properties['StandardInputEncoding']) { $info.StandardInputEncoding=$inputEncoding }
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.CreateNoWindow=$true
    $savedInputEncoding=[Console]::InputEncoding
    try { [Console]::InputEncoding=$inputEncoding; $p=[Diagnostics.Process]::Start($info) }
    finally { [Console]::InputEncoding=$savedInputEncoding }
    [pscustomobject]@{Process=$p;Out=$p.StandardOutput.ReadToEndAsync();Err=$p.StandardError.ReadToEndAsync()}
}
function Stop-OwnedLauncher($Run) {
    if(-not $Run.Process.HasExited) {
        # Only descendants of this fixture's exact CMD PID may be terminated.
        foreach($child in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$Run.Process.Id))) {
            $childProcess=$null
            try { $childProcess=[Diagnostics.Process]::GetProcessById($child.ProcessId) } catch [ArgumentException] { continue }
            try {
                if(-not $childProcess.HasExited) { $childProcess.Kill() }
                if(-not $childProcess.WaitForExit(10000)) { throw 'Fixture child termination was not confirmed; refusing to assume cleanup completed.' }
            } finally { $childProcess.Dispose() }
        }
        $Run.Process.Kill()
        $null=$Run.Process.WaitForExit(10000)
    }
    $Run.Process.Dispose()
}
function Wait-LauncherExit($Run,[Nullable[int]]$Expected,[string]$Label) {
    if(-not $Run.Process.WaitForExit(15000)) { throw ($Label+' hung; explicit CLI must not pause.') }
    $out=$Run.Out.Result; $err=$Run.Err.Result
    if(($null -ne $Expected -and $Run.Process.ExitCode -ne $Expected) -or ($null -eq $Expected -and $Run.Process.ExitCode -eq 0)) { throw ($Label+' exit '+$Run.Process.ExitCode+': '+$out+' '+$err) }
    [pscustomobject]@{Output=$out;Error=$err}
}
try {
    Copy-LauncherPackage $PackageRoot $hostile
    foreach($name in @('START-HERE.cmd','pitr-backup.cmd','pitr-config.cmd')) {
        if($name -eq 'pitr-config.cmd') {
            $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Original GUI proof requires an already-elevated runner. This harness must not trigger a real UAC request.' }
        }
        $path=Join-Path $hostile $name
        $run=Start-Launcher $path '--help'
        try {
            $r=Wait-LauncherExit $run 0 ($name+' help')
            if($r.Output -notmatch 'dry-run') { throw 'Hostile-path help did not reach the actual entrypoint.' }
        } finally { Stop-OwnedLauncher $run }
        $run=Start-Launcher $path
        $childProcess=$null;$element=$null;$statusText='';$seenWindow=$false;$warningSeen=$false
        $original=$name -eq 'pitr-config.cmd'
        $expectedTitle=if($original) {'Point-in-time restore'} else {'Backup and Recovery'}
        try {
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while($watch.Elapsed.TotalSeconds -lt 60) {
                if($run.Process.HasExited) { throw ('RED: '+$name+' no-argument launch exited before GUI discovery completed: '+$run.Process.ExitCode+' '+$run.Out.Result+' '+$run.Err.Result) }
                if($null -eq $childProcess) {
                    $children=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$run.Process.Id) | Where-Object { $_.Name -ieq 'powershell.exe' -and $_.CommandLine -match '(?i)-STA\b' })
                    if($children.Count -eq 1) { $childProcess=[Diagnostics.Process]::GetProcessById($children[0].ProcessId) }
                }
                if($childProcess) {
                    $childProcess.Refresh()
                    if($childProcess.HasExited) { throw 'Native PowerShell host exited before first rendered/discovery-ready window.' }
                    $handle=$childProcess.MainWindowHandle
                    if($handle -ne [IntPtr]::Zero) {
                        $element=[Windows.Automation.AutomationElement]::FromHandle($handle)
                        if($original -and $element.Current.Name -eq 'Applications and data before restore' -and $element.Current.ClassName -eq '#32770') {
                            # Only acknowledge the informational app-impact warning;
                            # never click a recovery/reboot/mutation confirmation.
                            $okCondition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,'1')
                            $ok=$element.FindFirst([Windows.Automation.TreeScope]::Descendants,$okCondition)
                            if($null -eq $ok) { throw 'Known informational warning has no OK button.' }
                            $ok.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
                            $warningSeen=$true
                        } elseif($element.Current.Name -eq $expectedTitle) {
                            $seenWindow=$true
                            $statusId=if($original) {'TxtLog'} else {'Status'}
                            $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$statusId)
                            $status=$element.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
                            if($status) {
                                $statusText=if($original) {$status.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value} else {$status.Current.Name}
                            }
                            if($original -and $warningSeen -and $statusText -match 'Ready\. Values|This Windows does not have point-in-time restore') { break }
                            if(-not $original -and $statusText -like 'All discovered profiles selected.*') { break }
                            if($statusText -like 'Operation failed:*' -or ($original -and $statusText -match 'Error:')) { throw ('Actual startup discovery failed: '+$statusText) }
                        }
                    }
                }
                Start-Sleep -Milliseconds 200
            }
            $ready=if($original) {$warningSeen -and $statusText -match 'Ready\. Values|This Windows does not have point-in-time restore'} else {$statusText -like 'All discovered profiles selected.*'}
            if(-not $seenWindow -or -not $ready -or ($original -and $statusText -match 'Error:')) { throw ('No real rendered/startup-ready window within deadline: '+$name+'; '+$statusText) }
            $null=[PitrLauncherWindowProbe]::SetForegroundWindow($childProcess.MainWindowHandle)
            Start-Sleep -Milliseconds 200
            $rect=$element.Current.BoundingRectangle
            if($rect.Width -lt 100 -or $rect.Height -lt 100 -or $element.Current.IsOffscreen) { throw 'GUI exists but is not visibly rendered.' }
            $bitmap=New-Object Drawing.Bitmap([int]$rect.Width,[int]$rect.Height)
            $graphics=[Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.CopyFromScreen([int]$rect.X,[int]$rect.Y,0,0,$bitmap.Size)
                $bitmap.Save((Join-Path $proof ($name+'-noargs.png')),[Drawing.Imaging.ImageFormat]::Png)
            } finally { $graphics.Dispose();$bitmap.Dispose() }
            $events.Add([pscustomobject]@{Launcher=$name;Path=$path;NativeEngine=$childProcess.MainModule.FileName;Window=$element.Current.Name;Status=$statusText;Visible=$true})
            $null=[PitrLauncherWindowProbe]::PostMessage($childProcess.MainWindowHandle,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)
            $null=Wait-LauncherExit $run 0 ($name+' WM_CLOSE shutdown')
            Write-Output ('PASS: actual '+$name+' no arguments -> visible WPF -> profile discovery -> WM_CLOSE shutdown, native Windows PowerShell STA.')
        } finally { if($childProcess) {$childProcess.Dispose()};Stop-OwnedLauncher $run }
    }
    foreach($missing in @('Entry','Platform')) {
        $broken=Join-Path $fixture ('missing-'+$missing)
        Copy-LauncherPackage $PackageRoot $broken
        [IO.File]::Delete((Join-Path $broken ('src/backup/'+$missing+'.ps1')))
        $run=Start-Launcher (Join-Path $broken 'START-HERE.cmd')
        try {
            Start-Sleep -Seconds 3
            if($run.Process.HasExited) { throw ('RED: double-click failure vanished before acknowledgement for missing '+$missing) }
            $run.Process.StandardInput.WriteLine(' ');$run.Process.StandardInput.Flush()
            if(-not $run.Process.WaitForExit(15000)) { throw 'Acknowledged failure did not exit.' }
            if($run.Process.ExitCode -eq 0 -or $run.Out.Result -notmatch 'PITR could not open' -or ($run.Out.Result+$run.Err.Result) -notmatch ($missing+'\.ps1')) { throw ('Missing dependency diagnostic/exit lost: '+$run.Out.Result+' '+$run.Err.Result) }
            $events.Add([pscustomobject]@{Missing=$missing;AcknowledgementRequired=$true;ExitCode=$run.Process.ExitCode})
        } finally { Stop-OwnedLauncher $run }
        $run=Start-Launcher (Join-Path $broken 'pitr-backup.cmd') 'backup --unknown'
        try {
            # Missing Entry never reaches our parser: powershell.exe owns that
            # native nonzero code. With Entry present, invalid input is exactly 3.
            $expected=if($missing -eq 'Entry') {$null} else {3}
            $r=Wait-LauncherExit $run $expected 'Explicit invalid CLI, incomplete package'
            if(($r.Output+$r.Error) -notmatch $(if($missing -eq 'Entry') {'Entry\.ps1'} else {'Unknown option'})) { throw 'CLI failed for the wrong reason.' }
        } finally { Stop-OwnedLauncher $run }
    }
    $events.ToArray() | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $proof 'launcher-startup.json') -Encoding UTF8
    Write-Output 'PASS: missing-entry/module GUI failures remain visible; explicit CLI does not pause.'
} finally {
    # Delete only this GUID-owned synthetic package; never source profiles/data.
    if([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture,$true) }
}
