$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repo 'gui\Gui.Core.psm1') -Force
$s=New-GuiSession -Mode Online -ToolRoot $repo
foreach($r in @(@{StepId='6a';Status='Done';ExitCode=0;Message=''},@{StepId='6b';Status='Warn';ExitCode=$null;Message='not staged'},@{StepId='6c';Status='Skipped';ExitCode=$null;Message='declined'})){[void]$s.Results.Add([pscustomobject]$r)}
$states=& (Get-Module Gui.Core) {param($session) Resolve-GuiListToken -Session $session -Name ScannerStateArgs} $s
if(($states -join '|') -ne '-KvrtState|Exit:0|-EsetState|NotStaged|-MalwarebytesState|Skipped'){throw 'GUI lost scanner outcome states'}
# Exercise the actual state machine's missing prerequisite result, not only a
# constructed record: an unstaged scanner produces Warn with no child exit code.
$real=New-GuiSession -Mode Online -ToolRoot $repo
$real.Plan=@($real.Plan | Where-Object {$_.StepId -eq '6b'})
$real.Answers['ScanEset']=$true
$null=Get-GuiNextAction -Session $real
if($real.Results.Count -ne 1 -or $real.Results[0].Status -ne 'Warn' -or $null -ne $real.Results[0].ExitCode){throw 'Fixture must exercise an unstaged scanner without launching a child'}
$states=& (Get-Module Gui.Core) {param($session) Resolve-GuiListToken -Session $session -Name ScannerStateArgs} $real
if(($states -join '|') -ne '-KvrtState|NotRun|-EsetState|NotStaged|-MalwarebytesState|NotRun'){throw 'Unstaged GUI scanner was reported as a successful child exit'}
Write-Host 'PASS: GUI report arguments retain all scanner outcomes even when Malwarebytes is declined.'
