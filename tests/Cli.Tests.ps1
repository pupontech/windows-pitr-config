$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cli = Join-Path $root 'src/backup/Cli.ps1'
if (-not (Test-Path -LiteralPath $cli)) { throw 'RED: CLI parser not implemented' }
. $cli
function Assert-True($Value, $Message) { if (-not $Value) { throw $Message } }
function Assert-Rejected([string[]]$Tokens) {
    $rejected = $false
    try { $null = ConvertFrom-PitrCommandLine -Tokens $Tokens } catch { $rejected = $true }
    Assert-True $rejected ('Expected rejection: ' + ($Tokens -join ' '))
}
$o = ConvertFrom-PitrCommandLine -Tokens @()
Assert-True ($o.Gui -and -not $o.Help -and $o.Command -eq 'backup' -and $o.Action -eq 'create') 'RED: double-click/no arguments must open the backup window, not print help and exit'
foreach($helpToken in @('--help','help','-h','/?')) {
    $helpOptions=ConvertFrom-PitrCommandLine -Tokens @($helpToken)
    Assert-True ($helpOptions.Help -and -not $helpOptions.Gui) 'Explicit help must remain noninteractive'
}
$o = ConvertFrom-PitrCommandLine -Tokens @('backup','--destination','E:\User Backups','--scope','all-users')
Assert-True ($o.Command -eq 'backup' -and $o.Action -eq 'create') 'backup route'
Assert-True ($o.Destination -eq 'E:\User Backups' -and $o.Scope -eq 'Complete') 'literal destination and scope'
$o = ConvertFrom-PitrCommandLine -Tokens @('recover','restore','--manifest','X:\a\manifest.json','--mapping','sid1=D:\Profiles\User A','--entry','a','--dry-run')
Assert-True (-not $o.Execute -and $o.Mappings['sid1'] -eq 'D:\Profiles\User A' -and $o.EntryIds[0] -eq 'a') 'safe restore defaults'
$o = ConvertFrom-PitrCommandLine -Tokens @('recover','compare','--manifest','a','--deep','--format','json')
Assert-True ($o.Deep -and $o.Format -eq 'Json') 'deep comparison'
$o = ConvertFrom-PitrCommandLine -Tokens @('backup')
Assert-True $o.Gui 'bare backup launches wizard'
Assert-Rejected @('backup','--unknown')
Assert-Rejected @('backup','--destination')
Assert-Rejected @('recover','restore','--execute','--dry-run')
Assert-Rejected @('recover','restore','--conflict','silently-overwrite')
Assert-Rejected @('backup','--scope','invented')
Assert-Rejected @('recover','--mapping','not-a-mapping')
Assert-Rejected @('recover','--mapping','a=X:\one','--mapping','a=X:\two')
Assert-Rejected @('recover','--manifest','a','--manifest','b')
Assert-Rejected @('backup','--destination','E:\a','extra')
Assert-Rejected @('backup','--scope','custom')
Assert-Rejected @('backup','--execute')
Assert-Rejected @('recover','compare','--execute')
Write-Output 'CLI parser assertions passed.'
