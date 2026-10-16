# Portable CLI entry. Read-only modes never self-elevate or load WPF.
param()
$ErrorActionPreference='Stop'
$exitCode=3
try {
    . (Join-Path $PSScriptRoot 'Cli.ps1')
    $options=ConvertFrom-PitrCommandLine -Tokens ([string[]]$args)
    if($options.Help) { Write-Output (Get-PitrCommandHelp); exit 0 }
    if($options.Command -eq 'recover' -and $options.Action -eq 'restore' -and -not $options.Gui) {
        if($options.EntryIds.Count -eq 0 -or ($options.Mappings.Count -eq 0 -and -not $options.AlternateRoot)) {
            [Console]::Error.WriteLine('Recovery requires explicit --entry selection and approved --mapping or --alternate-root. Nothing changed.')
            exit 5
        }
    }
    $applicationRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    foreach($module in @('Platform','Manifest','Backup','Recovery')) {
        $modulePath=Join-Path $PSScriptRoot ($module+'.ps1')
        if(-not [IO.File]::Exists($modulePath)) { throw ('Application package incomplete: '+$module+'.ps1 missing.') }
        . $modulePath
    }
    if($options.Gui) {
        foreach($module in @('Localization','Ui')) { . (Join-Path $PSScriptRoot ($module+'.ps1')) }
        $mode=if($options.Command -eq 'recover') {'Recover'} elseif($options.Action -eq 'verify') {'Verify'} else {'Backup'}
        Show-PitrBackupUi -Mode $mode -ApplicationRoot $applicationRoot -ManifestPath $options.ManifestPath
        exit 0
    }
    $result=$null
    if($options.Command -eq 'backup') {
        switch($options.Action) {
            'create' {
                if(-not $options.Destination) { throw 'Backup requires --destination, or --gui.' }
                $profiles=@(Get-PitrProfiles)
                if($options.ProfileSids.Count -gt 0) {
                    foreach($sid in $options.ProfileSids) { if(@($profiles | Where-Object {$_.Sid -eq $sid}).Count -ne 1) { throw ('Profile SID not uniquely discovered: '+$sid) } }
                    $profiles=@($profiles | Where-Object {$options.ProfileSids -contains $_.Sid})
                } elseif($options.Scope -eq 'Custom') { $profiles=@() }
                $sources=@(Get-PitrSourceRoots -Profiles $profiles -Scope $options.Scope -CustomPaths $options.CustomPaths)
                if($sources.Count -eq 0) { throw 'No eligible source roots selected.' }
                $result=New-PitrBackup -Sources $sources -Destination $options.Destination -Scope $options.Scope -RecoverySource $applicationRoot
                if($result.State -eq 'CopyCompleted') {
                    if(-not $result.ManifestPath) { throw 'Backup engine did not return its manifest location.' }
                    $result=Test-PitrBackup -ManifestPath $result.ManifestPath -Mode $options.VerificationMode
                }
            }
            'verify' {
                if(-not $options.ManifestPath) { throw 'Verification requires --manifest.' }
                $result=Test-PitrBackup -ManifestPath $options.ManifestPath -Mode $options.VerificationMode
            }
            'resume' {
                if(-not $options.ManifestPath) { throw 'Resume requires --manifest.' }
                $result=Resume-PitrBackup -ManifestPath $options.ManifestPath
                if($result.State -eq 'CopyCompleted') { $result=Test-PitrBackup -ManifestPath $options.ManifestPath -Mode $options.VerificationMode }
            }
            'list' {
                if(-not $options.Destination) { throw 'List requires --destination.' }
                $root=[IO.Path]::GetFullPath($options.Destination)
                if(-not [IO.Directory]::Exists($root)) { throw 'Backup destination unavailable.' }
                $queue=New-Object 'Collections.Generic.Queue[string]'
                $queue.Enqueue($root)
                $backups=New-Object 'Collections.Generic.List[object]'
                $warnings=New-Object 'Collections.Generic.List[string]'
                while($queue.Count -gt 0) {
                    $folder=$queue.Dequeue()
                    try {
                        if(([IO.File]::GetAttributes($folder) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $warnings.Add('Reparse folder not scanned: '+$folder);continue }
                        $manifest=Join-Path $folder 'manifest.json'
                        if([IO.File]::Exists($manifest)) {
                            try { $m=Read-PitrManifest -ManifestPath $manifest;$backups.Add([pscustomobject]@{BackupId=$m.BackupId;State=$m.State;CreatedUtc=$m.CreatedUtc;ManifestPath=$manifest}) } catch { $warnings.Add('Unreadable manifest: '+$manifest+' : '+$_.Exception.Message) }
                            continue
                        }
                        foreach($child in [IO.Directory]::EnumerateDirectories($folder)) { $queue.Enqueue($child) }
                    } catch { $warnings.Add('Incomplete scan: '+$folder+' : '+$_.Exception.Message) }
                }
                $result=[pscustomobject]@{SchemaVersion=1;Backups=$backups.ToArray();Warnings=$warnings.ToArray();Complete=($warnings.Count -eq 0)}
            }
        }
    } else {
        if(-not $options.ManifestPath) { throw 'Comparison/recovery requires --manifest, or --gui.' }
        if($options.Action -eq 'compare') {
            $result=Compare-PitrBackup -ManifestPath $options.ManifestPath -Mappings $options.Mappings -Deep:$options.Deep
        } else {
            $parameters=@{ManifestPath=$options.ManifestPath;Mappings=$options.Mappings;EntryIds=$options.EntryIds;Conflict=$options.Conflict;Execute=$options.Execute;AllowAdvanced=$options.AllowAdvanced}
            if($options.AlternateRoot) { $parameters.AlternateRoot=$options.AlternateRoot }
            $result=Restore-PitrFiles @parameters
        }
    }
    if($null -eq $result) { throw 'Operation returned no structured result; completion is unknown.' }
    if($options.OutputPath) { Export-PitrReport -Report $result -Path $options.OutputPath -Format $options.Format }
    if($options.Format -eq 'Json') { $result | ConvertTo-Json -Depth 12 }
    elseif($options.Format -eq 'Csv') {
        if(-not $options.OutputPath) { throw 'CSV requires --output to avoid ambiguous nested result formatting.' }
        Write-Output ('Report saved locally: '+$options.OutputPath)
    } else { $result | Format-List | Out-String | Write-Output }
    $exitCode=0
    $stateProperty=$result.PSObject.Properties['State']
    if($stateProperty -and $result.State -notin @('Verified')) { $exitCode=2 }
    if($stateProperty -and $result.State -eq 'Failed') { $exitCode=4 }
    foreach($name in @('Complete','ScanComplete')) {
        $property=$result.PSObject.Properties[$name]
        if($property -and -not $property.Value) { $exitCode=2 }
    }
} catch {
    [Console]::Error.WriteLine('pitr-backup: '+$_.Exception.Message)
    $exitCode=3
}
exit $exitCode
