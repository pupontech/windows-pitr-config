$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Platform.ps1')
. (Join-Path $root 'src/backup/Manifest.ps1')
$base=[IO.Path]::GetTempPath();if($env:TMPDIR){$base=$env:TMPDIR}
$f=Join-Path $base ('pitr-hardlink-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory((Join-Path $f 'backup'))
try {
    $outside=Join-Path $f 'outside.txt';[IO.File]::WriteAllText($outside,'outside')
    $payload=Join-Path $f 'backup/payload.txt'
    $null=New-Item -ItemType HardLink -Path $payload -Target $outside
    $refused=$false
    try { $null=Resolve-PitrPayloadPath -BackupRoot (Join-Path $f 'backup') -RelativePath 'payload.txt' } catch { $refused=$true }
    if(-not $refused){throw 'RED: hard-linked external payload was accepted'}
    if([IO.File]::ReadAllText($outside) -ne 'outside'){throw 'Outside hardlink bytes changed'}
    # Ordinary copied files must remain usable, not a blanket refusal.
    $ordinary=Join-Path $f 'backup/ordinary.txt';[IO.File]::WriteAllText($ordinary,'ordinary')
    $resolved=Resolve-PitrPayloadPath -BackupRoot (Join-Path $f 'backup') -RelativePath 'ordinary.txt'
    if($resolved -ne $ordinary){throw 'Ordinary single-link payload rejected or redirected'}
    Write-Output 'Native hardlink boundary and ordinary-payload control passed.'
} finally { [IO.Directory]::Delete($f,$true) }
