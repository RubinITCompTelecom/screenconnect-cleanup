$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'gui\Gui.Core.psm1') -Force
$child=[pscustomobject]@{Finished=$false;Tail='Awaiting technician approval';LastOutputUtc=[datetime]::UtcNow.AddSeconds(-10);DismissedTail='';DismissedUtc=$null}
if(-not (Get-GuiPendingPrompt -Child $child)){throw 'Punctuation-free prompt has no answer box'}
foreach($text in @('  [snapshot before] 3/12 sections, 45s elapsed','45%','Collecting processes...')){
    $child.Tail=$text
    if(Get-GuiPendingPrompt -Child $child){throw ('Progress was mistaken for input: '+$text)}
}
Write-Host 'PASS: unknown prompts retain their fallback while recognized progress stays quiet.'
