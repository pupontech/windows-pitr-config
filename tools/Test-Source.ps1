[CmdletBinding()]
param([string]$Root=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath($Root)
$strictUtf8=New-Object Text.UTF8Encoding($false,$true)
$paths=New-Object 'Collections.Generic.List[string]'
$unicodeTestFiles=New-Object 'Collections.Generic.List[string]'
foreach($dir in @('src','tools','tests')) {
    $p=Join-Path $Root $dir
    if(Test-Path -LiteralPath $p) {
        foreach($f in Get-ChildItem -LiteralPath $p -Recurse -File -Filter '*.ps1') { $paths.Add($f.FullName) }
    }
}
$optIn='# pitr-encoding: unicode-test-data'
foreach($path in $paths) {
    $bytes=[IO.File]::ReadAllBytes($path)
    if($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw "BOM prohibited: $path" }
    $text=$strictUtf8.GetString($bytes)
    if($text -match '[^\x00-\x7F]') {
        # Shipping code must stay ASCII-only for PS 5.1. A test fixture may declare
        # that it deliberately carries non-ASCII path data, and only then is it allowed.
        if($path -notlike '*tests*' -or $text -notmatch [regex]::Escape($optIn)) { throw "PS5.1 sidecar must use ASCII-safe source: $path" }
        $unicodeTestFiles.Add($path)
    }
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0) { throw ("Parse failure: $path : " + (($errors | ForEach-Object {$_.Message}) -join '; ')) }
}
$hybrid=Join-Path $Root 'pitr-config.cmd'
$bytes=[IO.File]::ReadAllBytes($hybrid)
if($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'Hybrid CMD must not have UTF8 BOM.' }
$text=$strictUtf8.GetString($bytes)
$marker='#___PSCODE___'
$index=$text.LastIndexOf($marker,[StringComparison]::Ordinal)
if($index -lt 0) { throw 'PowerShell marker missing.' }
$tokens=$null; $errors=$null
$null=[Management.Automation.Language.Parser]::ParseInput($text.Substring($index+$marker.Length),[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0) { throw ('Hybrid parse failure: '+(($errors | ForEach-Object {$_.Message}) -join '; ')) }
Write-Output ('Source parse/encoding checks passed: '+$paths.Count+' scripts plus hybrid CMD; engine '+$PSVersionTable.PSVersion.ToString()+'.')
