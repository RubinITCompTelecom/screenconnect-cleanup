# Exercise continuation choices before any engine, scanner or run-folder creation.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ToolRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$RitRoot = 'C:\ContinuationTestNotCreated'
Import-Module (Join-Path $ToolRoot 'gui/Gui.Core.psm1') -Force
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ToolRoot 'gui/Start-CleanupGui.ps1'), [ref]$null, [ref]$null)
$fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-Run'}, $true)
. ([scriptblock]::Create($fn.Extent.Text))
$ui = @{CbShare=[pscustomobject]@{IsChecked=$true}}
$script:AutoStart = $false; $script:TestMode = $true
$script:Prior = [pscustomobject]@{RunRoot='C:\CompletedOfflineRun'; FindingsJson='C:\CompletedOfflineRun\detect\findings.json'}
function Get-TestAnswer { param($Id) return $null }
function Find-GuiPriorRun { param($Session) return $script:Prior }
function Show-Dialog {
    param($Id,$Title,$Message,$Detail,$Buttons)
    if ($Id -ne 'ContinuePrior') { throw 'Unexpected dialog' }
    $script:Message = $Message; $script:Buttons = $Buttons
    return $script:Response
}
function Initialize-GuiRunRoot {
    param($Session,$Prior)
    $script:InitCalls++; $script:BoundPrior = $Prior
    # Stop at the initialization boundary: no run folder or child is created.
    throw 'TEST: initialization boundary reached'
}
function Add-ConsoleNote { param($Text) }
function Check { param([bool]$Ok,[string]$Message) if (-not $Ok) { throw $Message }; Write-Host ('PASS: ' + $Message) }
$script:Response = [pscustomobject]@{Value='continue'}; $script:InitCalls = 0
Start-Run Online
Check ($script:InitCalls -eq 1 -and $script:BoundPrior -eq $script:Prior) 'Continue uses the completed Offline run'
Check (($script:Buttons.Text -join '|') -ceq 'Continue Offline run|Start separate scans|Cancel') 'buttons clearly name both choices and Cancel'
Check ($script:Message.Contains('The updated report is shared at the end.')) 'continuation explains sharing when ticked'
Check ($script:Message.Contains('Leave Offline results unchanged. No combined report or upload.')) 'separate scans explain the report consequence'
Check ($script:Message.Contains('Neither repeats ScreenConnect detection or removal.') -and $script:Message.Contains('KVRT can run again.')) 'prompt explains completed cleanup and optional scanner reruns'
$ui.CbShare.IsChecked = $false
Start-Run Online
Check ($script:Message.Contains('The updated report stays local because sharing is unticked.')) 'unticked sharing has its own explanation'
$script:Response = [pscustomobject]@{Value='new'}; $script:InitCalls = 0
Start-Run Online
Check ($script:InitCalls -eq 1 -and $null -eq $script:BoundPrior) 'separate scans do not bind the Offline run'
foreach ($choice in @($null,'cancel','unexpected')) {
    $script:Response = $(if ($null -eq $choice) { $null } else { [pscustomobject]@{Value=$choice} })
    $script:InitCalls = 0
    Start-Run Online
    Check ($script:InitCalls -eq 0) 'close, cancel or unknown choice starts nothing'
}
