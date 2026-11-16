$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repo 'gui\Gui.Core.psm1') -Force
$s=New-GuiSession -Mode Online -ToolRoot $repo
foreach($r in @(@{StepId='6a';Status='Done';ExitCode=0;Message=''},@{StepId='6b';Status='Skipped';ExitCode=0;Message='not staged'},@{StepId='6c';Status='Skipped';ExitCode=0;Message='declined'})){[void]$s.Results.Add([pscustomobject]$r)}
$states=& (Get-Module Gui.Core) {param($session) Resolve-GuiListToken -Session $session -Name ScannerStateArgs} $s
if(($states -join '|') -ne '-KvrtState|Exit:0|-EsetState|NotStaged|-MalwarebytesState|Skipped'){throw 'GUI lost scanner outcome states'}
Write-Host 'PASS: GUI report arguments retain all scanner outcomes even when Malwarebytes is declined.'
