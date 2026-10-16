# Manifest manager: strict, untrusted-input-safe, transactional.
# A manifest is DATA. Nothing in it is ever evaluated as PowerShell or as a path
# that escapes the backup root. An interrupted backup can never look complete.

$script:PitrManifestStates = @(
    'Planned','Running','Interrupted','CopyCompleted','Verifying','Verified','CompletedWithWarnings','Failed'
)
$script:PitrManifestTerminalStates = @('Verified','Failed')
$script:PitrCopyStatuses = @('Pending','Copied','Skipped','Failed')
$script:PitrVerificationStatuses = @('Pending','QuickVerified','FullVerified','Failed')
$script:PitrEntryTypes = @('File','Directory','ReparsePoint','Unsupported','CloudPlaceholder','Encrypted')
$script:PitrScopes = @('Complete','Personal','Custom')
$script:PitrMaxManifestBytes = 268435456

function Get-PitrManifestStates { return ,@($script:PitrManifestStates) }
function Get-PitrManifestVersion { return 1 }

function Test-PitrManifestState {
    param([string]$State)
    return ($State -and ($script:PitrManifestStates -contains $State))
}

function ConvertTo-PitrSafeRelativePath {
    # Rejects anything that could escape the backup root or name an unsafe location.
    param([string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw 'Manifest entry has an empty relative path.' }
    $value = $RelativePath.Replace('\','/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'Manifest entry has an empty relative path.' }
    if ($value -match '^[A-Za-z]:') { throw ('Manifest entry path is rooted: ' + $RelativePath) }
    if ($value -match '^//' -or $value -match '^\\\\') { throw ('Manifest entry path is a UNC path: ' + $RelativePath) }
    if ($value.StartsWith('//?/') -or $value.StartsWith('//./')) { throw ('Manifest entry path is a device path: ' + $RelativePath) }
    foreach ($component in $value.Split('/')) {
        if ($component -eq '' -or $component -eq '.') { continue }
        if ($component -eq '..') { throw ('Manifest entry path traverses upward: ' + $RelativePath) }
        if ($component.IndexOf(':') -ge 0) { throw ('Manifest entry path contains a stream or drive separator: ' + $RelativePath) }
        if ($component -match '[<>"|?*]') { throw ('Manifest entry path contains an invalid Windows character: ' + $RelativePath) }
        if ($component -match '[ .]$') { throw ('Manifest entry path ends with a space or dot: ' + $RelativePath) }
        $stem = ($component.Split('.')[0]).ToUpperInvariant()
        if ($stem -in @('CON','PRN','AUX','NUL','COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9','LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')) { throw ('Manifest entry path uses a reserved device name: ' + $RelativePath) }
    }
    return $value
}

function Get-PitrManifestProperty {
    param($Object,[string]$Name)
    if ($null -eq $Object) { throw ('Manifest is missing the ' + $Name + ' object.') }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw ('Manifest field is missing: ' + $Name) }
    return $property.Value
}

function Assert-PitrManifestShape {
    param($Manifest)
    if ($null -eq $Manifest) { throw 'Manifest is null.' }
    $version = Get-PitrManifestProperty $Manifest 'SchemaVersion'
    if ([int]$version -ne 1) { throw ('Unsupported manifest schema version: ' + [string]$version) }
    $backupId = [string](Get-PitrManifestProperty $Manifest 'BackupId')
    if ([string]::IsNullOrWhiteSpace($backupId)) { throw 'Manifest has no BackupId.' }
    try { $null=[guid]$backupId } catch { throw ('Manifest BackupId is not a GUID: ' + $backupId) }
    $state = [string](Get-PitrManifestProperty $Manifest 'State')
    if (-not (Test-PitrManifestState $state)) { throw ('Manifest has an unknown state: ' + $state) }
    $scope = [string](Get-PitrManifestProperty $Manifest 'Scope')
    if ($script:PitrScopes -notcontains $scope) { throw ('Manifest has an unknown scope: ' + $scope) }
    $entries = Get-PitrManifestProperty $Manifest 'Entries'
    if ($null -ne $entries) {
        $seen = @{}
        foreach ($entry in @($entries)) {
            $id = [string](Get-PitrManifestProperty $entry 'Id')
            if ([string]::IsNullOrWhiteSpace($id)) { throw 'Manifest entry has no Id.' }
            if ($seen.ContainsKey($id)) { throw ('Manifest has a duplicate entry id: ' + $id) }
            $seen[$id] = $true
            $null = ConvertTo-PitrSafeRelativePath -RelativePath ([string](Get-PitrManifestProperty $entry 'RelativePath'))
            $type = [string](Get-PitrManifestProperty $entry 'Type')
            if ($script:PitrEntryTypes -notcontains $type) { throw ('Manifest entry has an unknown type: ' + $type) }
            $length = Get-PitrManifestProperty $entry 'Length'
            if ($null -eq $length -or [string]::IsNullOrWhiteSpace([string]$length)) { throw ('Manifest entry has no Length: ' + $id) }
            if ($length -is [string]) { throw ('Manifest entry Length must be a number, not a string: ' + $id) }
            try { $null = [int64]$length } catch { throw ('Manifest entry Length is not an integer: ' + $id) }
            $copy = [string](Get-PitrManifestProperty $entry 'CopyStatus')
            if ($script:PitrCopyStatuses -notcontains $copy) { throw ('Manifest entry has an unknown copy status: ' + $copy) }
            $verifyProperty = $entry.PSObject.Properties['VerificationStatus']
            if ($null -ne $verifyProperty -and $script:PitrVerificationStatuses -notcontains [string]$verifyProperty.Value) { throw ('Manifest entry has an unknown verification status: ' + [string]$verifyProperty.Value) }
            $shaProperty = $entry.PSObject.Properties['Sha256']
            if ($null -ne $shaProperty -and -not [string]::IsNullOrWhiteSpace([string]$shaProperty.Value)) {
                if ([string]$shaProperty.Value -notmatch '^[0-9a-fA-F]{64}$') { throw ('Manifest entry has a malformed SHA-256: ' + $id) }
            }
        }
    }
    return $true
}

function New-PitrManifestEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$SourceId,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][ValidateSet('File','Directory','ReparsePoint','Unsupported','CloudPlaceholder','Encrypted')][string]$Type,
        [Parameter(Mandatory=$false)][string]$BackupRelativePath,
        [Parameter(Mandatory=$false)][string]$OriginalPath,
        [Parameter(Mandatory=$false)][string]$ProfileSid=$null,
        [Parameter(Mandatory=$false)][int64]$Length=0,
        [Parameter(Mandatory=$false)][string]$LastWriteUtc=$null,
        [Parameter(Mandatory=$false)][string]$Attributes=$null,
        [Parameter(Mandatory=$false)][string]$SourceVolumeId=$null,
        [Parameter(Mandatory=$false)][ValidateSet('Pending','Copied','Skipped','Failed')][string]$CopyStatus='Pending',
        [Parameter(Mandatory=$false)][ValidateSet('Pending','QuickVerified','FullVerified','Failed')][string]$VerificationStatus='Pending',
        [Parameter(Mandatory=$false)][string]$Sha256=$null,
        [Parameter(Mandatory=$false)][string]$Error=$null,
        [Parameter(Mandatory=$false)][bool]$IsAdvanced=$false,
        [Parameter(Mandatory=$false)][bool]$IsSensitive=$false,
        [Parameter(Mandatory=$false)][string]$SourceView='Live'
    )
    $safe = ConvertTo-PitrSafeRelativePath -RelativePath $RelativePath
    if ([string]::IsNullOrWhiteSpace($BackupRelativePath)) {
        $BackupRelativePath = 'profiles/' + $SourceId + '/' + $safe
    } else {
        $BackupRelativePath = ConvertTo-PitrSafeRelativePath -RelativePath $BackupRelativePath
    }
    if ($Sha256 -and $Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw ('Invalid SHA-256 for entry: ' + $Id) }
    [pscustomobject]@{
        Id=$Id; SourceId=$SourceId; RelativePath=$safe; BackupRelativePath=$BackupRelativePath
        OriginalPath=$OriginalPath; ProfileSid=$ProfileSid; Type=$Type; Length=$Length
        LastWriteUtc=$LastWriteUtc; Attributes=$Attributes; SourceVolumeId=$SourceVolumeId
        CopyStatus=$CopyStatus; VerificationStatus=$VerificationStatus
        Sha256=if ($Sha256) { $Sha256.ToLowerInvariant() } else { $null }
        Error=$Error; SourceView=$SourceView; IsAdvanced=$IsAdvanced; IsSensitive=$IsSensitive
    }
}

function New-PitrManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$BackupId,
        [Parameter(Mandatory=$false)][ValidateSet('Complete','Personal','Custom')][string]$Scope='Complete',
        [Parameter(Mandatory=$false)][string]$ApplicationVersion=$null,
        [Parameter(Mandatory=$false)][string]$ComputerIdentity=$null,
        [Parameter(Mandatory=$false)][string]$OsVersion=$null
    )
    try { $null=[guid]$BackupId } catch { throw ('BackupId must be a GUID, got: ' + $BackupId) }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    try { $computer = if ($ComputerIdentity) { $ComputerIdentity } else { [Environment]::MachineName } } catch { $computer = 'unknown' }
    try { $os = if ($OsVersion) { $OsVersion } else { [Environment]::OSVersion.VersionString } } catch { $os = 'unknown' }
    [pscustomobject]@{
        SchemaVersion=1
        BackupId=$BackupId.ToLowerInvariant()
        ComputerIdentity=$computer
        OsVersion=$os
        ApplicationVersion=$ApplicationVersion
        CreatedUtc=$now
        StartedUtc=$now
        CompletedUtc=$null
        State='Planned'
        Scope=$Scope
        SourceView='Live'
        Consistency='LiveNotApplicationConsistent'
        Sources=@()
        Entries=@()
        Exclusions=@()
        Warnings=@()
        Counts=[pscustomobject]@{ Expected=0; Copied=0; Verified=0; Skipped=0; Failed=0; Bytes=0 }
        RecoveryPackage=$null
        DestinationIdentity=$null
    }
}

function Set-PitrManifestState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$State
    )
    if (-not (Test-PitrManifestState $State)) { throw ('Unknown manifest state: ' + $State) }
    $current = [string]$Manifest.State
    if ($script:PitrManifestTerminalStates -contains $current -and $current -ne $State) {
        throw ('Manifest state ' + $current + ' is terminal; it cannot become ' + $State + '.')
    }
    # An ordered lifecycle: the strongest success states are reachable only through
    # the work that earns them, so a plan or an interrupted run can never look complete.
    $required = @{
        'CopyCompleted' = @('Running','Interrupted')
        'Verifying'     = @('CopyCompleted')
        'Verified'      = @('Verifying')
    }
    if ($required.ContainsKey($State) -and ($required[$State] -notcontains $current)) {
        throw ('Manifest state cannot go from ' + $current + ' to ' + $State + '; it must pass through ' + ($required[$State] -join ' or ') + '.')
    }
    if ($State -eq 'Planned') { throw 'Manifest cannot return to Planned.' }
    if ($State -eq 'Running' -and $current -notin @('Planned','Interrupted')) { throw ('Manifest state cannot go from ' + $current + ' to Running.') }
    if ($State -eq 'CompletedWithWarnings' -and $current -ne 'Verifying') { throw ('CompletedWithWarnings requires a completed verification; current state is ' + $current + '.') }
    $Manifest.State = $State
    if ($State -in @('Verified','CompletedWithWarnings','Failed')) {
        $Manifest.CompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    return $Manifest
}

function Get-PitrManifestCounts {
    param($Manifest)
    $entries = @($Manifest.Entries)
    $copied = @($entries | Where-Object { $_.CopyStatus -eq 'Copied' }).Count
    $verified = @($entries | Where-Object { $_.VerificationStatus -in @('QuickVerified','FullVerified') }).Count
    $skipped = @($entries | Where-Object { $_.CopyStatus -eq 'Skipped' }).Count
    $failed = @($entries | Where-Object { $_.CopyStatus -eq 'Failed' }).Count
    $bytes = 0
    foreach ($entry in $entries | Where-Object { $_.CopyStatus -eq 'Copied' }) { $bytes += [int64]$entry.Length }
    [pscustomobject]@{ Expected=$entries.Count; Copied=$copied; Verified=$verified; Skipped=$skipped; Failed=$failed; Bytes=$bytes }
}

function Read-PitrManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ManifestPath)
    if (-not [IO.File]::Exists($ManifestPath)) { throw ('Manifest not found: ' + $ManifestPath) }
    $info = New-Object IO.FileInfo($ManifestPath)
    if ($info.Length -gt $script:PitrMaxManifestBytes) { throw ('Manifest is larger than the accepted limit: ' + $manifestPath) }
    $text = [IO.File]::ReadAllText($ManifestPath, [Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace($text)) { throw ('Manifest is empty: ' + $ManifestPath) }
    try { $parsed = $text | ConvertFrom-Json } catch { throw ('Manifest is not valid JSON: ' + $ManifestPath + ' : ' + $_.Exception.Message) }
    $null = Assert-PitrManifestShape $parsed
    $counts = Get-PitrManifestCounts $parsed
    if ($null -ne $parsed.PSObject.Properties['Counts']) { $parsed.Counts = $counts } else { $parsed | Add-Member -NotePropertyName Counts -NotePropertyValue $counts }
    return $parsed
}

function Write-PitrManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ManifestPath,
        [Parameter(Mandatory=$true)]$Manifest
    )
    $null = Assert-PitrManifestShape $Manifest
    $counts = Get-PitrManifestCounts $Manifest
    if ($null -ne $Manifest.PSObject.Properties['Counts']) { $Manifest.Counts = $counts } else { $Manifest | Add-Member -NotePropertyName Counts -NotePropertyValue $counts }
    $directory = Split-Path -Parent $ManifestPath
    if ($directory -and -not [IO.Directory]::Exists($directory)) { $null=[IO.Directory]::CreateDirectory($directory) }
    $json = $Manifest | ConvertTo-Json -Depth 8
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($ManifestPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $utf8 = New-Object Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temporary, $json, $utf8)
        # Atomic replace where the filesystem supports it; never a truncate-in-place.
        # A real backup path is passed rather than $null: PowerShell converts a null
        # argument to an empty string, which File.Replace rejects.
        if ([IO.File]::Exists($ManifestPath)) {
            $aside = $ManifestPath + '.' + [guid]::NewGuid().ToString('N') + '.bak'
            [IO.File]::Replace($temporary, $ManifestPath, $aside)
            if ([IO.File]::Exists($aside)) { [IO.File]::Delete($aside) }
        } else {
            [IO.File]::Move($temporary, $ManifestPath)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    return $ManifestPath
}

function Get-PitrHash {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { throw ('Cannot hash a missing file: ' + $Path) }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $hash = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($hash)).Replace('-','').ToLowerInvariant()
    } finally {
        if ($stream) { $stream.Dispose() }
        $algorithm.Dispose()
    }
}

function Get-PitrFileHashWithChanges {
    # Hashes a live file and reports whether it changed while being read, so a
    # backup can say "captured, but the source moved under us" rather than lie.
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $before = New-Object IO.FileInfo($Path)
    if (-not $before.Exists) { throw ('Cannot hash a missing file: ' + $Path) }
    $lengthBefore = $before.Length
    $writeBefore = $before.LastWriteTimeUtc
    $hash = Get-PitrHash -Path $Path
    $after = New-Object IO.FileInfo($Path)
    $changed = (-not $after.Exists) -or ($after.Length -ne $lengthBefore) -or ($after.LastWriteTimeUtc -ne $writeBefore)
    [pscustomobject]@{ Sha256=$hash; Length=$lengthBefore; LastWriteUtc=$writeBefore.ToString('o'); ChangedDuringRead=$changed }
}
