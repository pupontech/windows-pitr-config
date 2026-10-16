[CmdletBinding()]
param(
    [int]$SmallFiles=200,[int]$LargeFiles=4,[int]$LargeFileMiB=16,
    [string]$ReportPath,[switch]$SkipRobocopy,[int]$BufferKiB=256
)
$ErrorActionPreference='Stop'
$base=[IO.Path]::GetTempPath(); if($env:TMPDIR) { $base=$env:TMPDIR }
$fixture=Join-Path $base ('pitr-perf-'+[guid]::NewGuid().ToString('N'))
$source=Join-Path $fixture 'source'
$null=[IO.Directory]::CreateDirectory($source)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$datasetBytes=0
try {
    $rng=New-Object Random(20261016)
    for($i=0;$i -lt $SmallFiles;$i++) {
        $file=Join-Path $source ('small-{0:D5}.bin' -f $i)
        $buffer=New-Object byte[] (4096 + ($i % 7) * 512)
        $rng.NextBytes($buffer)
        [IO.File]::WriteAllBytes($file,$buffer)
        $datasetBytes+=$buffer.Length
    }
    foreach($i in 1..$LargeFiles) {
        $file=Join-Path $source ('large-{0:D2}.bin' -f $i)
        $stream=New-Object IO.FileStream($file,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $buffer=New-Object byte[] (1MB)
            for($chunk=0;$chunk -lt $LargeFileMiB;$chunk++) { $rng.NextBytes($buffer);$stream.Write($buffer,0,$buffer.Length) }
        } finally { $stream.Dispose() }
        $datasetBytes+=(1MB*$LargeFileMiB)
    }
    $adapters=New-Object 'Collections.Generic.List[object]'
    function Copy-Dataset([string]$Method,[string]$Destination,[string]$Executable,[string]$ArgumentTemplate) {
        $null=[IO.Directory]::CreateDirectory($Destination)
        $watch=[Diagnostics.Stopwatch]::StartNew()
        if($Executable) {
            $arguments=$ArgumentTemplate.Replace('{SOURCE}',$source).Replace('{DEST}',$Destination)
            $process=Start-Process -FilePath $Executable -ArgumentList $arguments -Wait -PassThru -NoNewWindow
            $nativeExit=$process.ExitCode
        } else {
            # Bounded streaming copy, same shape the engine uses: fixed buffer, never whole-file in memory.
            $buffer=New-Object byte[] ($BufferKiB*1KB)
            foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
                $relative=$file.FullName.Substring($source.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
                $target=Join-Path $Destination $relative
                $parent=Split-Path -Parent $target
                if(-not [IO.Directory]::Exists($parent)) { $null=[IO.Directory]::CreateDirectory($parent) }
                $input=$file.OpenRead();$output=New-Object IO.FileStream($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try { while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0) { $output.Write($buffer,0,$read) } }
                finally { $output.Dispose();$input.Dispose() }
            }
            $nativeExit=$null
        }
        $watch.Stop()
        $copySeconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
        $watch.Restart()
        $hashed=0;$bytes=0;$mismatches=0
        foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
            $relative=$file.FullName.Substring($source.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
            $target=Join-Path $Destination $relative
            if(-not [IO.File]::Exists($target)) { $mismatches++;continue }
            $sourceHash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $targetHash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if($sourceHash -ne $targetHash) { $mismatches++ } else { $hashed++;$bytes+=$file.Length }
        }
        $watch.Stop()
        [pscustomobject]@{
            Method=$Method;CopySeconds=$copySeconds;VerificationSeconds=[math]::Round($watch.Elapsed.TotalSeconds,3)
            VerifiedFiles=$hashed;VerifiedBytes=$bytes;Mismatches=$mismatches;NativeExitCode=$nativeExit
        }
    }
    $adapters.Add((Copy-Dataset -Method 'NetStreamCopy' -Destination (Join-Path $fixture 'out-net') -Executable '' -ArgumentTemplate ''))
    if(-not $SkipRobocopy) {
        $robocopy=Join-Path $env:SystemRoot 'System32/robocopy.exe'
        if([IO.File]::Exists($robocopy)) {
            # Non-destructive only. No mirror/purge/move, explicit file inventory verified afterwards.
            $adapters.Add((Copy-Dataset -Method 'Robocopy' -Destination (Join-Path $fixture 'out-robocopy') -Executable $robocopy -ArgumentTemplate ('"{SOURCE}" "{DEST}" /E /COPY:DAT /DCOPY:DA /R:2 /W:2 /XJ /NFL /NDL /NP /NJH /NJS')))
        }
    }
    [pscustomobject]@{
        SchemaVersion=1;GeneratedUtc=(Get-Date).ToUniversalTime().ToString('o')
        Engine=$PSVersionTable.PSVersion.ToString();OperatingSystem=[Environment]::OSVersion.VersionString
        Dataset=[pscustomobject]@{FileCount=($SmallFiles+$LargeFiles);Bytes=$datasetBytes;SmallFiles=$SmallFiles;LargeFiles=$LargeFiles;LargeFileMiB=$LargeFileMiB}
        Adapters=$adapters.ToArray()
        Limitations='Synthetic cached local fixture on this host and filesystem only. Verification rereads both copies. Robocopy dataset is a separate destination; its file inventory is hash verified. Not a user-profile, network, removable-media or PITR measurement.'
    } | Tee-Object -Variable result | Out-Null
    if($ReportPath) { $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding UTF8 }
    return $result
} finally {
    if([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture,$true) }
}
