# Comparison and selective recovery engine.
#
# Two rules decide the whole design:
#   1. Nothing in a manifest or a backup is trusted. Every path is re-validated
#      against an approved destination root before any write.
#   2. Nothing is written unless the caller asked for it explicitly. Recovery is
#      dry-run by default, existing files are never overwritten silently, and a
#      difference is never described as damage a rollback caused - only as a
#      difference observed now.

$script:PitrComparisonClassifications = @('Missing','Different','Identical','LikelyIdentical','CurrentOnly','Unknown')
$script:PitrSensitiveExtensions = @('.exe','.dll','.scr','.sys','.com','.pif','.bat','.cmd','.ps1','.psm1','.vbs','.vbe','.js','.jse','.wsf','.wsh','.hta','.lnk','.msi','.msp','.reg','.jar')
$script:PitrMaxCurrentOnlyScan = 200000

function Get-PitrComparisonClassifications { return ,@($script:PitrComparisonClassifications) }

function Test-PitrAdvancedRelativePath {
    param([string]$RelativePath)
    $value = $RelativePath.Replace('\','/')
    foreach ($component in $value.Split('/')) {
        if ($component -eq 'AppData') { return $true }
    }
    return $false
}

function Test-PitrSensitiveRelativePath {
    param([string]$RelativePath)
    $value = $RelativePath.Replace('\','/')
    $leaf = $value.Split('/')[-1]
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $false }
    $name = $leaf.ToLowerInvariant()
    foreach ($extension in $script:PitrSensitiveExtensions) {
        if ($name.EndsWith($extension)) { return $true }
    }
    $normalized = $value.ToLowerInvariant()
    foreach ($marker in @('start menu/programs/startup','startup/','/startup')) {
        if ($normalized.Contains($marker)) { return $true }
    }
    return $false
}

function Test-PitrPathInsideRoot {
    # Containment by canonical path boundary, not by string prefix.
    param([string]$Root,[string]$Candidate)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('/','\')
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    if ($candidateFull.Length -le $rootFull.Length) { return $false }
    if (-not $candidateFull.StartsWith($rootFull, [StringComparison]::Ordinal)) { return $false }
    $separator = $candidateFull[$rootFull.Length]
    return ($separator -eq [IO.Path]::DirectorySeparatorChar -or $separator -eq [IO.Path]::AltDirectorySeparatorChar)
}

function Get-PitrApprovedRoot {
    # An approved root is an existing directory that is not a reparse point, so a
    # junction cannot silently redirect a restore outside the shown location.
    param([string]$Root,[string]$Label)
    if ([string]::IsNullOrWhiteSpace($Root)) { throw ('Approved recovery root is empty for ' + $Label + '.') }
    $full = [IO.Path]::GetFullPath($Root)
    if (-not [IO.Directory]::Exists($full)) { throw ('Approved recovery root does not exist: ' + $full) }
    $attributes = [IO.File]::GetAttributes($full)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Approved recovery root is a reparse point and is refused: ' + $full) }
    return $full
}

function Get-PitrComparisonEntry {
    param(
        $Entry,
        [string]$CurrentPath,
        [string]$Classification,
        [string]$BackupPath,
        [string]$BackupSha=$null,
        [string]$CurrentSha=$null,
        [string]$Error=$null,
        [bool]$Deep=$false
    )
    [pscustomobject]@{
        Id=[string]$Entry.Id
        SourceId=[string]$Entry.SourceId
        RelativePath=[string]$Entry.RelativePath
        BackupRelativePath=[string]$Entry.BackupRelativePath
        BackupPath=$BackupPath
        CurrentPath=$CurrentPath
        Classification=$Classification
        BackupLength=[int64]$Entry.Length
        CurrentLength=$null
        BackupLastWriteUtc=$Entry.LastWriteUtc
        CurrentLastWriteUtc=$null
        BackupSha256=$BackupSha
        CurrentSha256=$CurrentSha
        ContentVerified=$Deep
        IsAdvanced=(Test-PitrAdvancedRelativePath ([string]$Entry.RelativePath))
        IsSensitive=(Test-PitrSensitiveRelativePath ([string]$Entry.RelativePath))
        Error=$Error
    }
}

function Compare-PitrBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ManifestPath,
        [Parameter(Mandatory=$false)][hashtable]$Mappings=@{},
        [Parameter(Mandatory=$false)][switch]$Deep,
        [Parameter(Mandatory=$false)][AllowEmptyCollection()][string[]]$AlternateRoots=@(),
        [Parameter(Mandatory=$false)][scriptblock]$Progress=$null,
        [Parameter(Mandatory=$false)]$Cancellation=$null
    )
    $manifest = Read-PitrManifest -ManifestPath $ManifestPath
    $backupRoot = Split-Path -Parent ([IO.Path]::GetFullPath($ManifestPath))
    $warnings = New-Object 'Collections.Generic.List[string]'
    $entries = New-Object 'Collections.Generic.List[object]'
    $scanComplete = $true

    # Which manifest sources have an approved current location?
    $sourceRoots = @{}
    $sourceIds = New-Object 'Collections.Generic.List[string]'
    foreach ($source in @($manifest.Sources)) {
        $id = [string]$source.Id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $sourceIds.Add($id)
        $candidate = $null
        if ($Mappings.ContainsKey($id)) { $candidate = [string]$Mappings[$id] }
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $warnings.Add('Source ' + $id + ' (' + [string]$source.Path + ') has no approved current location; its files are reported Unknown and never restored.')
            $scanComplete = $false
            continue
        }
        try { $sourceRoots[$id] = Get-PitrApprovedRoot -Root $candidate -Label $id }
        catch { $warnings.Add('Approved current location for ' + $id + ' was refused: ' + $_.Exception.Message); $scanComplete = $false }
    }
    foreach ($key in @($Mappings.Keys)) {
        if ($sourceIds -notcontains [string]$key) { $warnings.Add('A mapping was supplied for an unknown source id and was ignored: ' + [string]$key) }
    }

    $bySourceRelative = @{}
    foreach ($entry in @($manifest.Entries)) {
        if ($null -ne $Cancellation -and $Cancellation.Cancelled) { $scanComplete = $false; $warnings.Add('Comparison was cancelled; the result is incomplete.'); break }
        $sourceId = [string]$entry.SourceId
        $relative = [string]$entry.RelativePath
        $backupRelative = [string]$entry.BackupRelativePath
        $backupPath = $null
        try { $backupPath = [IO.Path]::GetFullPath((Join-Path $backupRoot $backupRelative.Replace('/',[IO.Path]::DirectorySeparatorChar))) }
        catch { $backupPath = $null }

        if ([string]$entry.Type -ne 'File') {
            $entries.Add((Get-PitrComparisonEntry -Entry $entry -CurrentPath $null -Classification 'Unknown' -BackupPath $backupPath -Error ('Entry type ' + [string]$entry.Type + ' is not comparable content.')))
            if ([string]$entry.Type -in @('Unsupported','ReparsePoint','CloudPlaceholder','Encrypted')) { $warnings.Add('Entry is not ordinary comparable content: ' + $relative + ' (' + [string]$entry.Type + ')') }
            continue
        }
        if (-not $sourceRoots.ContainsKey($sourceId)) {
            $entries.Add((Get-PitrComparisonEntry -Entry $entry -CurrentPath $null -Classification 'Unknown' -BackupPath $backupPath -Error 'No approved current location for this source.'))
            continue
        }
        if ([string]$entry.CopyStatus -ne 'Copied') {
            $entries.Add((Get-PitrComparisonEntry -Entry $entry -CurrentPath $null -Classification 'Unknown' -BackupPath $backupPath -Error ('The backup does not hold this file (copy status ' + [string]$entry.CopyStatus + ').')))
            continue
        }
        if (-not [IO.File]::Exists($backupPath)) {
            $entries.Add((Get-PitrComparisonEntry -Entry $entry -CurrentPath $null -Classification 'Unknown' -BackupPath $backupPath -Error 'The backup copy is missing.'))
            $scanComplete = $false
            continue
        }

        $currentPath = $null
        try {
            $safeRelative = ConvertTo-PitrSafeRelativePath -RelativePath $relative
            $currentPath = [IO.Path]::GetFullPath((Join-Path $sourceRoots[$sourceId] $safeRelative.Replace('/',[IO.Path]::DirectorySeparatorChar)))
            if (-not (Test-PitrPathInsideRoot -Root $sourceRoots[$sourceId] -Candidate $currentPath)) {
                $entries.Add((Get-PitrComparisonEntry -Entry $entry -CurrentPath $currentPath -Classification 'Unknown' -BackupPath $backupPath -Error 'Entry path would leave the approved root.'))
                $scanComplete = $false
                continue
            }
        } catch {
            $entries.Add((Get-PitrComparisonEntry -Entry $entry -CurrentPath $null -Classification 'Unknown' -BackupPath $backupPath -Error ('Entry path refused: ' + $_.Exception.Message)))
            $scanComplete = $false
            continue
        }

        if ($null -ne $Progress) { & $Progress ([pscustomobject]@{ Phase='Compare'; File=$currentPath; FilesProcessed=$entries.Count; TotalFiles=@($manifest.Entries).Count }) }

        if (-not [IO.File]::Exists($currentPath)) {
            $entries.Add((Get-PitrComparisonEntry -Entry $entry -CurrentPath $currentPath -Classification 'Missing' -BackupPath $backupPath -BackupSha $entry.Sha256))
            $bySourceRelative[($sourceId + '|' + $relative.ToLowerInvariant())] = $true
            continue
        }
        $bySourceRelative[($sourceId + '|' + $relative.ToLowerInvariant())] = $true
        $currentInfo = New-Object IO.FileInfo($currentPath)
        $backupInfo = New-Object IO.FileInfo($backupPath)
        $classification = 'Unknown'
        $currentSha = $null
        $backupSha = $entry.Sha256
        $error = $null
        try {
            if ($Deep) {
                $currentSha = Get-PitrHash -Path $currentPath
                $backupActual = Get-PitrHash -Path $backupPath
                if ($backupSha -and ($backupActual -ne $backupSha)) {
                    # The stored bytes no longer match what the backup recorded, so no
                    # classification can be trusted. Say so instead of quietly using it.
                    $classification = 'Unknown'
                    $error = 'The backup copy does not match the hash recorded in the manifest.'
                    $scanComplete = $false
                } elseif ($currentSha -eq $backupActual) {
                    $classification = 'Identical'
                } else {
                    $classification = 'Different'
                }
                # Deliberately keep the hash recorded by the backup in the row, so a
                # caller can still see what the backup claimed to hold.
            } else {
                # A JSON round trip can hand this back as a DateTime or a string, so
                # compare instants, not representations.
                $recordedWrite=$null
                if($null -ne $entry.PSObject.Properties['LastWriteUtc'] -and $entry.LastWriteUtc){ $recordedWrite=$entry.LastWriteUtc }
                $recordedUtc=$null
                if($recordedWrite -is [datetime]) { $recordedUtc=$recordedWrite.ToUniversalTime() }
                elseif($recordedWrite) {
                    try { $recordedUtc=[datetime]::Parse([string]$recordedWrite,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $recordedUtc=$null }
                }
                if ($currentInfo.Length -eq $backupInfo.Length -and $recordedUtc -and ($currentInfo.LastWriteTimeUtc -eq $recordedUtc)) {
                    $classification = 'LikelyIdentical'
                } else {
                    $classification = 'Different'
                }
            }
        } catch {
            $classification = 'Unknown'
            $error = $_.Exception.Message
            $scanComplete = $false
        }
        $row = Get-PitrComparisonEntry -Entry $entry -CurrentPath $currentPath -Classification $classification -BackupPath $backupPath -BackupSha $backupSha -CurrentSha $currentSha -Error $error -Deep:$Deep
        $row.CurrentLength = $currentInfo.Length
        $row.CurrentLastWriteUtc = $currentInfo.LastWriteTimeUtc.ToString('o')
        $entries.Add($row)
    }

    # Files that exist only on the current Windows installation. They are listed
    # for information and are never a recovery target.
    $currentOnly = New-Object 'Collections.Generic.List[object]'
    foreach ($sourceId in @($sourceRoots.Keys)) {
        if ($null -ne $Cancellation -and $Cancellation.Cancelled) { $scanComplete = $false; break }
        $root = $sourceRoots[$sourceId]
        $stack = New-Object 'Collections.Generic.Stack[string]'
        $stack.Push($root)
        $scanned = 0
        while ($stack.Count -gt 0) {
            $directory = $stack.Pop()
            try {
                if (($directory -ne $root) -and (([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    $warnings.Add('Reparse point not scanned as current-only content: ' + $directory)
                    continue
                }
                foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) { $stack.Push($child) }
                foreach ($file in [IO.Directory]::EnumerateFiles($directory)) {
                    $scanned++
                    if ($scanned -gt $script:PitrMaxCurrentOnlyScan) {
                        $scanComplete = $false
                        $warnings.Add('Current-only scan stopped at ' + $script:PitrMaxCurrentOnlyScan + ' files under ' + $root + '; the list is not complete.')
                        break
                    }
                    $relative = $file.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
                    if ($bySourceRelative.ContainsKey(($sourceId + '|' + $relative.ToLowerInvariant()))) { continue }
                    $currentOnly.Add([pscustomobject]@{
                        Id=('currentonly-' + $sourceId + '-' + $relative)
                        SourceId=$sourceId
                        RelativePath=($relative.Replace([IO.Path]::DirectorySeparatorChar,'/'))
                        BackupRelativePath=$null
                        BackupPath=$null
                        CurrentPath=$file
                        Classification='CurrentOnly'
                        BackupLength=$null
                        CurrentLength=(New-Object IO.FileInfo($file)).Length
                        BackupLastWriteUtc=$null
                        CurrentLastWriteUtc=(New-Object IO.FileInfo($file)).LastWriteTimeUtc.ToString('o')
                        BackupSha256=$null
                        CurrentSha256=$null
                        ContentVerified=$false
                        IsAdvanced=(Test-PitrAdvancedRelativePath $relative)
                        IsSensitive=(Test-PitrSensitiveRelativePath $relative)
                        Error=$null
                    })
                }
            } catch {
                $warnings.Add('Current-only scan could not read ' + $directory + ': ' + $_.Exception.Message)
                $scanComplete = $false
            }
        }
    }

    $all = New-Object 'Collections.Generic.List[object]'
    foreach ($row in $entries) { $all.Add($row) }
    foreach ($row in $currentOnly) { $all.Add($row) }
    $summary = [pscustomobject]@{
        Missing=@($all | Where-Object { $_.Classification -eq 'Missing' }).Count
        Different=@($all | Where-Object { $_.Classification -eq 'Different' }).Count
        Identical=@($all | Where-Object { $_.Classification -eq 'Identical' }).Count
        LikelyIdentical=@($all | Where-Object { $_.Classification -eq 'LikelyIdentical' }).Count
        CurrentOnly=@($all | Where-Object { $_.Classification -eq 'CurrentOnly' }).Count
        Unknown=@($all | Where-Object { $_.Classification -eq 'Unknown' }).Count
        BackupBytes=@($all | Where-Object { $_.BackupLength } | Measure-Object -Property BackupLength -Sum).Sum
    }
    [pscustomobject]@{
        SchemaVersion=1
        BackupId=[string]$manifest.BackupId
        ManifestPath=[IO.Path]::GetFullPath($ManifestPath)
        BackupRoot=$backupRoot
        ManifestState=[string]$manifest.State
        Deep=[bool]$Deep
        MappedSources=@($sourceRoots.Keys)
        Entries=$all.ToArray()
        Summary=$summary
        Warnings=$warnings.ToArray()
        ScanComplete=$scanComplete
        Complete=$scanComplete
    }
}

function Get-PitrConflictPath {
    param([string]$Destination,[string]$Kind,[string]$Stamp)
    $directory = Split-Path -Parent $Destination
    $name = [IO.Path]::GetFileNameWithoutExtension($Destination)
    $extension = [IO.Path]::GetExtension($Destination)
    $candidate = Join-Path $directory ($name + '.' + $Kind + '-' + $Stamp + $extension)
    $index = 1
    while ([IO.File]::Exists($candidate)) {
        $candidate = Join-Path $directory ($name + '.' + $Kind + '-' + $Stamp + '-' + $index + $extension)
        $index++
    }
    return $candidate
}

function Restore-PitrFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ManifestPath,
        [Parameter(Mandatory=$false)][hashtable]$Mappings=@{},
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$EntryIds,
        [Parameter(Mandatory=$false)][string]$AlternateRoot=$null,
        [Parameter(Mandatory=$false)][ValidateSet('Skip','Alongside','Replace')][string]$Conflict='Skip',
        [Parameter(Mandatory=$false)][switch]$Execute,
        [Parameter(Mandatory=$false)][switch]$AllowAdvanced,
        [Parameter(Mandatory=$false)][scriptblock]$Progress=$null,
        [Parameter(Mandatory=$false)]$Cancellation=$null
    )
    if ($EntryIds.Count -eq 0) { throw 'Recovery requires at least one explicitly selected entry id.' }
    if (-not $AlternateRoot -and $Mappings.Count -eq 0) { throw 'Recovery requires an approved --mapping or an --alternate-root.' }

    $alternate = $null
    if ($AlternateRoot) {
        if (-not [IO.Directory]::Exists($AlternateRoot)) { throw ('Alternate recovery root does not exist: ' + $AlternateRoot) }
        $alternate = Get-PitrApprovedRoot -Root $AlternateRoot -Label 'alternate root'
    }

    $comparison = Compare-PitrBackup -ManifestPath $ManifestPath -Mappings $Mappings -Deep -Cancellation $Cancellation
    $byId = @{}
    foreach ($row in @($comparison.Entries)) { $byId[[string]$row.Id] = $row }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $actions = New-Object 'Collections.Generic.List[object]'
    $complete = $true
    foreach ($id in $EntryIds) {
        $row = $byId[$id]
        if ($null -eq $row) {
            $actions.Add([pscustomobject]@{ EntryId=$id; RelativePath=$null; Action='Refused'; Destination=$null; PreservedPath=$null; Result='Failed'; VerificationStatus='NotAttempted'; Error='Entry id is not present in this backup.' })
            $complete = $false
            continue
        }
        $action = [pscustomobject]@{
            EntryId=$id; RelativePath=$row.RelativePath; Action='None'; Destination=$null
            PreservedPath=$null; Result='Skipped'; VerificationStatus='NotAttempted'; Error=$null
        }
        if ($row.Classification -eq 'CurrentOnly') {
            $action.Action='PreserveCurrentOnly'; $action.Error='A file that exists only on the current installation is never a recovery target.'; $complete=$false
            $actions.Add($action); continue
        }

        # Verify the backup copy against what the backup recorded before anything else
        # is decided about it: a changed or unreadable source must never be restored.
        if ($row.BackupPath) {
            $expected = [string]$row.BackupSha256
            try {
                $actualBackupHash = Get-PitrHash -Path $row.BackupPath
                if ($expected -and ($actualBackupHash -ne $expected)) {
                    $action.Action='RefusedBackupChanged'; $action.Error='The backup copy does not match the hash recorded in the manifest.'
                    $complete=$false; $actions.Add($action); continue
                }
                $expected = $actualBackupHash
            } catch {
                $action.Action='RefusedBackupUnreadable'; $action.Error=$_.Exception.Message
                $complete=$false; $actions.Add($action); continue
            }
        } else {
            $action.Action='RefusedNoBackupSource'; $action.Error='This entry has no backup copy to restore from.'
            $complete=$false; $actions.Add($action); continue
        }

        if ($row.Classification -eq 'Unknown') {
            $action.Action='RefusedUnknown'; $action.Error='The comparison could not classify this entry: ' + [string]$row.Error; $complete=$false
            $actions.Add($action); continue
        }
        if ($row.Classification -eq 'Identical') {
            $action.Action='SkipIdentical'; $action.Error='The current file already matches the backup.'; $actions.Add($action); continue
        }
        if ($row.IsAdvanced -and -not $AllowAdvanced) {
            $action.Action='SkipAdvancedNotPermitted'; $action.Error='This entry is application data (AppData). Restoring it requires explicit advanced consent; recovery into an alternate folder is preferred.'
            $actions.Add($action); continue
        }
        $destinationRoot = $null
        if ($alternate) { $destinationRoot = $alternate }
        elseif ($row.SourceId -and $Mappings.ContainsKey($row.SourceId)) { $destinationRoot = [IO.Path]::GetFullPath([string]$Mappings[$row.SourceId]) }
        if (-not $destinationRoot) {
            $action.Action='RefusedNoApprovedRoot'; $action.Error='No approved destination for this entry.'; $complete=$false
            $actions.Add($action); continue
        }
        if ($row.IsSensitive -and -not $alternate) {
            $action.Action='RefusedSensitive'; $action.Error='Executable, script, shortcut or startup content is not restored into a live profile. Use an alternate folder.'
            $complete=$false; $actions.Add($action); continue
        }
        $destination = $null
        try {
            $safeRelative = ConvertTo-PitrSafeRelativePath -RelativePath ([string]$row.RelativePath)
            $destination = [IO.Path]::GetFullPath((Join-Path $destinationRoot $safeRelative.Replace('/',[IO.Path]::DirectorySeparatorChar)))
            if (-not (Test-PitrPathInsideRoot -Root $destinationRoot -Candidate $destination)) { throw 'Destination would leave the approved root.' }
        } catch {
            $action.Action='RefusedUnsafePath'; $action.Error=$_.Exception.Message; $complete=$false
            $actions.Add($action); continue
        }
        $action.Destination=$destination

        # $expected was established when the backup copy was verified above.
        $exists = [IO.File]::Exists($destination)
        if ($exists -and $Conflict -eq 'Skip') {
            $action.Action='SkipExistingDefault'; $action.Result='Skipped'
            $action.Error='An existing file is kept unless a conflict policy is chosen explicitly.'
            $actions.Add($action); continue
        }
        if ($row.Classification -eq 'Missing' -and $exists -and $Conflict -ne 'Alongside') {
            $action.Action='DifferentOnArrival'; $action.Result='Skipped'; $action.Error='The file appeared while comparing; it is left alone.'
            $actions.Add($action); continue
        }

        $target = $destination
        $replacing = $false
        if ($exists -and $Conflict -eq 'Alongside') {
            # Write next to the current file and leave that file exactly as it is.
            $target = Get-PitrConflictPath -Destination $destination -Kind 'restored' -Stamp $stamp
        } elseif ($exists) {
            $replacing = $true
        }
        $action.Action = if ($replacing) { 'ReplacePreservingCurrent' } elseif ($row.Classification -eq 'Missing') { 'RecoverMissing' } else { 'RecoverDifferent' }
        $action.Destination = $target

        if (-not $Execute) {
            $action.Result='DryRun'
            $action.VerificationStatus='NotAttempted'
            $actions.Add($action)
            continue
        }

        try {
            if ($Progress) { & $Progress ([pscustomobject]@{ Phase='Recover'; File=$target; FilesProcessed=$actions.Count; TotalFiles=$EntryIds.Count }) }
            $directory = Split-Path -Parent $target
            if (-not [IO.Directory]::Exists($directory)) { $null=[IO.Directory]::CreateDirectory($directory) }
            $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
            $input = New-Object IO.FileStream($row.BackupPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            $output = New-Object IO.FileStream($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] (262144)
                while (($read = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
                    if ($null -ne $Cancellation -and $Cancellation.Cancelled) { throw 'Recovery was cancelled.' }
                    $output.Write($buffer,0,$read)
                }
            } finally { $output.Dispose(); $input.Dispose() }
            if ((Get-PitrHash -Path $temporary) -ne $expected) { throw 'The copied file does not match the expected hash.' }
            if ($replacing) {
                # Preserve the current bytes first, then swap; restore them if the swap fails.
                $preserved = Get-PitrConflictPath -Destination $destination -Kind 'replaced' -Stamp $stamp
                [IO.File]::Move($destination,$preserved)
                $action.PreservedPath=$preserved
                try { [IO.File]::Move($temporary,$target) }
                catch { [IO.File]::Move($preserved,$destination); throw }
            } else {
                [IO.File]::Move($temporary,$target)
            }
            if ((Get-PitrHash -Path $target) -ne $expected) { throw 'The restored file does not verify.' }
            $action.Result='Succeeded'
            $action.VerificationStatus='FullVerified'
        } catch {
            $action.Result='Failed'
            $action.Error=$_.Exception.Message
            $complete=$false
        } finally {
            if ($temporary -and [IO.File]::Exists($temporary)) { try { [IO.File]::Delete($temporary) } catch { } }
        }
        $actions.Add($action)
    }

    $restored = @($actions | Where-Object { $_.Result -eq 'Succeeded' }).Count
    $failed = @($actions | Where-Object { $_.Result -eq 'Failed' }).Count
    $skipped = @($actions | Where-Object { $_.Result -eq 'Skipped' }).Count
    [pscustomobject]@{
        SchemaVersion=1
        BackupId=$comparison.BackupId
        ManifestPath=$comparison.ManifestPath
        DryRun=(-not $Execute)
        ConflictPolicy=$Conflict
        AlternateRoot=$alternate
        Actions=$actions.ToArray()
        Summary=[pscustomobject]@{ Selected=$EntryIds.Count; Restored=$restored; Skipped=$skipped; Failed=$failed }
        Complete=($complete -and $failed -eq 0)
        Warnings=$comparison.Warnings
    }
}

function ConvertTo-PitrCsvField {
    # CSV escaping plus neutralisation of spreadsheet formula prefixes.
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    if ($text.Length -gt 0 -and ($text[0] -in @('=','+','-','@') -or $text[0] -eq "`t" -or $text[0] -eq "`r")) { $text = "'" + $text }
    if ($text -match '[",\r\n]') { return '"' + $text.Replace('"','""') + '"' }
    return $text
}

function Export-PitrReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Report,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$false)][ValidateSet('Json','Csv','Text')][string]$Format='Json'
    )
    $full = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $full
    if ($directory -and -not [IO.Directory]::Exists($directory)) { $null=[IO.Directory]::CreateDirectory($directory) }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $text = ''
    if ($Format -eq 'Json') {
        $text = ($Report | ConvertTo-Json -Depth 8)
    } elseif ($Format -eq 'Csv') {
        $rows = @($Report.Entries)
        if ($rows.Count -eq 0) { $rows = @($Report.Actions) }
        $lines = New-Object 'Collections.Generic.List[string]'
        $lines.Add('Classification,SourceId,RelativePath,BackupLength,CurrentLength,BackupSha256,CurrentSha256,Error')
        foreach ($row in $rows) {
            $fields = @(
                (ConvertTo-PitrCsvField ([string]$row.Classification)),
                (ConvertTo-PitrCsvField ([string]$row.SourceId)),
                (ConvertTo-PitrCsvField ([string]$row.RelativePath)),
                (ConvertTo-PitrCsvField ([string]$row.BackupLength)),
                (ConvertTo-PitrCsvField ([string]$row.CurrentLength)),
                (ConvertTo-PitrCsvField ([string]$row.BackupSha256)),
                (ConvertTo-PitrCsvField ([string]$row.CurrentSha256)),
                (ConvertTo-PitrCsvField ([string]$row.Error))
            )
            $lines.Add(($fields -join ','))
        }
        $text = ($lines -join "`r`n") + "`r`n"
    } else {
        $builder = New-Object Text.StringBuilder
        $null = $builder.AppendLine('Windows PITR Config - local report (may contain private file names)')
        $null = $builder.AppendLine('BackupId: ' + [string]$Report.BackupId)
        if ($null -ne $Report.PSObject.Properties['Summary']) {
            $null = $builder.AppendLine('Summary: ' + ($Report.Summary | ConvertTo-Json -Compress))
        }
        foreach ($row in @($Report.Entries) + @($Report.Actions)) {
            if ($null -eq $row) { continue }
            $null = $builder.AppendLine(([string]$row.Classification) + "`t" + ([string]$row.RelativePath) + "`t" + ([string]$row.Result) + "`t" + ([string]$row.Error))
        }
        $text = $builder.ToString()
    }
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($full) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary,$text,$utf8)
        if ([IO.File]::Exists($full)) { [IO.File]::Replace($temporary,$full,$null) } else { [IO.File]::Move($temporary,$full) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    return $full
}
