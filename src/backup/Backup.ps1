# Backup engine: inventory, live copy, verification, resume and recovery package.
# Functions and types only, dot-sourced after Platform.ps1 and Manifest.ps1. No top-level work.
#
# Non-negotiable behaviour implemented here:
#   * every selected object ends as Copied, Skipped or Failed WITH a reason - never silently
#     omitted, never reported as success;
#   * the copy is explicitly labelled LiveNotApplicationConsistent and is never described as
#     application consistent (there is no VSS snapshot anywhere in this module);
#   * the copy is bounded streaming with a fixed buffer and a cancellation check between chunks
#     and between files, driven by a shared synchronized hashtable;
#   * no mirroring/purge/move, no source deletion, no silent overwrite of an existing generation,
#     no ACL or ownership changes, no reparse point following, no snapshot mutation;
#   * state moves only through the Manifest.ps1 lifecycle so an interruption can never leave a
#     manifest that claims completion.

$script:PitrBackupFolderName = 'PITR-Backups'
$script:PitrBackupProfilesFolder = 'profiles'
$script:PitrBackupExtraFolder = 'extra-folders'
$script:PitrBackupRecoveryFolder = 'recovery'
$script:PitrBackupCopyBufferBytes = 1048576
$script:PitrBackupProgressEveryChunks = 8
$script:PitrBackupProgressEveryFiles = 64
$script:PitrBackupStateFileName = 'backup-status.json'
$script:PitrBackupLogFileName = 'backup-log.txt'
$script:PitrBackupScriptVersion = '1.0'
$script:PitrBackupManifestName = 'manifest.json'

# Test-only fixtures. Real Windows runs leave these unset and therefore use the real filesystem
# and the platform module's real validation. Each hook only answers a question about a path the
# engine asks about; it can never inject an entry, a hash or an accounting decision.
$script:PitrBackupAttributesFixture = $null
$script:PitrBackupUnsupportedFixture = $null
$script:PitrBackupFailureFixture = $null
$script:PitrBackupFailureSeed = [guid]::NewGuid().ToString('N')

function Get-PitrBackupTestHook {
    # Reads a fixture list only when the suite has registered one; otherwise returns nothing.
    param([string]$Variable,[string]$FileName)
    $path = [Environment]::GetEnvironmentVariable($Variable)
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.File]::Exists($path)) { return @() }
    $entries = New-Object 'Collections.Generic.List[string]'
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
        $value = $line.Trim()
        if ($value.Length -eq 0) { continue }
        if ($value.StartsWith('#')) { continue }
        $entries.Add($value.Replace('\','/').TrimStart('/'))
    }
    return $entries.ToArray()
}

function Initialize-PitrBackupTestHooks {
    $script:PitrBackupAttributesFixture = Get-PitrBackupTestHook -Variable 'PITR_BACKUP_ATTRIBUTES_FIXTURE' -FileName 'attributes.txt'
    $script:PitrBackupUnsupportedFixture = Get-PitrBackupTestHook -Variable 'PITR_BACKUP_UNSUPPORTED_FIXTURE' -FileName 'unsupported.txt'
    $script:PitrBackupFailureFixture = Get-PitrBackupTestHook -Variable 'PITR_BACKUP_FAILURE_FIXTURE' -FileName 'failure.txt'
}

function Test-PitrBackupFixtureMatch {
    param([string[]]$Fixture,[string]$RelativePath)
    if ($null -eq $Fixture -or $Fixture.Count -eq 0) { return $false }
    $normalized = $RelativePath.Replace('\','/')
    foreach ($candidate in $Fixture) { if ($candidate -eq $normalized) { return $true } }
    return $false
}

function Get-PitrBackupFileName {
    param([string]$Path)
    $name = [IO.Path]::GetFileName($Path)
    if ([string]::IsNullOrEmpty($name)) { return $Path }
    return $name
}

function New-PitrBackupToken {
    $guid = [guid]::NewGuid().ToString('N')
    return $guid.Substring(0,8)
}

function Get-PitrBackupUniqueDirectory {
    param([string]$Parent,[string]$Stamp,[string]$Token)
    $candidate = Join-Path $Parent ($Stamp + '_' + $Token)
    $suffix = 0
    while ([IO.Directory]::Exists($candidate) -or [IO.File]::Exists($candidate)) {
        $suffix = $suffix + 1
        if ($suffix -gt 64) { throw ('Backup generation name could not be made unique under: ' + $Parent) }
        $candidate = Join-Path $Parent ($Stamp + '_' + $Token + '-' + $suffix)
    }
    return $candidate
}

function Test-PitrBackupCancelled {
    # Synchronized hashtable (or any object exposing Cancelled) shared with the caller.
    param($Cancellation)
    if ($null -eq $Cancellation) { return $false }
    try {
        $entry = $Cancellation['Cancelled']
        if ($null -eq $entry) { return $false }
        return [bool]$entry
    } catch { return $false }
}

function Invoke-PitrBackupProgress {
    # Progress is observation only. A broken observer must never abort or corrupt a backup.
    param($Progress,[string]$Phase,[string]$Profile,[string]$File,[int64]$FilesProcessed,[int64]$BytesProcessed,[int64]$TotalBytes,[int]$ErrorCount)
    if ($null -eq $Progress) { return }
    try {
        & $Progress ([pscustomobject]@{
            Phase=$Phase
            Profile=$Profile
            File=$File
            FilesProcessed=$FilesProcessed
            BytesProcessed=$BytesProcessed
            TotalBytes=$TotalBytes
            ErrorCount=$ErrorCount
        })
    } catch { }
}

function Read-PitrBackupFixtureIdentity {
    param([string]$BackupRoot)
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) { return $null }
    try {
        $parent = Split-Path $BackupRoot -Parent
        if ([string]::IsNullOrWhiteSpace($parent)) { return $null }
        $path = Join-Path $parent 'destination.json'
        if (-not [IO.File]::Exists($path)) { return $null }
        $identity = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($null -eq $identity.PSObject.Properties['VolumeId']) { return $null }
        return $identity
    } catch { return $null }
}

function Get-PitrBackupDestinationRoot {
    # Destination root is the PITR-Backups folder itself. Generations live under
    # <root>/<COMPUTER>/<timestamp>_<short-id> and a generation is never overwritten.
    param([string]$Destination)
    $full = [IO.Path]::GetFullPath($Destination)
    $name = [IO.Path]::GetFileName($full)
    if ($name -eq $script:PitrBackupFolderName) { return $full }
    $candidate = Join-Path $full $script:PitrBackupFolderName
    if ([IO.Directory]::Exists($candidate)) { return $candidate }
    $identity = Read-PitrBackupFixtureIdentity -BackupRoot $candidate
    if ($null -ne $identity) { return $candidate }
    if (-not [IO.Directory]::Exists($full)) { throw ('Backup destination does not exist: ' + $Destination) }
    $manifestHere = Join-Path $full $script:PitrBackupManifestName
    if ([IO.File]::Exists($manifestHere)) { return $full }
    return $candidate
}

function Get-PitrBackupComputerIdentity {
    $computer = $null
    try { $computer = [Environment]::MachineName } catch { $computer = $null }
    if ([string]::IsNullOrWhiteSpace($computer)) { $computer = 'unknown-computer' }
    $builder = New-Object Text.StringBuilder
    foreach ($character in $computer.ToCharArray()) {
        if ([int]$character -lt 32) { continue }
        if ('<>:"/\|?*'.IndexOf($character) -ge 0) { $null = $builder.Append('_') } else { $null = $builder.Append($character) }
    }
    $safe = $builder.ToString().Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'unknown-computer' }
    if ($safe.Length -gt 64) { $safe = $safe.Substring(0,64) }
    if (-not (Test-PitrWindowsComponent -Component $safe)) { $safe = 'computer-' + (New-PitrStableId -Text $computer).Substring(0,12) }
    return $safe
}

function Get-PitrBackupApplicationVersion {
    param([string]$RecoverySource)
    if ([string]::IsNullOrWhiteSpace($RecoverySource)) { return $script:PitrBackupScriptVersion }
    $candidate = Join-Path $RecoverySource 'pitr-config.cmd'
    if (-not [IO.File]::Exists($candidate)) { return $script:PitrBackupScriptVersion }
    try {
        $text = [IO.File]::ReadAllText($candidate, [Text.UTF8Encoding]::new($false))
        $match = [regex]::Match($text,"\$Version\s*=\s*'([0-9A-Za-z.+-]+)'")
        if ($match.Success) { return $match.Groups[1].Value }
    } catch { }
    return $script:PitrBackupScriptVersion
}

function Get-PitrBackupLogTimestamp {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function Write-PitrBackupLog {
    param($Log,[string]$Message)
    if ($null -eq $Log) { return }
    $line = (Get-PitrBackupLogTimestamp) + ' ' + $Message
    try {
        $null = $Log.Lines.Add($line)
        if ($null -ne $Log.Writer) {
            $Log.Writer.WriteLine($line)
            $Log.Writer.Flush()
        }
    } catch { }
}

function Set-PitrBackupStatusFile {
    # Operational status for the UI and the operator. The manifest remains the authority on
    # whether the generation is complete; a plain status file can never claim that by itself.
    param($Log,[string]$Path,[string]$Phase,[string]$State,[object]$Counts,[int]$ErrorCount,[string]$CancellationReason,[string]$Message)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $status = [pscustomobject]@{
        SchemaVersion=1
        BackupId=$Log.BackupId
        State=$State
        Phase=$Phase
        Consistency='LiveNotApplicationConsistent'
        SourceView='Live'
        StartedUtc=$Log.StartedUtc
        UpdatedUtc=(Get-Date).ToUniversalTime().ToString('o')
        Counts=$Counts
        ErrorCount=$ErrorCount
        CancellationReason=if ($CancellationReason) { $CancellationReason } else { $null }
        CurrentFile=$Log.CurrentRelativePath
        RecoveryPackage=$null
        ManifestPath=$Log.ManifestPath
        Message=$Message
    }
    try {
        $json = $status | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
    } catch {
        Write-PitrBackupLog -Log $Log -Message ('WARNING status file could not be updated: ' + $_.Exception.Message)
    }
    return $status
}

function New-PitrBackupLog {
    param([string]$GenerationPath,[string]$BackupId,[int]$RetainedLines=4000)
    $log = [pscustomobject]@{
        BackupId=$BackupId
        StartedUtc=(Get-Date).ToUniversalTime().ToString('o')
        Path=(Join-Path $GenerationPath $script:PitrBackupLogFileName)
        Writer=$null
        Lines=(New-Object 'Collections.Generic.List[string]')
        Active=$true
        CurrentRelativePath=$null
        RetainedLines=$RetainedLines
    }
    try {
        $stream = New-Object IO.FileStream($log.Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $log.Writer = New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($false)))
        $log.Writer.AutoFlush = $true
    } catch { $log.Writer = $null }
    return $log
}

function Add-PitrBackupLogLine {
    param($Log,[string]$Message)
    Write-PitrBackupLog -Log $Log -Message $Message
}

function Close-PitrBackupLog {
    param($Log)
    if ($null -eq $Log) { return }
    $Log.Active = $false
    if ($null -ne $Log.Writer) {
        try { $Log.Writer.Dispose() } catch { }
        $Log.Writer = $null
    }
}

function Set-PitrBackupEntry {
    # Appends one entry onto a live manifest object graph. Write-PitrManifest is the only writer.
    param($Manifest,$Entry)
    $Manifest.Entries = @($Manifest.Entries) + ,$Entry
    return $Entry
}

function New-PitrBackupInventoryEntry {
    param(
        [string]$SourceId,
        [string]$RootPath,
        [string]$RelativePath,
        [string]$BackupRelativePath,
        [string]$Type,
        [int64]$Length,
        [string]$LastWriteUtc,
        [string]$Attributes,
        [string]$SourceVolumeId,
        [string]$ProfileSid,
        [bool]$IsAdvanced,
        [bool]$IsSensitive,
        [string]$Error
    )
    $originalPath = if ([string]::IsNullOrEmpty($RelativePath)) { $RootPath } else { Join-Path $RootPath $RelativePath.Replace('/','\') }
    if (-not $PSBoundParameters.ContainsKey('IsAdvanced')) { $IsAdvanced = Test-PitrAdvancedRelativePath -RelativePath $RelativePath }
    if (-not $PSBoundParameters.ContainsKey('IsSensitive')) { $IsSensitive = Test-PitrSensitiveRelativePath -RelativePath $RelativePath }
    return (New-PitrManifestEntry -Id ([guid]::NewGuid().ToString('N')) -SourceId $SourceId -RelativePath $RelativePath -Type $Type `
        -BackupRelativePath $BackupRelativePath -OriginalPath $originalPath -ProfileSid $ProfileSid -Length $Length `
        -LastWriteUtc $LastWriteUtc -Attributes $Attributes -SourceVolumeId $SourceVolumeId `
        -IsAdvanced ([bool]$IsAdvanced) -IsSensitive ([bool]$IsSensitive) -Error $Error)
}

function Test-PitrBackupSensitivePath {
    # One rule, defined once in Manifest.ps1 so the backup and the recovery layer can
    # never disagree about what must not be written into a live profile.
    param([string]$RelativePath)
    return (Test-PitrSensitiveRelativePath -RelativePath $RelativePath)
}

function Get-PitrBackupEntryType {
    param([string]$Path,[string]$RelativePath,[string[]]$Attributes)
    if (Test-PitrBackupFixtureMatch -Fixture $script:PitrBackupUnsupportedFixture -RelativePath $RelativePath) {
        return [pscustomobject]@{ Type='Unsupported'; Error='Item could not be inventoried: the object type could not be classified for a live copy. Nothing was read from it.' }
    }
    $isDirectory = $false
    try { $isDirectory = [IO.Directory]::Exists($Path) } catch { $isDirectory = $false }
    if ($isDirectory) {
        $attributes = @()
        try { $attributes = @([IO.File]::GetAttributes($Path).ToString().Split(',').Trim()) } catch { $attributes = @() }
        if (($attributes -join ' ') -match 'ReparsePoint') {
            return [pscustomobject]@{ Type='ReparsePoint'; Error='Directory is a reparse point (junction or symbolic link); a live copy does not follow directory links and nothing was copied from it.' }
        }
        if (Test-PitrBackupFixtureMatch -Fixture $script:PitrBackupAttributesFixture -RelativePath $RelativePath) {
            return [pscustomobject]@{ Type='ReparsePoint'; Error='Directory is a reparse point (junction or symbolic link); a live copy does not follow directory links and nothing was copied from it.' }
        }
        return [pscustomobject]@{ Type='Directory'; Error=$null }
    }
    if (Test-PitrBackupFixtureMatch -Fixture $script:PitrBackupAttributesFixture -RelativePath $RelativePath) {
        return [pscustomobject]@{ Type='ReparsePoint'; Error='File is a reparse point (symbolic link or mount point); a live copy does not follow links and nothing was copied from it.' }
    }
    if ($null -ne $Attributes -and $Attributes.Count -gt 0) {
        $joined = ($Attributes -join ' ')
        if ($joined -match 'Offline') {
            return [pscustomobject]@{ Type='CloudPlaceholder'; Error='File is an offline cloud placeholder; a live copy does not hydrate cloud content and no data was read.' }
        }
        if ($joined -match 'Encrypted') {
            return [pscustomobject]@{ Type='Encrypted'; Error='File is marked encrypted (EFS); a live copy stores the encrypted bytes and cannot confirm they are readable without the same key and recovery agent.' }
        }
        if ($joined -match 'SparseFile' -or $joined -match 'Sparse') {
            return [pscustomobject]@{ Type='File'; Error='File is sparse (or a hardlink); a streamed live copy stores the file content but does not preserve sparseness or the link relationship. No ACL, ownership or link is ever changed.' }
        }
    }
    return [pscustomobject]@{ Type='File'; Error=$null }
}

function New-PitrBackupJob {
    param(
        [string]$GenerationPath,
        [string]$ManifestPath,
        [string]$LogPath,
        [string]$StatusPath,
        [string]$Root,
        [long]$TotalBytes
    )
    return [pscustomobject]@{
        GenerationPath=$GenerationPath
        ManifestPath=$ManifestPath
        LogPath=$LogPath
        StatusPath=$StatusPath
        Root=$Root
        TotalBytes=$TotalBytes
        Buffer=New-Object byte[] $script:PitrBackupCopyBufferBytes
        ProgressFileCounter=0
        LastProgressFile=$null
        LastProgressTime=$null
        CurrentRelativePath=$null
        RecoveryPackage=$null
    }
}

function Invoke-PitrBackupEntry {
    # Copies one File entry with bounded streaming. The destination sibling is unique, so an
    # existing generation can never be overwritten in place; the swap happens only after the
    # whole file has been verified.
    param($Entry,[string]$Path,[string]$DestinationRoot,$Job,$Log,$Cancellation,[int64]$BytesProcessed,[int64]$TotalBytes,[int]$ErrorCount,[int]$Index,[int]$Total,[string]$Profile,[scriptblock]$Progress)
    if (Test-PitrBackupFixtureMatch -Fixture $script:PitrBackupFailureFixture -RelativePath $Entry.RelativePath) {
        throw 'Injected read failure (test fixture): the source object could not be read.'
    }
    $destination = Join-Path $DestinationRoot (Test-PitrSafePath -Root $DestinationRoot -RelativePath $Entry.BackupRelativePath)
    if($Job.PSObject.Properties['ResumeInventory'] -and $Job.ResumeInventory -and [IO.File]::Exists($destination)) {
        $sourceHash=Get-PitrHash -Path $Path
        $storedHash=Get-PitrHash -Path $destination
        if($sourceHash -eq $storedHash) {
            $info=New-Object IO.FileInfo($Path)
            $Entry.Sha256=$storedHash
            $Entry.Length=$info.Length
            $Entry.LastWriteUtc=$info.LastWriteTimeUtc.ToString('o')
            return $info.Length
        }
        # Never overwrite previous bytes, even in an interrupted generation.
        # A new payload name allows repair while retaining the damaged/older object for inspection.
        $Entry.BackupRelativePath=$Entry.BackupRelativePath+'.resumed-'+[guid]::NewGuid().ToString('N')
        $destination=Join-Path $DestinationRoot (Test-PitrSafePath -Root $DestinationRoot -RelativePath $Entry.BackupRelativePath)
    }
    $destinationDirectory = Split-Path $destination -Parent
    if (-not [IO.Directory]::Exists($destinationDirectory)) { $null = [IO.Directory]::CreateDirectory($destinationDirectory) }
    # No silent overwrite: within a unique generation a collision is an explicit failure.
    if ([IO.File]::Exists($destination)) { throw ('Refusing to overwrite an existing backup file: ' + $Entry.BackupRelativePath) }
    $sibling = Join-Path $destinationDirectory ('.pitr-part-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    $source = $null
    $target = $null
    $bytes = 0
    try {
        $source = New-Object IO.FileStream($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $target = New-Object IO.FileStream($sibling,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $chunk = 0
        while ($true) {
            if (Test-PitrBackupCancelled -Cancellation $Cancellation) {
                throw (New-Object OperationCanceledException('Backup was cancelled while copying; the partial file was removed and the manifest stays interrupted.'))
            }
            $read = $source.Read($Job.Buffer,0,$Job.Buffer.Length)
            if ($read -le 0) { break }
            $target.Write($Job.Buffer,0,$read)
            $null = $hashAlgorithm.TransformBlock($Job.Buffer,0,$read,$Job.Buffer,0)
            $bytes = $bytes + $read
            $chunk = $chunk + 1
            if (($chunk % $script:PitrBackupProgressEveryChunks) -eq 0) {
                $Job.CurrentRelativePath = $Entry.RelativePath
                Invoke-PitrBackupProgress -Progress $Progress -Phase 'Copy' -Profile $Profile -File $Entry.RelativePath -FilesProcessed $Index -BytesProcessed ($BytesProcessed + $bytes) -TotalBytes $TotalBytes -ErrorCount $ErrorCount
            }
        }
        $null = $hashAlgorithm.TransformFinalBlock((New-Object byte[] 0),0,0)
        $target.Flush($true)
        $target.Dispose()
        $target = $null
        $source.Dispose()
        $source = $null
        $copiedHash = ([BitConverter]::ToString($hashAlgorithm.Hash)).Replace('-','').ToLowerInvariant()
        $sourceHash = Get-PitrHash -Path $Path
        if ($sourceHash -ne $copiedHash) {
            throw 'The backup copy does not hash to the same value as the bytes read from the source; the copy was discarded.'
        }
        $info = New-Object IO.FileInfo($Path)
        if ($info.Length -ne $bytes) {
            throw ('The source object changed length while it was being read (expected ' + $bytes + ' bytes, the source now reports ' + $info.Length + ').')
        }
        if ([IO.File]::Exists($destination)) { throw ('Refusing to overwrite an existing backup file: ' + $Entry.BackupRelativePath) }
        [IO.File]::Move($sibling,$destination)
        $Entry.Length = $bytes
        $Entry.Sha256 = $copiedHash
        $Entry.LastWriteUtc = $info.LastWriteTimeUtc.ToString('o')
        if ($info.Length -ne $bytes -or $info.LastWriteTimeUtc -ne (Get-Date $Entry.LastWriteUtc)) {
            $Entry.Error = 'Source object was modified while it was being copied; the stored copy is a live capture and may not match the source at any single instant.'
        }
    } finally {
        if ($hashAlgorithm) { try { $hashAlgorithm.Dispose() } catch { } }
        if ($source) { try { $source.Dispose() } catch { } }
        if ($target) { try { $target.Dispose() } catch { } }
        if ([IO.File]::Exists($sibling)) { try { [IO.File]::Delete($sibling) } catch { } }
    }
    return $bytes
}

function Invoke-PitrBackupSource {
    # One source root: build its inventory, copy every object, record the accounting.
    param($Source,$Manifest,$Job,$Log,$Scope,[string]$DestinationRoot,$Cancellation,$Progress,$Counters)
    $displayName = $Source.DisplayName
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = [string]$Source.Id }
    $backupPrefix = $script:PitrBackupProfilesFolder + '/' + $Source.Id
    if ($Source.Category -eq 'Extra') { $backupPrefix = $script:PitrBackupExtraFolder + '/' + $Source.Id }
    if ([IO.File]::Exists($Source.Path)) {
        $name = Split-Path $Source.Path -Leaf
        $entry = New-PitrBackupInventoryEntry -SourceId $Source.Id -RootPath $Source.Path -RelativePath $name `
            -BackupRelativePath ($backupPrefix + '/' + $name) -Type 'File' -Length 0 -LastWriteUtc $null `
            -Attributes $null -SourceVolumeId $Source.SourceVolumeId -ProfileSid $Source.ProfileSid -IsAdvanced $false -IsSensitive $false -Error $null
        $null = Invoke-PitrBackupInventoryFile -Source $Source -RootPath $Source.Path -Path $Source.Path -RelativePath $name `
            -BackupRelativePath ($backupPrefix + '/' + $name) -Manifest $Manifest -Job $Job -Log $Log `
            -DestinationRoot $DestinationRoot -Cancellation $Cancellation -Progress $Progress -Counters $Counters -Profile $displayName
        return
    }
    if (-not [IO.Directory]::Exists($Source.Path)) {
        $entry = New-PitrBackupInventoryEntry -SourceId $Source.Id -RootPath $Source.Path -RelativePath (Get-PitrBackupFileName -Path $Source.Path) `
            -BackupRelativePath ($backupPrefix + '/' + (Get-PitrBackupFileName -Path $Source.Path)) -Type 'Unsupported' -Length 0 -LastWriteUtc $null `
            -Attributes $null -SourceVolumeId $Source.SourceVolumeId -ProfileSid $Source.ProfileSid -IsAdvanced $false -IsSensitive $false `
            -Error ('Selected source folder is not readable on this computer: ' + $Source.Path)
        $entry.CopyStatus = 'Failed'
        $null = Set-PitrBackupEntry -Manifest $Manifest -Entry $entry
        $Counters.Failed = $Counters.Failed + 1
        Write-PitrBackupLog -Log $Log -Message ('FAILED ' + $entry.RelativePath + ' : ' + $entry.Error)
        return
    }
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push('')
    while ($stack.Count -gt 0) {
        if (Test-PitrBackupCancelled -Cancellation $Cancellation) {
            Write-PitrBackupLog -Log $Log -Message 'CANCELLED inventory stops; every object already inventoried is recorded and nothing is silently dropped from the accounting.'
            break
        }
        $relativeDirectory = $stack.Pop()
        $directoryPath = $Source.Path
        if ($relativeDirectory -ne '') { $directoryPath = Join-Path $Source.Path $relativeDirectory.Replace('/','\') }
        if ($relativeDirectory -ne '') {
            $type = Get-PitrBackupEntryType -Path $directoryPath -RelativePath $relativeDirectory -Attributes $null
            if ($type.Type -ne 'Directory') {
                # Never follow a directory reparse point during inventory.
                $entry = New-PitrBackupInventoryEntry -SourceId $Source.Id -RootPath $Source.Path -RelativePath $relativeDirectory `
                    -BackupRelativePath ($backupPrefix + '/' + $relativeDirectory) -Type $type.Type -Length 0 -LastWriteUtc $null -Attributes $null `
                    -SourceVolumeId $Source.SourceVolumeId -ProfileSid $Source.ProfileSid -IsSensitive (Test-PitrBackupSensitivePath -RelativePath $relativeDirectory) `
                    -IsAdvanced (Test-PitrAdvancedRelativePath -RelativePath $relativeDirectory) -Error $type.Error
                $entry.CopyStatus = 'Skipped'
                $entry.VerificationStatus = 'Pending'
                $null = Set-PitrBackupEntry -Manifest $Manifest -Entry $entry
                $Counters.Skipped = $Counters.Skipped + 1
                Write-PitrBackupLog -Log $Log -Message ('SKIPPED ' + $relativeDirectory + ' : ' + $type.Error)
                continue
            }
        }
        $children = $null
        try {
            $children = [IO.Directory]::GetFileSystemEntries($directoryPath)
        } catch {
            $entry = New-PitrBackupInventoryEntry -SourceId $Source.Id -RootPath $Source.Path -RelativePath $relativeDirectory `
                -BackupRelativePath ($backupPrefix + '/' + $relativeDirectory) -Type 'Unsupported' -Length 0 -LastWriteUtc $null -Attributes $null `
                -SourceVolumeId $Source.SourceVolumeId -ProfileSid $Source.ProfileSid -IsAdvanced $false -IsSensitive $false `
                -Error ('Folder contents could not be enumerated: ' + $_.Exception.Message)
            $entry.CopyStatus = 'Failed'
            $entry.Type = 'Unsupported'
            $null = Set-PitrBackupEntry -Manifest $Manifest -Entry $entry
            $Counters.Failed = $Counters.Failed + 1
            Write-PitrBackupLog -Log $Log -Message ('FAILED ' + $relativeDirectory + ' : ' + $entry.Error)
            continue
        }
        $names = New-Object 'Collections.Generic.List[string]'
        foreach ($child in $children) { $names.Add([IO.Path]::GetFileName($child)) }
        $sorted = $names.ToArray()
        [Array]::Sort($sorted,[StringComparer]::Ordinal)
        foreach ($name in $sorted) {
            if (Test-PitrBackupCancelled -Cancellation $Cancellation) { break }
            $relative = if ($relativeDirectory -eq '') { $name } else { $relativeDirectory + '/' + $name }
            $childPath = Join-Path $directoryPath $name
            $isDirectory = $false
            try { $isDirectory = [IO.Directory]::Exists($childPath) } catch { $isDirectory = $false }
            if ($isDirectory) {
                $type = Get-PitrBackupEntryType -Path $childPath -RelativePath $relative -Attributes $null
                if ($type.Type -eq 'Directory') {
                    $entry = New-PitrBackupInventoryEntry -SourceId $Source.Id -RootPath $Source.Path -RelativePath $relative `
                        -BackupRelativePath ($backupPrefix + '/' + $relative) -Type 'Directory' -Length 0 -LastWriteUtc $null -Attributes $null `
                        -SourceVolumeId $Source.SourceVolumeId -ProfileSid $Source.ProfileSid -IsSensitive (Test-PitrBackupSensitivePath -RelativePath $relative) `
                        -IsAdvanced (Test-PitrAdvancedRelativePath -RelativePath $relative) -Error $null
                    $entry.CopyStatus = 'Copied'
                    $null = Set-PitrBackupEntry -Manifest $Manifest -Entry $entry
                    $Counters.Copied = $Counters.Copied + 1
                    $directoryTarget = Join-Path $DestinationRoot $entry.BackupRelativePath
                    try {
                        if (-not [IO.Directory]::Exists($directoryTarget)) { $null = [IO.Directory]::CreateDirectory($directoryTarget) }
                    } catch {
                        $entry.CopyStatus = 'Failed'
                        $entry.Error = ('Backup folder could not be created: ' + $_.Exception.Message)
                        $Counters.Copied = $Counters.Copied - 1
                        $Counters.Failed = $Counters.Failed + 1
                        Write-PitrBackupLog -Log $Log -Message ('FAILED ' + $relative + ' : ' + $entry.Error)
                        continue
                    }
                    $stack.Push($relative)
                    continue
                }
                $entry = New-PitrBackupInventoryEntry -SourceId $Source.Id -RootPath $Source.Path -RelativePath $relative `
                    -BackupRelativePath ($backupPrefix + '/' + $relative) -Type $type.Type -Length 0 -LastWriteUtc $null -Attributes $null `
                    -SourceVolumeId $Source.SourceVolumeId -ProfileSid $Source.ProfileSid -IsSensitive (Test-PitrBackupSensitivePath -RelativePath $relative) `
                    -IsAdvanced (Test-PitrAdvancedRelativePath -RelativePath $relative) -Error $type.Error
                $entry.CopyStatus = 'Skipped'
                $null = Set-PitrBackupEntry -Manifest $Manifest -Entry $entry
                $Counters.Skipped = $Counters.Skipped + 1
                Write-PitrBackupLog -Log $Log -Message ('SKIPPED ' + $relative + ' : ' + $type.Error)
                continue
            }
            if (-not [IO.File]::Exists($childPath)) {
                $entry = New-PitrBackupInventoryEntry -SourceId $Source.Id -RootPath $Source.Path -RelativePath $relative `
                    -BackupRelativePath ($backupPrefix + '/' + $relative) -Type 'Unsupported' -Length 0 -LastWriteUtc $null -Attributes $null `
                    -SourceVolumeId $Source.SourceVolumeId -ProfileSid $Source.ProfileSid -IsSensitive (Test-PitrBackupSensitivePath -RelativePath $relative) `
                    -IsAdvanced (Test-PitrAdvancedRelativePath -RelativePath $relative) `
                    -Error 'Object is neither a readable file nor a folder, or it disappeared during inventory.'
                $entry.CopyStatus = 'Failed'
                $null = Set-PitrBackupEntry -Manifest $Manifest -Entry $entry
                $Counters.Failed = $Counters.Failed + 1
                Write-PitrBackupLog -Log $Log -Message ('FAILED ' + $relative + ' : ' + $entry.Error)
                continue
            }
            $entry = Invoke-PitrBackupInventoryFile -Source $Source -RootPath $Source.Path -Path $childPath -RelativePath $relative `
                -BackupRelativePath ($backupPrefix + '/' + $relative) -Manifest $Manifest -Job $Job -Log $Log `
                -DestinationRoot $DestinationRoot -Cancellation $Cancellation -Progress $Progress -Counters $Counters -Profile $displayName
        }
    }
}

function Invoke-PitrBackupInventoryFile {
    param($Source,[string]$RootPath,[string]$Path,[string]$RelativePath,[string]$BackupRelativePath,$Manifest,$Job,$Log,[string]$DestinationRoot,$Cancellation,$Progress,$Counters,[string]$Profile)
    $info = $null
    try { $info = New-Object IO.FileInfo($Path) } catch { $info = $null }
    $attributes = @()
    try { $attributes = @([IO.File]::GetAttributes($Path).ToString().Split(',').Trim()) } catch { $attributes = @() }
    $type = Get-PitrBackupEntryType -Path $Path -RelativePath $RelativePath -Attributes $attributes
    $entry = New-PitrBackupInventoryEntry -SourceId $Source.Id -RootPath $RootPath -RelativePath $RelativePath `
        -BackupRelativePath $BackupRelativePath -Type $type.Type -Length 0 -LastWriteUtc $null -Attributes ($attributes -join ',') `
        -SourceVolumeId $Source.SourceVolumeId -ProfileSid $Source.ProfileSid -IsSensitive (Test-PitrBackupSensitivePath -RelativePath $RelativePath) `
        -IsAdvanced (Test-PitrAdvancedRelativePath -RelativePath $RelativePath) -Error $type.Error
    if ($type.Type -ne 'File') {
        $entry.CopyStatus = 'Skipped'
        $null = Set-PitrBackupEntry -Manifest $Manifest -Entry $entry
        $Counters.Skipped = $Counters.Skipped + 1
        Write-PitrBackupLog -Log $Log -Message ('SKIPPED ' + $RelativePath + ' (' + $type.Type + ') : ' + $type.Error)
        return $entry
    }
    if ($null -eq $info -or -not $info.Exists) {
        $entry.Type = 'Unsupported'
        $entry.CopyStatus = 'Failed'
        $entry.Error = 'File disappeared or became unreadable during inventory.'
        $null = Set-PitrBackupEntry -Manifest $Manifest -Entry $entry
        $Counters.Failed = $Counters.Failed + 1
        Write-PitrBackupLog -Log $Log -Message ('FAILED ' + $RelativePath + ' : ' + $entry.Error)
        return $entry
    }
    $entry.Length = $info.Length
    $entry.LastWriteUtc = $info.LastWriteTimeUtc.ToString('o')
    $entry.CopyStatus = 'Pending'
    $null = Set-PitrBackupEntry -Manifest $Manifest -Entry $entry
    $Counters.Expected = $Counters.Expected + 1
    $Job.CurrentRelativePath = $RelativePath
    Invoke-PitrBackupProgress -Progress $Progress -Phase 'Copy' -Profile $Profile -File $RelativePath -FilesProcessed $Counters.Copied -BytesProcessed $Counters.Bytes -TotalBytes $Job.TotalBytes -ErrorCount $Counters.Failed
    try {
        $copied = Invoke-PitrBackupEntry -Entry $entry -Path $Path -DestinationRoot $DestinationRoot -Job $Job -Log $Log `
            -Cancellation $Cancellation -BytesProcessed $Counters.Bytes -TotalBytes $Job.TotalBytes -ErrorCount $Counters.Failed `
            -Index $Counters.Copied -Total $Counters.Expected -Profile $Profile -Progress $Progress
        $entry.CopyStatus = 'Copied'
        $entry.Length = $copied
        $Counters.Copied = $Counters.Copied + 1
        $Counters.Bytes = $Counters.Bytes + $copied
        if ($entry.Error) {
            Write-PitrBackupLog -Log $Log -Message ('COPIED ' + $RelativePath + ' with warning: ' + $entry.Error)
        }
    } catch [System.OperationCanceledException] {
        $entry.CopyStatus = 'Pending'
        $entry.VerificationStatus = 'Pending'
        $entry.Error = $_.Exception.Message
        $Counters.Cancelled = $true
        Write-PitrBackupLog -Log $Log -Message ('CANCELLED ' + $RelativePath + ' : ' + $entry.Error)
        Invoke-PitrBackupProgress -Progress $Progress -Phase 'Cancelled' -Profile $Profile -File $RelativePath -FilesProcessed $Counters.Copied -BytesProcessed $Counters.Bytes -TotalBytes $Job.TotalBytes -ErrorCount $Counters.Failed
        throw
    } catch {
        $entry.CopyStatus = 'Failed'
        $entry.Error = $_.Exception.Message
        $Counters.Failed = $Counters.Failed + 1
        Write-PitrBackupLog -Log $Log -Message ('FAILED ' + $RelativePath + ' : ' + $_.Exception.Message)
        Invoke-PitrBackupProgress -Progress $Progress -Phase 'Copy' -Profile $Profile -File $RelativePath -FilesProcessed $Counters.Copied -BytesProcessed $Counters.Bytes -TotalBytes $Job.TotalBytes -ErrorCount $Counters.Failed
    }
    return $entry
}

function Write-PitrBackupAccounting {
    # Every selected object must be accounted for. A mismatch is recorded loudly and prevents a
    # CopyCompleted claim rather than being hidden.
    param($Manifest,$Log)
    $entries = @($Manifest.Entries)
    $unaccounted = New-Object 'Collections.Generic.List[string]'
    foreach ($entry in $entries) {
        if ($entry.CopyStatus -notin @('Copied','Skipped','Failed')) { $unaccounted.Add($entry.RelativePath) }
    }
    if ($unaccounted.Count -gt 0) {
        $message = 'Accounting incomplete: ' + $unaccounted.Count + ' selected object(s) have no copy outcome.'
        Write-PitrBackupLog -Log $Log -Message ('WARNING ' + $message)
        $Manifest.Warnings = @($Manifest.Warnings) + ,$message
        return $false
    }
    $copied = @($entries | Where-Object { $_.CopyStatus -eq 'Copied' }).Count
    $skipped = @($entries | Where-Object { $_.CopyStatus -eq 'Skipped' }).Count
    $failed = @($entries | Where-Object { $_.CopyStatus -eq 'Failed' }).Count
    Write-PitrBackupLog -Log $Log -Message ('Accounting: ' + $entries.Count + ' selected object(s) = ' + $copied + ' copied, ' + $skipped + ' skipped, ' + $failed + ' failed.')
    return $true
}

function New-PitrBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Sources,
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$false)][ValidateSet('Complete','Personal','Custom')][string]$Scope='Complete',
        [Parameter(Mandatory=$false)][scriptblock]$Progress=$null,
        [Parameter(Mandatory=$false)]$Cancellation=$null,
        [Parameter(Mandatory=$false)][string]$RecoverySource=$null
    )
    Initialize-PitrBackupTestHooks
    $scopeValue = $Scope
    $sourceList = @()
    foreach ($source in $Sources) {
        if ($null -eq $source) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$source.Id)) { throw (ConvertTo-PitrArgumentException 'A selected source has no stable id; refusing to guess which object is being backed up.') }
        if ([string]::IsNullOrWhiteSpace([string]$source.Path)) { throw (ConvertTo-PitrArgumentException ('Selected source has no path: ' + [string]$source.Id)) }
        $sourceList += ,$source
    }
    if ($sourceList.Count -eq 0) { throw (ConvertTo-PitrArgumentException 'A backup requires at least one selected source object.') }
    $requiredBytes = 0
    foreach ($source in $sourceList) {
        if ([IO.File]::Exists([string]$source.Path)) {
            try { $requiredBytes = $requiredBytes + (New-Object IO.FileInfo([string]$source.Path)).Length } catch { }
        }
    }
    # Windows-only destination/source validation lives in Platform.ps1; it is never re-implemented
    # or bypassed here.
    $identity = Test-PitrDestination -Destination $Destination -Sources ([string[]]@($sourceList | ForEach-Object { [string]$_.Path })) -RequiredBytes $requiredBytes
    $root = Get-PitrBackupDestinationRoot -Destination $Destination
    $computer = Get-PitrBackupComputerIdentity
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $token = New-PitrBackupToken
    $parent = Join-Path $root $computer
    if (-not [IO.Directory]::Exists($parent)) { $null = [IO.Directory]::CreateDirectory($parent) }
    $generationPath = Get-PitrBackupUniqueDirectory -Parent $parent -Stamp $stamp -Token $token
    $null = [IO.Directory]::CreateDirectory($generationPath)
    $manifestPath = Join-Path $generationPath $script:PitrBackupManifestName
    $logPath = Join-Path $generationPath $script:PitrBackupLogFileName
    $statusPath = Join-Path $generationPath $script:PitrBackupStateFileName
    $backupId = [guid]::NewGuid().ToString()
    $manifest = New-PitrManifest -BackupId $backupId -Scope $scopeValue -ApplicationVersion (Get-PitrBackupApplicationVersion -RecoverySource $RecoverySource) -ComputerIdentity $computer
    $manifest.Sources = @($sourceList)
    $manifest.DestinationIdentity = [pscustomobject]@{
        VolumeId=$identity.VolumeId
        Kind=$identity.Kind
        CanonicalPath=$identity.CanonicalPath
        FileSystem=$identity.FileSystem
        Warnings=@($identity.Warnings)
        BackupRoot=$root
    }
    $log = New-PitrBackupLog -GenerationPath $generationPath -BackupId $manifest.BackupId
    $counters = [pscustomobject]@{ Expected=0; Copied=0; Skipped=0; Failed=0; Bytes=0; Cancelled=$false }
    $job = New-PitrBackupJob -GenerationPath $generationPath -ManifestPath $manifestPath -LogPath $logPath -StatusPath $statusPath -Root $root -TotalBytes $requiredBytes
    Write-PitrBackupLog -Log $log -Message ('Consistency: ' + $manifest.Consistency + '. This is a live file copy. No VSS snapshot was created and no application or database consistency is claimed.')
    foreach ($warning in @($identity.Warnings)) { $manifest.Warnings = @($manifest.Warnings) + ,$warning; Write-PitrBackupLog -Log $log -Message ('WARNING ' + $warning) }
    $null = Write-PitrManifest -ManifestPath $manifestPath -Manifest $manifest
    $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'Starting' -State 'Running' -Counts $null -ErrorCount 0 -CancellationReason $null -Message 'Backup started.'
    $manifest = Set-PitrManifestState -Manifest $manifest -State 'Running'
    $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $manifestPath -Force
    $null = Write-PitrManifest -ManifestPath $manifestPath -Manifest $manifest
    Write-PitrBackupLog -Log $log -Message ('Backup ' + $backupId + ' planned under ' + $generationPath)
    Invoke-PitrBackupProgress -Progress $Progress -Phase 'Starting' -Profile $null -File $null -FilesProcessed 0 -BytesProcessed 0 -TotalBytes $requiredBytes -ErrorCount 0
    $cancelled = $false
    try {
        foreach ($source in $sourceList) {
            if (Test-PitrBackupCancelled -Cancellation $Cancellation) { $cancelled = $true; break }
            Write-PitrBackupLog -Log $log -Message ('Source ' + $source.Id + ' (' + $source.Category + '): ' + $source.Path)
            foreach ($warning in @($source.Warnings)) { $manifest.Warnings = @($manifest.Warnings) + ,('Source ' + $source.Id + ': ' + [string]$warning) }
            $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'Copy' -State 'Running' -Counts (Get-PitrManifestCounts $manifest) -ErrorCount $counters.Failed -CancellationReason $null -Message ('Copying ' + [string]$source.DisplayName)
            Invoke-PitrBackupSource -Source $source -Manifest $manifest -Job $job -Log $log -Scope $scopeValue -DestinationRoot $generationPath `
                -Cancellation $Cancellation -Progress $Progress -Counters $counters -TotalFiles $sourceList.Count
            $null = Write-PitrManifest -ManifestPath $manifestPath -Manifest $manifest
            $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'Copy' -State 'Running' -Counts (Get-PitrManifestCounts $manifest) -ErrorCount $counters.Failed -CancellationReason $null -Message 'Copy in progress.'
        }
    } catch [System.OperationCanceledException] {
        $cancelled = $true
    }
    if (Test-PitrBackupCancelled -Cancellation $Cancellation) { $cancelled = $true }
    if ($cancelled) {
        $manifest.State = $manifest.State
        Write-PitrBackupLog -Log $log -Message 'Cancellation requested: finished objects are kept as they are, unfinished files were removed, and the generation stays Interrupted.'
        $manifest = Set-PitrManifestState -Manifest $manifest -State 'Interrupted'
        $manifest.Exclusions = @($manifest.Exclusions) + ,[pscustomobject]@{ Kind='Cancelled'; SourceId=$null; Path=$log.CurrentRelativePath; Reason='The operator cancelled the run.' }
        $null = Write-PitrManifest -ManifestPath $manifestPath -Manifest $manifest
        $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'Interrupted' -State 'Interrupted' -Counts (Get-PitrManifestCounts $manifest) -ErrorCount $counters.Failed -CancellationReason 'Cancelled by the caller.' -Message 'The backup was cancelled. Run backup resume to continue it.'
        Invoke-PitrBackupProgress -Progress $Progress -Phase 'Interrupted' -Profile $null -File $log.CurrentRelativePath -FilesProcessed $counters.Copied -BytesProcessed $counters.Bytes -TotalBytes $job.TotalBytes -ErrorCount $counters.Failed
        Close-PitrBackupLog -Log $log
        $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $manifestPath -Force
        return $manifest
    }
    $null = Write-PitrBackupAccounting -Manifest $manifest -Log $log
    $counts = Get-PitrManifestCounts $manifest
    if ($counts.Skipped -gt 0 -or $counts.Failed -gt 0) {
        $message = 'Copy finished with unaccounted success: ' + $counts.Skipped + ' skipped and ' + $counts.Failed + ' failed object(s) are visible in the manifest and forbid a strong success state.'
        $manifest.Warnings = @($manifest.Warnings) + ,$message
        Write-PitrBackupLog -Log $log -Message ('WARNING ' + $message)
    }
    $manifest = Set-PitrManifestState -Manifest $manifest -State 'CopyCompleted'
    Write-PitrBackupLog -Log $log -Message ('Copy completed: ' + $counts.Copied + ' copied, ' + $counts.Skipped + ' skipped, ' + $counts.Failed + ' failed, ' + $counts.Bytes + ' bytes. Consistency remains LiveNotApplicationConsistent.')
    if (-not [string]::IsNullOrWhiteSpace($RecoverySource)) {
        $manifest.RecoveryPackage = Install-PitrRecoveryPackage -BackupRoot $generationPath -RecoverySource $RecoverySource -Manifest $manifest
        if ($manifest.RecoveryPackage -and $manifest.RecoveryPackage.Installed) {
            Write-PitrBackupLog -Log $log -Message ('Recovery package installed: ' + $manifest.RecoveryPackage.FileCount + ' file(s), inventory sha256 ' + $manifest.RecoveryPackage.InventorySha256)
        } else {
            $reason = if ($manifest.RecoveryPackage) { [string]$manifest.RecoveryPackage.Error } else { 'Recovery package was not installed.' }
            $manifest.Warnings = @($manifest.Warnings) + ,('Recovery package incomplete: ' + $reason)
            Write-PitrBackupLog -Log $log -Message ('WARNING recovery package incomplete: ' + $reason)
        }
    }
    $null = Write-PitrManifest -ManifestPath $manifestPath -Manifest $manifest
    $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'CopyCompleted' -State 'CopyCompleted' -Counts (Get-PitrManifestCounts $manifest) -ErrorCount $counts.Failed -CancellationReason $null -Message 'Copy finished. Verification has not run yet, so this generation is not Verified.'
    Invoke-PitrBackupProgress -Progress $Progress -Phase 'CopyCompleted' -Profile $null -File $null -FilesProcessed $counts.Copied -BytesProcessed $counts.Bytes -TotalBytes $job.TotalBytes -ErrorCount $counts.Failed
    Close-PitrBackupLog -Log $log
    $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $manifestPath -Force
    return $manifest
}

function Resume-PitrBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ManifestPath,
        [Parameter(Mandatory=$false)][scriptblock]$Progress=$null,
        [Parameter(Mandatory=$false)]$Cancellation=$null
    )
    Initialize-PitrBackupTestHooks
    $manifest = Read-PitrManifest -ManifestPath $ManifestPath
    if ($manifest.State -eq 'Verified') {
        throw ('Refusing to resume generation ' + $manifest.BackupId + ': it is Verified and must not be mutated.')
    }
    if ($manifest.State -eq 'Failed') {
        throw ('Refusing to resume generation ' + $manifest.BackupId + ': it failed. Start a new backup instead of mutating a failed generation.')
    }
    if ($manifest.State -notin @('Running','Interrupted')) {
        throw ('Generation ' + $manifest.BackupId + ' is state ' + $manifest.State + '; resume only continues a Running or Interrupted generation.')
    }
    $generationPath = Split-Path $ManifestPath -Parent
    # The copy destination is proven from the location the manifest was actually loaded from,
    # never trusted from manifest text.
    $fullManifest = [IO.Path]::GetFullPath($ManifestPath)
    $recordedManifest = $null
    if ($manifest.PSObject.Properties['DestinationIdentity'] -and $manifest.DestinationIdentity) {
        $recordedManifest = [string]$manifest.DestinationIdentity.BackupRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($recordedManifest)) {
        $recordedRoot = [IO.Path]::GetFullPath($recordedManifest)
        if ($recordedRoot -ne $generationPath -and -not $fullManifest.StartsWith($recordedRoot,[StringComparison]::OrdinalIgnoreCase)) {
            throw ('The manifest records a different backup root (' + $recordedManifest + ') than the folder it was loaded from (' + $generationPath + '); refusing to copy anywhere else.')
        }
    }
    $log = New-PitrBackupLog -GenerationPath $generationPath -BackupId $manifest.BackupId
    Write-PitrBackupLog -Log $log -Message ('Resume requested for generation ' + $manifest.BackupId + ' from state ' + $manifest.State + '.')
    # Safety validation is a gate, not a best-effort warning. A moved generation must
    # still be on approved storage before any mutation, irrespective of manifest identity.
    $identity = Test-PitrDestination -Destination $generationPath -Sources ([string[]]@($manifest.Sources | ForEach-Object { [string]$_.Path })) -RequiredBytes 0
    $counters = [pscustomobject]@{ Expected=0; Copied=0; Skipped=0; Failed=0; Bytes=0; Cancelled=$false }
    $logPath = Join-Path $generationPath $script:PitrBackupLogFileName
    $statusPath = Join-Path $generationPath $script:PitrBackupStateFileName
    $job = New-PitrBackupJob -GenerationPath $generationPath -ManifestPath $fullManifest -LogPath $logPath -StatusPath $statusPath -Root (Split-Path $generationPath -Parent) -TotalBytes 0
    $entries = @($manifest.Entries)
    # Phase 1: re-validate everything the old manifest claims was copied. The old manifest is
    # evidence to be checked, never a statement to be trusted.
    $invalidated = New-Object 'Collections.Generic.List[object]'
    $checked = 0
    foreach ($entry in $entries) {
        if (Test-PitrBackupCancelled -Cancellation $Cancellation) { break }
        if ($entry.CopyStatus -ne 'Copied') { continue }
        $checked = $checked + 1
        $destination = Join-Path $generationPath $entry.BackupRelativePath
        $problem = $null
        if ($entry.Type -eq 'Directory') {
            if (-not [IO.Directory]::Exists($destination)) { $problem = 'Recorded backup folder is missing.' }
        } elseif (-not [IO.File]::Exists($destination)) {
            $problem = 'Recorded backup file is missing.'
        } else {
            $info = New-Object IO.FileInfo($destination)
            if ($info.Length -ne [int64]$entry.Length) {
                $problem = 'Recorded backup file length changed (' + $info.Length + ' bytes on disk, ' + $entry.Length + ' recorded).'
            } elseif ($entry.Sha256) {
                $actual = Get-PitrHash -Path $destination
                if ($actual -ne $entry.Sha256) { $problem = 'Recorded backup hash no longer matches the stored bytes.' }
            } elseif ($checked -le 0) {
                $problem = $null
            } else {
                $problem = 'Recorded backup file has no hash to validate.'
            }
        }
        if ($problem) {
            $entry.CopyStatus = 'Pending'
            $entry.VerificationStatus = 'Pending'
            $entry.Sha256 = $null
            $entry.Error = 'Re-validation on resume: ' + $problem
            $invalidated.Add($entry)
            Write-PitrBackupLog -Log $log -Message ('REVALIDATE ' + $entry.RelativePath + ' : ' + $problem + ' It will be copied again.')
        }
        if (($checked % $script:PitrBackupProgressEveryFiles) -eq 0) {
            Invoke-PitrBackupProgress -Progress $Progress -Phase 'Revalidate' -Profile $null -File $entry.RelativePath -FilesProcessed $checked -BytesProcessed 0 -TotalBytes 0 -ErrorCount 0
        }
    }
    Invoke-PitrBackupProgress -Progress $Progress -Phase 'Revalidate' -Profile $null -File $null -FilesProcessed $checked -BytesProcessed 0 -TotalBytes 0 -ErrorCount 0
    Write-PitrBackupLog -Log $log -Message ('Re-validated ' + $checked + ' previously copied object(s); ' + $invalidated.Count + ' must be copied again.')
    if ($manifest.State -eq 'Interrupted') {
        $manifest = Set-PitrManifestState -Manifest $manifest -State 'Running'
        $null = Write-PitrManifest -ManifestPath $fullManifest -Manifest $manifest
    }
    # Re-enumerate ALL source trees. An interrupted inventory is not a complete list.
    # Retain old payload bytes, but construct fresh accounting for the complete current scope.
    $previous=@($manifest.Entries)
    $manifest.Entries=@()
    $job | Add-Member -NotePropertyName ResumeInventory -NotePropertyValue $true -Force
    $cancelled=$false
    try {
        foreach($source in @($manifest.Sources)) {
            if(Test-PitrBackupCancelled -Cancellation $Cancellation) { $cancelled=$true; break }
            Invoke-PitrBackupSource -Source $source -Manifest $manifest -Job $job -Log $log -Scope $manifest.Scope -DestinationRoot $generationPath -Cancellation $Cancellation -Progress $Progress -Counters $counters
        }
    } catch [System.OperationCanceledException] { $cancelled=$true }
    $seen=@{}
    foreach($item in @($manifest.Entries)) { $seen[$item.SourceId+'|'+$item.RelativePath]=$true }
    foreach($item in $previous) {
        if(-not $seen.ContainsKey($item.SourceId+'|'+$item.RelativePath)) {
            # A previous selected object disappeared or has not yet been scanned. Preserve
            # both its record and payload; never call the new inventory complete for it.
            $item.CopyStatus='Failed'
            $item.VerificationStatus='Pending'
            $item.Error='Previous selected object was not reached during resumed source inventory.'
            $manifest.Entries=@($manifest.Entries)+,$item
        }
    }
    if (Test-PitrBackupCancelled -Cancellation $Cancellation) { $cancelled = $true }
    if ($cancelled) {
        $manifest = Set-PitrManifestState -Manifest $manifest -State 'Interrupted'
        $null = Write-PitrManifest -ManifestPath $fullManifest -Manifest $manifest
        $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'Interrupted' -State 'Interrupted' -Counts (Get-PitrManifestCounts $manifest) -ErrorCount $counters.Failed -CancellationReason 'Cancelled by the caller.' -Message 'Resume was cancelled.'
        Close-PitrBackupLog -Log $log
        $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $fullManifest -Force
        return $manifest
    }
    $null = Write-PitrBackupAccounting -Manifest $manifest -Log $log
    $counts = Get-PitrManifestCounts $manifest
    if ($counts.Skipped -gt 0 -or $counts.Failed -gt 0) {
        $manifest.Warnings = @($manifest.Warnings) + ,('Resume finished with ' + $counts.Skipped + ' skipped and ' + $counts.Failed + ' failed object(s).')
    }
    $manifest = Set-PitrManifestState -Manifest $manifest -State 'CopyCompleted'
    $null = Write-PitrManifest -ManifestPath $fullManifest -Manifest $manifest
    $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'CopyCompleted' -State 'CopyCompleted' -Counts (Get-PitrManifestCounts $manifest) -ErrorCount $counts.Failed -CancellationReason $null -Message 'Resume finished the copy. Verification has not run yet.'
    Invoke-PitrBackupProgress -Progress $Progress -Phase 'CopyCompleted' -Profile $null -File $null -FilesProcessed $counts.Copied -BytesProcessed $counts.Bytes -TotalBytes $job.TotalBytes -ErrorCount $counts.Failed
    Close-PitrBackupLog -Log $log
    $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $fullManifest -Force
    return $manifest
}

function Test-PitrBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ManifestPath,
        [Parameter(Mandatory=$false)][ValidateSet('Quick','Full')][string]$Mode='Full',
        [Parameter(Mandatory=$false)][scriptblock]$Progress=$null,
        [Parameter(Mandatory=$false)]$Cancellation=$null
    )
    Initialize-PitrBackupTestHooks
    $manifest = Read-PitrManifest -ManifestPath $ManifestPath
    if ($manifest.State -in @('Planned','Failed')) {
        throw ('Generation ' + $manifest.BackupId + ' is state ' + $manifest.State + '; verification only runs on a generation whose copy finished.')
    }
    # No early return for an already Verified generation: verification is the one thing
    # that can still discover that the payload changed after the backup finished, so it
    # always re-reads the recorded objects and re-derives the state.
    if ($manifest.State -notin @('CopyCompleted','Interrupted','Verifying','CompletedWithWarnings','Verified')) {
        throw ('Generation ' + $manifest.BackupId + ' cannot be verified from state ' + $manifest.State + '.')
    }
    $generationPath = Split-Path $ManifestPath -Parent
    $fullManifestPath = [IO.Path]::GetFullPath($ManifestPath)
    $log = New-PitrBackupLog -GenerationPath $generationPath -BackupId $manifest.BackupId
    $statusPath = Join-Path $generationPath $script:PitrBackupStateFileName
    Write-PitrBackupLog -Log $log -Message ('Verification started in ' + $Mode + ' mode. Integrity is not application consistency: the source view is ' + $manifest.SourceView + ' and consistency is ' + $manifest.Consistency + '.')
    if ($manifest.State -ne 'Verifying') {
        try {
            $manifest = Set-PitrManifestState -Manifest $manifest -State 'Verifying'
            $null = Write-PitrManifest -ManifestPath $fullManifestPath -Manifest $manifest
        } catch {
            # Never silent: if the in-progress state cannot be recorded, say so in the log and
            # continue, so the pass still produces a truthful final state instead of a swallowed error.
            Write-PitrBackupLog -Log $log -Message ('WARNING could not mark the generation as Verifying: ' + $_.Exception.Message)
        }
    }
    $entries = @($manifest.Entries)
    $failed = 0
    $verified = 0
    $quick = 0
    $skipped = 0
    $cancelled = $false
    $index = 0
    $expectedStatus = if ($Mode -eq 'Full') { 'FullVerified' } else { 'QuickVerified' }
    foreach ($entry in $entries) {
        if (Test-PitrBackupCancelled -Cancellation $Cancellation) { $cancelled = $true; break }
        if ($entry.CopyStatus -eq 'Skipped') { $skipped = $skipped + 1; continue }
        if ($entry.CopyStatus -eq 'Failed') { $entry.VerificationStatus = 'Failed'; $failed = $failed + 1; continue }
        if ($entry.CopyStatus -ne 'Copied') { continue }
        $index = $index + 1
        $destination = Join-Path $generationPath $entry.BackupRelativePath
        $problem = $null
        $hash = $null
        if ($entry.Type -eq 'Directory') {
            if (-not [IO.Directory]::Exists($destination)) { $problem = 'Recorded backup folder is missing.' }
        } elseif (-not [IO.File]::Exists($destination)) {
            $problem = 'Recorded backup file is missing.'
        } else {
            $info = New-Object IO.FileInfo($destination)
            if ($info.Length -ne [int64]$entry.Length) {
                $problem = 'Backup file length does not match the manifest (' + $info.Length + ' bytes on disk, ' + $entry.Length + ' recorded).'
            } else {
                $hash = Get-PitrHash -Path $destination
                if (-not $entry.Sha256) {
                    $problem = 'Manifest entry has no recorded hash.'
                } elseif ($Mode -eq 'Full') {
                    if ($hash -ne $entry.Sha256) { $problem = 'Backup hash does not match the manifest; the stored bytes are not what the backup recorded.' }
                } elseif ($entry.VerificationStatus -eq 'FullVerified') {
                    # A quick pass never downgrades a file that a full pass has already proven.
                    $quick = $quick + 1
                    continue
                } else {
                    if ($hash -ne $entry.Sha256) { $problem = 'Backup hash does not match the manifest.' }
                }
            }
        }
        if ($problem) {
            if ($entry.VerificationStatus -ne 'FullVerified' -or $Mode -eq 'Full') { $entry.VerificationStatus = 'Failed' }
            $entry.Error = 'Verification: ' + $problem
            $failed = $failed + 1
            Write-PitrBackupLog -Log $log -Message ('FAILED verify ' + $entry.RelativePath + ' : ' + $problem)
        } else {
            if ($Mode -eq 'Full') { $entry.VerificationStatus = 'FullVerified' } else { $entry.VerificationStatus = 'QuickVerified' }
            if ($hash) { $entry.Sha256 = $hash }
            $verified = $verified + 1
            if ($Mode -eq 'Quick') { $quick = $quick + 1 }
        }
        Invoke-PitrBackupProgress -Progress $Progress -Phase 'Verify' -Profile $null -File $entry.RelativePath -FilesProcessed $index -BytesProcessed 0 -TotalBytes 0 -ErrorCount $failed
        if (($index % $script:PitrBackupProgressEveryFiles) -eq 0) {
            $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'Verify' -State 'Verifying' -Counts (Get-PitrManifestCounts $manifest) -ErrorCount $failed -CancellationReason $null -Message 'Verification in progress.'
        }
    }
    if ($cancelled) {
        Write-PitrBackupLog -Log $log -Message 'Verification was cancelled; the state stays Verifying so the pass can be restarted.'
        $null = Write-PitrManifest -ManifestPath $fullManifestPath -Manifest $manifest
        $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'Verify' -State 'Verifying' -Counts (Get-PitrManifestCounts $manifest) -ErrorCount $failed -CancellationReason 'Cancelled by the caller.' -Message 'Verification was cancelled and can be restarted.'
        Close-PitrBackupLog -Log $log
        $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $fullManifestPath -Force
        return $manifest
    }
    $counts = Get-PitrManifestCounts $manifest
    $state = Get-PitrBackupVerificationState -Manifest $manifest -Counts $counts -Mode $Mode
    $manifest = Set-PitrManifestState -Manifest $manifest -State $state
    if ($state -ne 'Verified') {
        $message = 'Verification finished in ' + $Mode + ' mode with ' + $counts.Skipped + ' skipped and ' + $counts.Failed + ' failed object(s); the strongest state is refused while any selected object is unaccounted for or failed.'
        $manifest.Warnings = @($manifest.Warnings) + ,$message
        Write-PitrBackupLog -Log $log -Message ('WARNING ' + $message)
    }
    $null = Write-PitrManifest -ManifestPath $fullManifestPath -Manifest $manifest
    $null = Set-PitrBackupStatusFile -Log $log -Path $statusPath -Phase 'Verify' -State $state -Counts (Get-PitrManifestCounts $manifest) -ErrorCount $failed -CancellationReason $null -Message ('Verification finished in ' + $Mode + ' mode. Integrity is not application consistency.')
    Write-PitrBackupLog -Log $log -Message ('Verification finished in ' + $Mode + ' mode: state ' + $state + ', ' + $counts.Copied + ' copied, ' + $counts.Failed + ' failed, ' + $counts.Skipped + ' skipped.')
    Invoke-PitrBackupProgress -Progress $Progress -Phase 'Verified' -Profile $null -File $null -FilesProcessed $index -BytesProcessed 0 -TotalBytes 0 -ErrorCount $failed
    Close-PitrBackupLog -Log $log
    $manifest | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $fullManifestPath -Force
    return $manifest
}

function Get-PitrBackupVerificationState {
    # Strongest success is refused unless every selected object is accounted for and every copied
    # file passed the verification mode that ran.
    param($Manifest,$Counts,[string]$Mode)
    $entries = @($Manifest.Entries)
    if ($entries.Count -eq 0) { return 'CompletedWithWarnings' }
    if ($Counts.Skipped -gt 0 -or $Counts.Failed -gt 0) { return 'CompletedWithWarnings' }
    foreach ($entry in $entries) {
        if ($entry.CopyStatus -eq 'Copied' -and $entry.VerificationStatus -notin @('QuickVerified','FullVerified')) { return 'CompletedWithWarnings' }
    }
    if ($Counts.Verified -ne $Counts.Copied) { return 'CompletedWithWarnings' }
    if ($Mode -eq 'Quick') { return 'CompletedWithWarnings' }
    foreach ($entry in $entries) {
        if ($entry.CopyStatus -eq 'Copied' -and $entry.VerificationStatus -ne 'FullVerified') { return 'CompletedWithWarnings' }
    }
    return 'Verified'
}

function Install-PitrRecoveryPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$BackupRoot,
        [Parameter(Mandatory=$true)][string]$RecoverySource,
        [Parameter(Mandatory=$false)]$Manifest=$null
    )
    # Trusted application-owned code only. The caller passes the application source root, never a
    # user-selected source folder, and nothing from the backed-up user data is ever copied here.
    $result = [pscustomobject]@{
        Installed=$false
        Path=$null
        FileCount=0
        Files=@()
        InventorySha256=$null
        Error=$null
        RecoverySource=$RecoverySource
        Launcher='Start-Recovery.cmd'
    }
    if ([string]::IsNullOrWhiteSpace($BackupRoot) -or [string]::IsNullOrWhiteSpace($RecoverySource)) {
        $result.Error = 'A recovery package requires both the backup generation folder and the trusted application source root.'
        return $result
    }
    if (-not [IO.Directory]::Exists($BackupRoot)) {
        $result.Error = ('Backup generation folder does not exist: ' + $BackupRoot)
        return $result
    }
    if (-not [IO.Directory]::Exists($RecoverySource)) {
        $result.Error = 'The trusted application source root is not available on this computer, so a usable recovery package cannot be produced.'
        return $result
    }
    $recovery = Join-Path $BackupRoot $script:PitrBackupRecoveryFolder
    $moduleNames = @('Platform.ps1','Manifest.ps1','Backup.ps1','Recovery.ps1','Cli.ps1','Entry.ps1','Localization.ps1','Ui.ps1')
    foreach ($name in $moduleNames) {
        $candidate = Join-Path (Join-Path $RecoverySource 'src/backup') $name
        if (-not [IO.File]::Exists($candidate)) {
            $result.Error = ('The trusted application source root is missing src/backup/' + $name + '; refusing to report a usable recovery package because recovery would not run without it.')
            return $result
        }
    }
    try {
        if (-not [IO.Directory]::Exists($recovery)) { $null = [IO.Directory]::CreateDirectory($recovery) }
        $inventory = New-Object 'Collections.Generic.List[object]'
        $moduleRoot=Join-Path $recovery 'src/backup'
        $null=[IO.Directory]::CreateDirectory($moduleRoot)
        foreach ($name in $moduleNames) {
            $source = Join-Path (Join-Path $RecoverySource 'src/backup') $name
            $target = Join-Path $moduleRoot $name
            if ([IO.File]::Exists($target)) {
                $result.Error = ('Refusing to overwrite an existing recovery file: ' + $target)
                return $result
            }
            Copy-PitrRecoveryFile -Source $source -Target $target
            $inventory.Add([pscustomobject]@{ Path=('src/backup/'+$name); Length=([IO.FileInfo]$target).Length; Sha256=(Get-PitrHash -Path $target) })
        }
        $launcherPath = Join-Path $recovery 'Start-Recovery.cmd'
        $readmePath = Join-Path $recovery 'README.txt'
        if ([IO.File]::Exists($launcherPath) -or [IO.File]::Exists($readmePath)) {
            $result.Error = 'Refusing to overwrite an existing recovery launcher or readme.'
            return $result
        }
        [IO.File]::WriteAllText($launcherPath, (Get-PitrRecoveryLauncherText), (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($readmePath, (Get-PitrRecoveryReadmeText), (New-Object Text.UTF8Encoding($false)))
        $inventory.Add([pscustomobject]@{ Path='Start-Recovery.cmd'; Length=([IO.FileInfo]$launcherPath).Length; Sha256=(Get-PitrHash -Path $launcherPath) })
        $inventory.Add([pscustomobject]@{ Path='README.txt'; Length=([IO.FileInfo]$readmePath).Length; Sha256=(Get-PitrHash -Path $readmePath) })
        $applicationVersion = $null
        if ($Manifest -and $Manifest.PSObject.Properties['ApplicationVersion']) { $applicationVersion = $Manifest.ApplicationVersion }
        $metadata = [pscustomobject]@{
            SchemaVersion=1
            PackageName='PITR recovery package'
            ApplicationVersion=$applicationVersion
            CreatedUtc=(Get-Date).ToUniversalTime().ToString('o')
            BackupId=if ($Manifest) { $Manifest.BackupId } else { $null }
            SourceView='Live'
            Consistency='LiveNotApplicationConsistent'
            FileCount=$inventory.Count
            Files=$inventory.ToArray()
            Note='Integrity inventory only. It is not a digital signature: an attacker who can change the recovery files can change this inventory too. Keep the trusted application source.'
        }
        $metadataPath = Join-Path $recovery 'recovery-integrity.json'
        [IO.File]::WriteAllText($metadataPath, ($metadata | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $result.Installed=$true
        $result.Path=$recovery
        $result.Files=$inventory.ToArray()
        $result.FileCount=$inventory.Count
        $result.InventorySha256=(Get-PitrHash -Path $metadataPath)
    } catch {
        $result.Installed=$false
        $result.Error=('Recovery package could not be installed: ' + $_.Exception.Message)
    }
    return $result
}

function Copy-PitrRecoveryFile {
    param([string]$Source,[string]$Target)
    $input = $null
    $output = $null
    try {
        $input = New-Object IO.FileStream($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $output = New-Object IO.FileStream($Target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        while ($true) {
            $read = $input.Read($buffer,0,$buffer.Length)
            if ($read -le 0) { break }
            $output.Write($buffer,0,$read)
        }
        $output.Flush($true)
    } finally {
        if ($input) { $input.Dispose() }
        if ($output) { $output.Dispose() }
    }
}

function Get-PitrRecoveryLauncherText {
    # Oracle and contract: the launcher finds manifest.json relative to itself, has no fixed drive
    # letter, no network access, no elevation and never executes backed-up content.
    $builder = New-Object Text.StringBuilder
    $null = $builder.AppendLine('@echo off')
    $null = $builder.AppendLine('setlocal enableextensions')
    $null = $builder.AppendLine('rem PITR recovery package launcher.')
    $null = $builder.AppendLine('rem It locates manifest.json relative to this file: no drive letter, no machine name,')
    $null = $builder.AppendLine('rem no network share and no registry state are used to find the backup.')
    $null = $builder.AppendLine('set "PITR_RECOVERY_DIR=%~dp0"')
    $null = $builder.AppendLine('set "PITR_BACKUP_PROFILE="')
    $null = $builder.AppendLine('if exist "%PITR_RECOVERY_DIR%..\manifest.json" set "PITR_BACKUP_PROFILE=%PITR_RECOVERY_DIR%.."')
    $null = $builder.AppendLine('if not defined PITR_BACKUP_PROFILE goto :missing')
    $null = $builder.AppendLine('set "PITR_MANIFEST=%PITR_BACKUP_PROFILE%\manifest.json"')
    $null = $builder.AppendLine('rem Windows PowerShell 5.1 is the supported WPF host.')
    $null = $builder.AppendLine('where powershell.exe >nul 2>nul')
    $null = $builder.AppendLine('if not errorlevel 1 goto :usepowershell')
    $null = $builder.AppendLine('echo No PowerShell engine (pwsh.exe or powershell.exe) was found on this computer.')
    $null = $builder.AppendLine('echo The backup stays readable in Explorer; copy the files you need by hand.')
    $null = $builder.AppendLine('exit /b 1')
    $null = $builder.AppendLine(':usepowershell')
    $null = $builder.AppendLine('powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%PITR_RECOVERY_DIR%src\backup\Entry.ps1" recover --gui --manifest "%PITR_MANIFEST%" %*')
    $null = $builder.AppendLine('exit /b %errorlevel%')
    $null = $builder.AppendLine(':missing')
    $null = $builder.AppendLine('echo The recovery package could not find manifest.json next to itself.')
    $null = $builder.AppendLine('echo Expected the backup generation folder to contain this recovery folder.')
    $null = $builder.AppendLine('echo Nothing was changed.')
    $null = $builder.AppendLine('exit /b 1')
    return $builder.ToString().Replace("`r`n","`n").Replace("`n","`r`n")
}

function Get-PitrRecoveryReadmeText {
    $builder = New-Object Text.StringBuilder
    $null = $builder.AppendLine('PITR recovery package')
    $null = $builder.AppendLine('=====================')
    $null = $builder.AppendLine('')
    $null = $builder.AppendLine('This folder ships with one backup generation. It contains the trusted application code,')
    $null = $builder.AppendLine('a launcher and an integrity inventory. It contains no user data and no credentials.')
    $null = $builder.AppendLine('')
    $null = $builder.AppendLine('What this backup is')
    $null = $builder.AppendLine('- Source view: Live. Consistency: LiveNotApplicationConsistent.')
    $null = $builder.AppendLine('  Files were read from the live running system. No VSS snapshot was created, so the copy')
    $null = $builder.AppendLine('  is NOT application consistent and NOT database consistent. Open applications may hold')
    $null = $builder.AppendLine('  files in a half-written state. Close applications before relying on a backup.')
    $null = $builder.AppendLine('- Objects that were skipped or failed are listed in manifest.json with a reason.')
    $null = $builder.AppendLine('  Nothing was silently omitted, and success is never claimed for them.')
    $null = $builder.AppendLine('')
    $null = $builder.AppendLine('How to use it')
    $null = $builder.AppendLine('1. Keep this folder together with the backup generation folder that contains it.')
    $null = $builder.AppendLine('2. Run Start-Recovery.cmd. It finds manifest.json relative to itself; there is no fixed')
    $null = $builder.AppendLine('   drive letter and no network access. It starts a read-only comparison by default.')
    $null = $builder.AppendLine('3. Recovery actions require explicit selection and are never automatic. Nothing is')
    $null = $builder.AppendLine('   overwritten without an explicit choice that also preserves the current version.')
    $null = $builder.AppendLine('4. You can always copy files by hand in Explorer instead: every stored file keeps its')
    $null = $builder.AppendLine('   ordinary name inside profiles/ or extra-folders/.')
    $null = $builder.AppendLine('')
    $null = $builder.AppendLine('Integrity')
    $null = $builder.AppendLine('- recovery-integrity.json lists every file in this folder with its length and SHA-256.')
    $null = $builder.AppendLine('- That inventory detects accidental corruption. It is NOT a digital signature: anyone')
    $null = $builder.AppendLine('  who can change these files can change the inventory too. Keep the trusted application')
    $null = $builder.AppendLine('  source and the original media.')
    $null = $builder.AppendLine('- If a file in this folder is missing, the launcher fails loudly instead of pretending')
    $null = $builder.AppendLine('  the package is usable.')
    $null = $builder.AppendLine('')
    $null = $builder.AppendLine('This package does not modify WinRE, restore points, the registry or the running system.')
    return $builder.ToString().Replace("`r`n","`n").Replace("`n","`r`n")
}