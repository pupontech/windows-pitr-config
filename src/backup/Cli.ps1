# Pure parser: filenames are values, never PowerShell expressions.
function ConvertFrom-PitrCommandLine {
    param([string[]]$Tokens = @())
    $o = [pscustomobject]@{
        Command='help'; Action='help'; Destination=$null; Scope='Complete'; ManifestPath=$null
        Format='Json'; VerificationMode='Full'; Conflict='Skip'; AlternateRoot=$null
        Gui=$false; Deep=$false; Execute=$false; DryRun=$false; AllowAdvanced=$false
        Mappings=@{}; EntryIds=@(); ProfileSids=@(); CustomPaths=@(); OutputPath=$null
        Help=$false; Resume=$false
    }
    if ($Tokens.Count -eq 0) { $o.Help=$true; return $o }
    if ($Tokens[0] -in @('help','--help','-h','/?')) { $o.Help=$true; return $o }
    $o.Command = $Tokens[0].ToLowerInvariant()
    if ($o.Command -notin @('backup','recover')) { throw 'Expected backup or recover. Use --help.' }
    $o.Action = if ($o.Command -eq 'backup') { 'create' } else { 'compare' }
    $i=1
    if ($Tokens.Count -gt 1 -and -not $Tokens[1].StartsWith('--')) {
        $o.Action=$Tokens[1].ToLowerInvariant(); $i=2
    }
    $validActions = if ($o.Command -eq 'backup') { @('create','verify','resume','list') } else { @('compare','restore') }
    if ($o.Action -notin $validActions) { throw ('Unsupported action: ' + $o.Action) }
    $seen=@{}
    for (; $i -lt $Tokens.Count; $i++) {
        $key=$Tokens[$i].ToLowerInvariant()
        if ($key -in @('--help','-h')) { $o.Help=$true; continue }
        $repeatable=$key -in @('--mapping','--entry','--profile','--folder')
        if ($seen.ContainsKey($key) -and -not $repeatable) { throw ('Duplicate option: ' + $key) }
        $seen[$key]=$true
        switch ($key) {
            '--gui' { $o.Gui=$true; continue }
            '--deep' { $o.Deep=$true; continue }
            '--execute' { $o.Execute=$true; continue }
            '--dry-run' { $o.DryRun=$true; continue }
            '--allow-advanced' { $o.AllowAdvanced=$true; continue }
        }
        if ($key -in @('--gui','--deep','--execute','--dry-run','--allow-advanced')) { continue }
        if ($key -notin @('--destination','--scope','--manifest','--format','--verification','--conflict','--alternate-root','--mapping','--entry','--profile','--folder','--output')) { throw ('Unknown option: ' + $Tokens[$i]) }
        $i++
        if ($i -ge $Tokens.Count -or [string]::IsNullOrWhiteSpace($Tokens[$i]) -or $Tokens[$i].StartsWith('--')) { throw ('Missing value for ' + $key) }
        $value=$Tokens[$i]
        switch ($key) {
            '--destination' { $o.Destination=$value }
            '--manifest' { $o.ManifestPath=$value }
            '--output' { $o.OutputPath=$value }
            '--alternate-root' { $o.AlternateRoot=$value }
            '--entry' { $o.EntryIds += $value }
            '--profile' { $o.ProfileSids += $value }
            '--folder' { $o.CustomPaths += $value }
            '--scope' {
                switch ($value.ToLowerInvariant()) {
                    'all-users' { $o.Scope='Complete' }
                    'complete' { $o.Scope='Complete' }
                    'personal' { $o.Scope='Personal' }
                    'custom' { $o.Scope='Custom' }
                    default { throw 'Scope must be all-users, complete, personal or custom.' }
                }
            }
            '--format' {
                if ($value -notin @('json','csv','text')) { throw 'Format must be json, csv or text.' }
                $o.Format=(Get-Culture).TextInfo.ToTitleCase($value.ToLowerInvariant())
            }
            '--verification' {
                if ($value -notin @('quick','full')) { throw 'Verification must be quick or full.' }
                $o.VerificationMode=(Get-Culture).TextInfo.ToTitleCase($value.ToLowerInvariant())
            }
            '--conflict' {
                if ($value -notin @('skip','alongside','replace')) { throw 'Conflict must be skip, alongside or replace.' }
                $o.Conflict=(Get-Culture).TextInfo.ToTitleCase($value.ToLowerInvariant())
            }
            '--mapping' {
                $equal=$value.IndexOf('=')
                if ($equal -le 0 -or $equal -eq ($value.Length-1)) { throw 'Mapping syntax is SourceId=approved-current-folder.' }
                $id=$value.Substring(0,$equal)
                if ($o.Mappings.ContainsKey($id)) { throw ('Duplicate mapping: ' + $id) }
                $o.Mappings[$id]=$value.Substring($equal+1)
            }
        }
    }
    if ($o.Execute -and $o.DryRun) { throw 'Choose --execute or --dry-run, not both.' }
    if (($o.Execute -or $o.AllowAdvanced -or $seen.ContainsKey('--conflict')) -and ($o.Command -ne 'recover' -or $o.Action -ne 'restore')) { throw 'Recovery authorization options are only valid for recover restore.' }
    if ($o.Scope -eq 'Custom' -and $o.CustomPaths.Count -eq 0 -and $o.ProfileSids.Count -eq 0 -and -not $o.Gui) { throw 'Custom scope requires --folder or --profile.' }
    if ($Tokens.Count -eq 1) { $o.Gui=$true }
    return $o
}

function Get-PitrCommandHelp {
    @'
Windows PITR Config - user backup and selective recovery

pitr-config.cmd backup                         Open backup wizard
pitr-config.cmd backup --destination "E:\PITR-Backups" --scope all-users
pitr-config.cmd backup --destination "E:\PITR-Backups" --scope personal --profile SID
pitr-config.cmd backup --destination "E:\PITR-Backups" --scope custom --folder "C:\Data"
pitr-config.cmd backup verify --manifest "...\manifest.json" --verification full
pitr-config.cmd backup resume --manifest "...\manifest.json"
pitr-config.cmd backup list --destination "E:\PITR-Backups"
pitr-config.cmd recover --gui --manifest "...\manifest.json"
pitr-config.cmd recover compare --manifest "..." --mapping "SOURCE-ID=C:\Users\Name" --deep
pitr-config.cmd recover restore --manifest "..." --mapping "SOURCE-ID=C:\Users\Name" --entry FILE-ID --dry-run

Restoration is dry-run unless --execute is present. Select IDs explicitly.
--alternate-root DIR permits recovery to an approved alternate root.
--conflict skip|alongside|replace (default skip). Replace preserves current bytes.
--allow-advanced explicitly permits selected advanced content; prefer alternate root.
--format json|text|csv; --output PATH exports a local report. Paths may be private.
No unattended command prompts for elevation. Use an authorized elevated console
if permissions require it. CLI does not initiate PITR or a reboot.
Exit: 0 complete; 2 warnings/incomplete; 3 invalid input/operation failure;
4 verification failure; 5 missing explicit recovery authorization/selection.
Integrity verification does not guarantee application/database consistency.
'@
}
