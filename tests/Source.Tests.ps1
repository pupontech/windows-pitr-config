$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$checker=Join-Path $root 'tools/Test-Source.ps1'
$builder=Join-Path $root 'tools/Build-Portable.ps1'
if (-not (Test-Path -LiteralPath $checker)) { throw 'RED: source verifier not implemented' }
& $checker -Root $root
if (-not (Test-Path -LiteralPath $builder)) { throw 'RED: portable builder not implemented' }
$tempBase=[IO.Path]::GetTempPath()
if ($env:TMPDIR) { $tempBase=$env:TMPDIR }
$fixture=Join-Path $tempBase ('pitr-build-test-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try {
    $src=Join-Path $fixture 'source'
    $null=[IO.Directory]::CreateDirectory((Join-Path $src 'src/backup'))
    $utf8=New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $src 'pitr-config.cmd'),"@echo off`n#___PSCODE___`n`$Version='0.0.0-test'`n",$utf8)
    foreach($name in @('pitr-backup.cmd','LICENSE','README.md','CHANGELOG.md')) { [IO.File]::WriteAllText((Join-Path $src $name),'fixture',$utf8) }
    foreach($name in @('Platform','Manifest','Backup','Recovery','Ui','Localization','Cli','Entry')) { [IO.File]::WriteAllText((Join-Path $src ('src/backup/'+$name+'.ps1')),"# fixture`n",$utf8) }
    $out=Join-Path $fixture 'out'
    $a=& $builder -Root $src -OutDirectory $out
    $b=& $builder -Root $src -OutDirectory $out
    if ($a.Sha256 -ne $b.Sha256) { throw 'Identical source did not produce identical ZIP bytes.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($a.Path)
    try {
        $cmd=$zip.GetEntry('pitr-config.cmd')
        if ($null -eq $cmd) { throw 'Portable root launcher missing' }
        $r=New-Object IO.StreamReader($cmd.Open(),[Text.Encoding]::UTF8)
        try { $text=$r.ReadToEnd() } finally { $r.Dispose() }
        if ($text -match '(?<!\r)\n') { throw 'Packaged executable has bare LF' }
        if ($null -eq $zip.GetEntry('src/backup/Entry.ps1')) { throw 'Independent engine entry missing' }
        if ($null -eq $zip.GetEntry('package-integrity.json')) { throw 'Integrity inventory missing' }
    } finally { $zip.Dispose() }
    [IO.File]::Delete((Join-Path $src 'src/backup/Entry.ps1'))
    $refused=$false
    try { $null=& $builder -Root $src -OutDirectory $out } catch { $refused=$true }
    if (-not $refused) { throw 'Builder accepted incomplete recovery source' }
    Write-Output 'Source and reproducible portable-build assertions passed.'
} finally {
    # Only this test-owned GUID fixture is removed; never source/user backup data.
    [IO.Directory]::Delete($fixture,$true)
}
