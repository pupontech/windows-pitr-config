$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Platform.ps1')
function Assert($ok,[string]$why) { if(-not $ok) { throw $why } }
$nativeDiscovery=${function:Get-PitrProfileListProfiles}
function Get-PitrProfileListProfiles { [pscustomobject]@{Sid='user';Path='C:\Users\User';IsPublic=$false;Inaccessible=$false;Reason=$null} }
function Get-PitrPublicProfile { [pscustomobject]@{Sid='S-1-5-32-545';Path='C:\Users\Public';IsPublic=$true;Inaccessible=$false;Reason=$null} }
$profiles=@(Get-PitrProfiles)
Assert ($profiles.Count -eq 2 -and @($profiles | Where-Object { $_.IsPublic }).Count -eq 1) 'RED: Public must be discovered independently when no Users-group SID exists in ProfileList.'
function Get-PitrProfileListProfiles {
    [pscustomobject]@{Sid='user';Path='C:\Users\User';IsPublic=$false;Inaccessible=$false;Reason=$null}
    [pscustomobject]@{Sid='S-1-5-32-545';Path='C:\Users\Public';IsPublic=$true;Inaccessible=$false;Reason=$null}
}
Assert (@(Get-PitrProfiles).Count -eq 2) 'Do not duplicate an already represented Public source.'
# Exercise the production Public helper with inert registry/volume boundaries.
. (Join-Path $root 'src/backup/Platform.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('pitr-public-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try {
    function Get-ItemProperty { param($LiteralPath,$Name,$ErrorAction) [pscustomobject]@{Public=$fixture} }
    function Get-PitrVolumeIdentity { param($Path) [pscustomobject]@{VolumeId='os-volume'} }
    function Get-PitrWindowsHost { $true }
    $public=Get-PitrPublicProfile
    Assert ($public.IsPublic -and -not $public.Inaccessible -and $public.Path -eq $fixture) 'Production helper must read the independent Public registry value.'
    function Get-PitrVolumeIdentity { param($Path) [pscustomobject]@{VolumeId=if($Path -eq $fixture){'other-volume'}else{'os-volume'}} }
    $public=Get-PitrPublicProfile
    Assert ($public.Inaccessible -and $public.Reason -match 'volume') 'Off-OS-volume Public must be explicitly unavailable under the discovery contract.'
    function Get-ItemProperty { param($LiteralPath,$Name,$ErrorAction) throw 'Registry unavailable' }
    $public=Get-PitrPublicProfile
    Assert ($public.IsPublic -and $public.Inaccessible -and $public.Reason) 'Unavailable Public location must remain visible, not silently disappear.'
} finally { [IO.Directory]::Delete($fixture,$true) }
Write-Output 'Independent Public discovery, duplicate prevention, registry failure and volume-boundary tests passed with inert registry/volume seams.'
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Remove-Item Function:\Get-ItemProperty
    . (Join-Path $root 'src/backup/Platform.ps1')
    $public=Get-PitrPublicProfile
    Assert ($public.IsPublic -and -not $public.Inaccessible -and [IO.Directory]::Exists($public.Path)) ('Native Windows Public discovery failed: '+$public.Reason)
    $all=@(Get-PitrProfiles)
    Assert (@($all | Where-Object { $_.IsPublic }).Count -eq 1) 'Native discovery must include Public exactly once.'
    Write-Output 'Native Windows registry and volume identity Public discovery passed.'
} else { Write-Output 'SKIP: native Windows Public discovery requires Windows.' }
