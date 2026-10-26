$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$platform=Join-Path $root 'src/backup/Platform.ps1'
if(-not (Test-Path -LiteralPath $platform)) { throw 'Platform.ps1 missing.' }
. $platform

$script:Failures=New-Object 'Collections.Generic.List[string]'
$script:Passed=0
function Assert-True([bool]$Condition,[string]$Message) {
    if($Condition) { $script:Passed++ } else { $script:Failures.Add($Message) }
}
function Assert-Equal($Expected,$Actual,[string]$Message) {
    if($Expected -eq $Actual) { $script:Passed++ } else { $script:Failures.Add($Message+' (expected ['+$Expected+'], got ['+$Actual+'])') }
}
function New-ScratchRoot([string]$Name) {
    # Use the mandated agent scratch root on this Linux lane. A Windows CI execution has no
    # /root path, so keep its temporary fixture outside the repository in the runner temp root.
    $scratch='/root/.hermes/cache/scratch'
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $scratch=[IO.Path]::GetTempPath() }
    if(-not [IO.Directory]::Exists($scratch)) { $null=[IO.Directory]::CreateDirectory($scratch) }
    $path=Join-Path $scratch ('volume-fixture-'+$Name+'-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($path)
    return $path
}

$actualWindows=([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$savedOs=$env:OS
$savedForce=$env:PITR_FORCE_WINDOWS_HOST
$savedFixture=$env:PITR_VOLUME_IDENTITY_FIXTURE
$fixtureRoot=$null
try {
    # OS identity is a runtime fact, not an inherited environment assertion.
    $env:OS=if($actualWindows) { 'spoof-non-windows' } else { 'Windows_NT' }
    Remove-Item Env:PITR_FORCE_WINDOWS_HOST -ErrorAction SilentlyContinue
    $detected=Get-PitrWindowsHost
    Assert-Equal $actualWindows $detected 'Get-PitrWindowsHost must use actual runtime OS detection, not spoofable $env:OS'

    if($actualWindows) {
        # Keep the native identity probe on the genuine Windows branch even when the OS-spoof
        # assertion above fails against the current implementation.
        $env:OS='Windows_NT'
        # On Windows, compare the native identity with the same real system-volume path while an
        # inherited fixture claims a fabricated identity. Read-only: this never probes/writes a volume.
        $systemRoot=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        if([string]::IsNullOrWhiteSpace($systemRoot)) { $systemRoot=$env:SystemRoot }
        if([string]::IsNullOrWhiteSpace($systemRoot)) { throw 'Cannot locate Windows directory for native identity regression.' }
        $baseline=Get-PitrVolumeIdentity -Path $systemRoot
        $fixtureRoot=New-ScratchRoot 'windows'
        $fixture=Join-Path $fixtureRoot 'spoof.json'
        $key=[IO.Path]::GetFullPath($baseline.CanonicalComparisonPath).Replace('\','\\')
        $utf8=New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($fixture,('{"'+$key+'":"local-forged|serial:DEADBEEF"}'),$utf8)
        $env:PITR_VOLUME_IDENTITY_FIXTURE=$fixture
        $env:OS='spoof-non-windows'
        $env:PITR_FORCE_WINDOWS_HOST='0'
        Assert-True (Get-PitrWindowsHost) 'Windows native branch cannot be disabled by OS/force environment spoofing'
        $after=$null
        $nativeFailed=$false
        try { $after=Get-PitrVolumeIdentity -Path $systemRoot } catch { $nativeFailed=$true }
        if($nativeFailed) {
            # Fail-closed refusal is acceptable; the ambient fixture must not rescue native failure.
            Assert-True $true 'fixture did not supply identity after native identity failure'
        } else {
            Assert-Equal $baseline.VolumeId $after.VolumeId 'ambient PITR_VOLUME_IDENTITY_FIXTURE cannot change native identity of the current Windows system volume'
            Assert-True ($after.VolumeId -ne 'local-forged|serial:deadbeef') 'forged fixture identity was not returned on Windows'
        }
        Write-Output 'Windows native-volume regression branch executed; native identity outcome checked.'
    } else {
        # Linux cannot prove native Windows volume semantics. It does exercise the shipped
        # runtime OS decision above and documents the allowed synthetic fixture behavior below.
        $fixtureRoot=New-ScratchRoot 'linux'
        $path=Join-Path $fixtureRoot 'synthetic-volume'
        $null=[IO.Directory]::CreateDirectory($path)
        $comparison=[IO.Path]::GetFullPath($path)
        $fixture=Join-Path $fixtureRoot 'fixture.json'
        $utf8=New-Object Text.UTF8Encoding($false)
        $key=$comparison.Replace('\','\\')
        [IO.File]::WriteAllText($fixture,('{"'+$key+'":"host-test-fixture|serial:01020304"}'),$utf8)
        $env:PITR_VOLUME_IDENTITY_FIXTURE=$fixture
        $identity=Get-PitrVolumeIdentity -Path $path
        Assert-Equal 'host-test-fixture|serial:01020304' $identity.VolumeId 'Linux synthetic fixture remains usable (not Windows proof)'
        Write-Output 'Linux runtime-OS contract and synthetic fixture path exercised; no Windows identity proof.'
    }
} finally {
    if($null -eq $savedOs) { Remove-Item Env:OS -ErrorAction SilentlyContinue } else { $env:OS=$savedOs }
    if($null -eq $savedForce) { Remove-Item Env:PITR_FORCE_WINDOWS_HOST -ErrorAction SilentlyContinue } else { $env:PITR_FORCE_WINDOWS_HOST=$savedForce }
    if($null -eq $savedFixture) { Remove-Item Env:PITR_VOLUME_IDENTITY_FIXTURE -ErrorAction SilentlyContinue } else { $env:PITR_VOLUME_IDENTITY_FIXTURE=$savedFixture }
    if($fixtureRoot -and [IO.Directory]::Exists($fixtureRoot)) { [IO.Directory]::Delete($fixtureRoot,$true) }
}
Write-Output ('Volume fixture boundary assertions passed: '+$script:Passed+'; failures: '+$script:Failures.Count+'.')
if($script:Failures.Count -gt 0) {
    foreach($failure in $script:Failures) { [Console]::Error.WriteLine('FAIL '+$failure) }
    throw ('Volume fixture boundary failed: '+$script:Failures.Count+' assertion(s).')
}
