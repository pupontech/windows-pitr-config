$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/backup/Ui.ps1')
function Assert($ok,[string]$message) { if(-not $ok) { throw $message } }
[xml]$xml=Get-PitrBackupXaml
function Node([string]$name) { $xml.SelectSingleNode('//*[@*[local-name()="Name"]="'+$name+'"]') }
Assert ($null -ne (Node 'BackupFolders')) 'RED: folder selection must be tucked under Change folders.'
Assert ((Node 'BackupFolders').LocalName -eq 'Expander' -and (Node 'BackupFolders').GetAttribute('IsExpanded') -eq 'False') 'Folder choices must be collapsed initially.'
foreach($name in @('Scope','CustomPaths','ConflictPolicy','AllowAdvanced','AlternateRoot','ClassificationFilter','ManifestPath','ExportFormat')) {
    Assert ($null -ne (Node $name).SelectSingleNode('ancestor::*[local-name()="Expander"]')) ('Technical control must be under an expander: '+$name)
}
foreach($name in @('ChooseBackup','MappingsApproved','FindMissing','ShowDetails')) { Assert ($null -ne (Node $name)) ('Missing simple action: '+$name) }
Assert ((Node 'StartBackup').GetAttribute('Content') -eq 'Start backup') 'Simple backup action must be labelled Start backup.'
Assert ((Node 'FindMissing').GetAttribute('Content') -eq 'Find missing files') 'Simple compare action must use plain language.'
Assert ((Node 'RecoverFiles').GetAttribute('Content') -eq 'Restore selected files...') 'Simple restore action must use plain language.'
Assert ($null -eq (Node 'Mappings').SelectSingleNode('.//*[local-name()="DataGridTextColumn" and @Header="SourceId"]')) 'Source IDs must not be exposed in the basic review table.'
Write-Output 'Simple layout contracts passed.'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('pitr-simple-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try {
    $dated=Join-Path $fixture 'dated'; $null=[IO.Directory]::CreateDirectory($dated)
    [IO.File]::WriteAllText((Join-Path $dated 'manifest.json'),'{}')
    Assert ((Resolve-PitrUiBackupFolder -Path $dated) -eq (Join-Path $dated 'manifest.json')) 'Folder chooser must locate the direct generation manifest.'
    $refused=$false; try { $null=Resolve-PitrUiBackupFolder -Path $fixture } catch { $refused=$true }
    Assert $refused 'Parent containing dated generations must not silently choose a backup.'
    $user=Join-Path $fixture 'user'; $null=[IO.Directory]::CreateDirectory($user)
    $manifest=[pscustomobject]@{Sources=@(
        [pscustomobject]@{Id='same';ProfileSid='sid-one';Category='Profile';Path='C:\Users\Old'},
        [pscustomobject]@{Id='other';ProfileSid='sid-two';Category='Profile';Path=$user},
        [pscustomobject]@{Id='extra';ProfileSid=$null;Category='Extra';Path=$user},
        [pscustomobject]@{Id='personal';ProfileSid='sid-one';Category='Personal';Path='C:\Users\Old\Documents'}
    )}
    $profiles=@([pscustomobject]@{Sid='sid-one';Path=$user;Inaccessible=$false})
    $rows=@(Get-PitrUiMappingSuggestions -Manifest $manifest -Profiles $profiles)
    Assert ($rows.Count -eq 4 -and $rows[0].TargetRoot -eq $user) 'Same SID profile must get a suggestion.'
    Assert ($rows[1].TargetRoot -eq '' -and $rows[2].TargetRoot -eq '' -and $rows[3].TargetRoot -eq '') 'Do not guess from names, old paths, custom sources or personal-folder suffixes.'
    $duplicate=@(Get-PitrUiMappingSuggestions -Manifest $manifest -Profiles @($profiles[0],$profiles[0]))
    Assert ($duplicate[0].TargetRoot -eq '') 'Ambiguous SID must not be automatically mapped.'
    $profiles[0].Inaccessible=$true
    $locked=@(Get-PitrUiMappingSuggestions -Manifest $manifest -Profiles $profiles)
    Assert ($locked[0].TargetRoot -eq '') 'Unreadable profile must not be suggested.'
} finally { if([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture,$true) } }
Write-Output 'Folder selection and identity-only mapping suggestions passed.'
$report=[pscustomobject]@{ManifestPath='E:\Backup\manifest.json';Warnings=@('Unreadable source');Actions=@([pscustomobject]@{RelativePath='one.txt';Result='Skipped';Error='Existing file kept'})}
$details=Get-PitrUiReportDetails -Report $report -Status 'Preview ready'
Assert ($details -match 'one.txt' -and $details -match 'Existing file kept' -and $details -match 'Unreadable source' -and $details -match 'manifest.json') 'Details must expose paths, warnings, skipped actions and reasons.'
Write-Output 'Plain details preserve warning and action evidence.'
$many=New-Object Collections.ArrayList
for($i=0;$i -lt 205;$i++) { $null=$many.Add([pscustomobject]@{RelativePath=('routine-'+$i);Result='Succeeded';Error=$null}) }
$null=$many.Add([pscustomobject]@{RelativePath='late-failure.txt';Result='Failed';Error='late critical reason'})
$large=[pscustomobject]@{Actions=$many.ToArray();Warnings=@()}
$largeDetails=Get-PitrUiReportDetails -Report $large -Status 'Restore has problems'
Assert ($largeDetails -match 'late critical reason' -and $largeDetails -match 'late-failure.txt') 'RED: details must not hide failures after 200 routine actions.'
