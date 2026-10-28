$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$md=Join-Path $root 'USER-GUIDE.md'
$htmlPath=Join-Path $root 'USER-GUIDE.html'
foreach($path in @($md,$htmlPath)) { if(-not [IO.File]::Exists($path)) { throw ('RED: shipped guide missing: '+$path) } }
$text=[IO.File]::ReadAllText($md,[Text.Encoding]::UTF8)
$html=[IO.File]::ReadAllText($htmlPath,[Text.Encoding]::UTF8)

# Basic and advanced halves must exist, in that order, as real sections.
$basic=$text.IndexOf('## 2. Basic use',[StringComparison]::Ordinal)
$advanced=$text.IndexOf('## 3. Advanced use',[StringComparison]::Ordinal)
if($basic -lt 0 -or $advanced -lt 0 -or $basic -gt $advanced) { throw 'Guide must separate basic use from advanced use, basic first.' }
$basicHalf=$text.Substring($basic,$advanced-$basic)
$advancedHalf=$text.Substring($advanced)
foreach($topic in @('Back up files','Restore files','Restore points')) {
    if($basicHalf -notmatch [regex]::Escape($topic)) { throw ('Basic half omits a core tab: '+$topic) }
}
foreach($topic in @('Backup scope','Advanced restore controls','Reports and privacy','Command line - Windows PITR','Command line - file backup','Independent recovery package','Startup automation','Troubleshooting','Limits of this testing build')) {
    if($advancedHalf -notmatch [regex]::Escape($topic)) { throw ('Advanced half omits a feature: '+$topic) }
}
foreach($flag in @('pitr-config.cmd apply','pitr-config.cmd snapshot','pitr-config.cmd autostart','pitr-config.cmd idle','backup verify','recover restore','--alternate-root','--dry-run','--execute','Exit codes')) {
    if($text -notmatch [regex]::Escape($flag)) { throw ('Guide omits documented capability: '+$flag) }
}
if($text -notmatch 'UAC approval or cancellation on your account' -or $text -notmatch 'not proof of the following') { throw 'Guide must keep the unproven-live-limits statement.' }

# The HTML copy must be self-contained: no scripts, no network assets, real structure.
if($html -match '<script' -or $html -match '(?i)(src|href)\s*=\s*"(?!#)(https?:)?//') { throw 'Guide HTML must not load scripts or network resources.' }
foreach($tag in @('<table>','<h2','<pre>','</html>')) { if(-not $html.Contains($tag)) { throw ('Guide HTML is not a complete document: missing '+$tag) } }
if($html -match '\*\*' -or $html -match '(?<![\w*])\*[A-Za-z][^*<\r\n]{0,40}\*(?![\w*])') { throw 'Guide HTML still shows raw markdown emphasis markers.' }
foreach($tag in @('<em>','<strong>')) { if(-not $html.Contains($tag)) { throw ('Guide HTML lost inline formatting: missing '+$tag) } }
foreach($topic in @('Basic use','Advanced use','Combine','Restore points')) { if($html -notmatch [regex]::Escape($topic)) { throw ('Guide HTML omits: '+$topic) } }
if($html -notmatch 'id="2-basic-use"' -or $html -notmatch 'id="3-advanced-use"') { throw 'Guide HTML anchors for basic/advanced sections are missing.' }

# Both the window and the build must reference the shipped guide.
$ui=[IO.File]::ReadAllText((Join-Path $root 'src/backup/Ui.ps1'),[Text.Encoding]::UTF8)
if($ui -notmatch 'USER-GUIDE\.html') { throw 'The unified window does not point at the shipped guide.' }
$builder=[IO.File]::ReadAllText((Join-Path $root 'tools/Build-Portable.ps1'),[Text.Encoding]::UTF8)
foreach($member in @('USER-GUIDE.md','USER-GUIDE.html')) { if($builder -notmatch [regex]::Escape($member)) { throw ('Portable build does not package '+$member) } }
$readme=[IO.File]::ReadAllText((Join-Path $root 'README.md'),[Text.Encoding]::UTF8)
if($readme -notmatch 'USER-GUIDE\.md') { throw 'README does not link the guide.' }
Write-Output 'Guide contracts passed: basic/advanced halves, all tabs and CLI capabilities, self-contained HTML, packaged and referenced.'
