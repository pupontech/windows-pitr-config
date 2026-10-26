$ErrorActionPreference='Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Output 'SKIP: real WPF confirmation default-button proof requires Windows.'
    return
}
$root=Split-Path $PSScriptRoot -Parent
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/backup/Ui.ps1'),[ref]$t,[ref]$e)
$recover=$ast.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$recover'},$true)
$call=$recover.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '[Windows.MessageBox]' -and $n.Member.Value -eq 'Show'},$true)
if(-not $call){throw 'Production confirmation invocation missing'}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PitrDialogProbe {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls,string title);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr window,int id);
 [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr window,int index);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window,uint msg,IntPtr w,IntPtr l);
}
'@
$rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.Open()
$ps=[powershell]::Create();$ps.Runspace=$rs
$dialog=[IntPtr]::Zero;$noButton=[IntPtr]::Zero
try {
    $null=$ps.AddScript(('Add-Type -AssemblyName PresentationFramework; $message="Inert confirmation-default test; no file recovery is performed."; '+$call.Extent.Text))
    $async=$ps.BeginInvoke()
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($dialog -eq [IntPtr]::Zero -and $clock.Elapsed.TotalSeconds -lt 20) {
        $dialog=[PitrDialogProbe]::FindWindow('#32770','Confirm recovery')
        if($dialog -eq [IntPtr]::Zero){Start-Sleep -Milliseconds 100}
    }
    if($dialog -eq [IntPtr]::Zero){throw 'Real production WPF confirmation did not appear within 20 seconds'}
    $noButton=[PitrDialogProbe]::GetDlgItem($dialog,7)
    if($noButton -eq [IntPtr]::Zero){throw 'No button missing from real confirmation'}
    $style=[PitrDialogProbe]::GetWindowLong($noButton,-16)
    $defaultIsNo=(($style -band 15) -eq 1)
    $null=[PitrDialogProbe]::SendMessage($noButton,245,[IntPtr]::Zero,[IntPtr]::Zero)
    if(-not $async.AsyncWaitHandle.WaitOne(10000)){throw 'Confirmation did not close after inert No click'}
    $answer=@($ps.EndInvoke($async))
    if(-not $defaultIsNo){throw 'Real WPF dialog did not mark No as its default button'}
    if($answer.Count -ne 1 -or [string]$answer[0] -ne 'No'){throw 'Real WPF No button did not return No'}
    Write-Output 'Real production WPF confirmation: No is default, inert No click returns No; no recovery worker executed.'
}finally{
    if($noButton -ne [IntPtr]::Zero){$null=[PitrDialogProbe]::SendMessage($noButton,245,[IntPtr]::Zero,[IntPtr]::Zero)}
    if($ps.InvocationStateInfo.State -eq 'Running'){$ps.Stop()}
    $ps.Dispose();$rs.Dispose()
}
