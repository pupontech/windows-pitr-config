[CmdletBinding()]
param([string]$Root=(Split-Path $PSScriptRoot -Parent),[string]$OutDirectory,
      [ValidatePattern('^(unversioned|[0-9a-f]{40})$')][string]$SourceCommit='unversioned')
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath($Root)
if(-not $OutDirectory) { $OutDirectory=Join-Path $Root 'dist' }
$OutDirectory=[IO.Path]::GetFullPath($OutDirectory)
$required=@('START-HERE.cmd','pitr-config.cmd','pitr-backup.cmd','LICENSE','README.md','CHANGELOG.md','TESTING.md','USER-GUIDE.md','USER-GUIDE.html','docs/BACKUP-RECOVERY-GUIDE.md')
foreach($name in @('Platform','Manifest','Backup','Recovery','Ui','Localization','Cli','Entry')) { $required += 'src/backup/'+$name+'.ps1' }
foreach($rel in $required) { if(-not [IO.File]::Exists((Join-Path $Root $rel))) { throw ('Portable application incomplete; missing '+$rel) } }
$utf8=New-Object Text.UTF8Encoding($false,$true)
$cmd=$utf8.GetString([IO.File]::ReadAllBytes((Join-Path $Root 'pitr-config.cmd')))
$versionMatch=[regex]::Match($cmd,'\$Version\s*=\s*''([0-9A-Za-z.+-]+)''')
if(-not $versionMatch.Success) { throw 'Could not determine application version.' }
$version=$versionMatch.Groups[1].Value
$files=New-Object 'Collections.Generic.SortedDictionary[string,byte[]]' ([StringComparer]::Ordinal)
foreach($rel in $required) { $files.Add($rel,[IO.File]::ReadAllBytes((Join-Path $Root $rel))) }
$guide=Join-Path $Root 'docs/guide.html'
if([IO.File]::Exists($guide)) { $files.Add('guide.html',[IO.File]::ReadAllBytes($guide)) }
# Ship owner-facing schema documentation, not agent transcripts/checkpoints or fixture data.
$schemaGuide=Join-Path $Root 'docs/development/BACKUP-SCHEMA-REPORTS.md'
if ([IO.File]::Exists($schemaGuide)) { $files.Add('docs/BACKUP-SCHEMA-REPORTS.md',[IO.File]::ReadAllBytes($schemaGuide)) }
$inventory=New-Object 'Collections.Generic.List[object]'
foreach($rel in @($files.Keys)) {
    $bytes=$files[$rel]
    if($rel -match '\.(ps1|cmd|bat)$') {
        $text=$utf8.GetString($bytes).TrimStart([char]0xFEFF)
        $text=$text.Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n")
        $bytes=$utf8.GetBytes($text);$files[$rel]=$bytes
    }
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $inventory.Add([pscustomobject]@{Path=$rel;Length=$bytes.Length;Sha256=$hash})
}
$meta=[pscustomobject]@{SchemaVersion=1;ApplicationVersion=$version;SourceCommit=$SourceCommit;Files=$inventory.ToArray();Note='Integrity inventory is not a digital signature. Preserve the trusted application source.'}
$files.Add('package-integrity.json',$utf8.GetBytes(($meta | ConvertTo-Json -Depth 6)))
$null=[IO.Directory]::CreateDirectory($OutDirectory)
$temp=Join-Path $OutDirectory ('.building-'+[guid]::NewGuid().ToString('N')+'.zip')
$final=Join-Path $OutDirectory ('windows-pitr-config-'+$version+'.zip')
# Windows PowerShell 5.1 needs both assemblies: ZipArchive/ZipArchiveMode live in
# System.IO.Compression, ZipFile in System.IO.Compression.FileSystem.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
    $stream=New-Object IO.FileStream($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $archive=New-Object System.IO.Compression.ZipArchive($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        foreach($rel in $files.Keys) {
            $entry=$archive.CreateEntry($rel,[System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime=[DateTimeOffset]::new(2000,1,1,0,0,0,[TimeSpan]::Zero)
            $entryStream=$entry.Open()
            try { $bytes=$files[$rel];$entryStream.Write($bytes,0,$bytes.Length) } finally { $entryStream.Dispose() }
        }
    } finally { $archive.Dispose();$stream.Dispose() }
    $hash=(Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
    if([IO.File]::Exists($final)) {
        if((Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Refusing to overwrite a different existing artifact. Use a new output directory or version.' }
        [IO.File]::Delete($temp)
    } else { [IO.File]::Move($temp,$final) }
    [pscustomobject]@{Path=$final;Sha256=$hash;Bytes=([IO.FileInfo]$final).Length;Entries=$files.Count;Version=$version}
} finally {
    if([IO.File]::Exists($temp)) {
        # A build must never leave a locked temporary archive behind: Windows PowerShell 5.1 can
        # release the archive handle a moment after Dispose, so retry briefly before giving up.
        for($attempt=0;$attempt -lt 20 -and [IO.File]::Exists($temp);$attempt++) {
            try { [IO.File]::Delete($temp) } catch { [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 150 }
        }
    }
}
