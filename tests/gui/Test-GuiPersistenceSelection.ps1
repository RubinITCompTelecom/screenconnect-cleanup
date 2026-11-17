# Exercise the real dialog controls and prompt routing without running any removal.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'gui/Start-CleanupGui.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-PersistenceCandidateChecks','New-DialogWindow','Test-ButtonNeedsWord','Resolve-Prompt','Invoke-Tick')) {
    $fn = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$win = New-Object Windows.Window
function Get-Brush { param($Name) return [Windows.Media.Brushes]::Black }
function Set-ButtonStyle { param($Button,$Variant) }
function Add-ConsoleNote { param($Text) }
function Send-GuiAnswer { param($Child,$Text) $script:Sent = $Text }
function Check { param([bool]$Ok,[string]$Message) if (-not $Ok) { throw $Message }; Write-Host ('PASS: ' + $Message) }
$script:Child = [pscustomobject]@{}
$script:Choice = 'send'; $script:Tick = @('2','11'); $script:LastDetail = ''
function Show-Dialog {
    param($Id,$Title,$Message,$Detail,$Buttons,$Checks=@(),$TypeWord)
    $script:LastDetail = $Detail
    if ($Id -eq 'PersistRemove') { return $null }
    $dw = New-DialogWindow -Title $Title -Message $Message -Buttons $Buttons -Checks $Checks
    Check ($null -eq $dw.Tag.Text) 'candidate dialog has no numeric input field'
    Check ($dw.Tag.Checks.Count -eq 12) 'all candidates are available beyond the old 30-line tail'
    Check (@($dw.Tag.Checks.Values | Where-Object { $_.IsChecked }).Count -eq 0) 'every candidate starts unchecked'
    $scroll = @($dw.Content.Children | Where-Object { $_ -is [Windows.Controls.ScrollViewer] })[0]
    Check ($scroll.MaxHeight -eq 260 -and $scroll.Content.Children.Count -eq 12) 'candidate list scrolls with buttons outside it'
    foreach ($key in $script:Tick) { $dw.Tag.Checks[$key].IsChecked = $true }
    $values = @{}
    foreach ($key in $dw.Tag.Checks.Keys) { $values[$key] = [bool]$dw.Tag.Checks[$key].IsChecked }
    $dw.Close()
    if ($script:Choice -eq 'close') { return $null }
    return [pscustomobject]@{Value=$script:Choice; Checks=$values; Text='999'}
}
$outputText = "earlier inventory notes`n" + ((1..12 | ForEach-Object {
    "[$_] StartupFile`n    Target: C:\Startup\item$_.lnk`n    Command: C:\Tools\item$_.exe`n    Reason: heuristic; review only"
}) -join "`n") + "`n"
function Update-GuiChild { param($Child) return [pscustomobject]@{Lines=$script:PumpLines; Exited=$false} }
function Add-ConsoleLines { param($Lines) }
function Get-GuiPendingPrompt { param($Child) return $null }
function Update-ScanControls {}
$ui = @{StatusDetail=(New-Object Windows.Controls.TextBlock)}
$script:InDialog = $false
$script:Child = [pscustomobject]@{StartedUtc=[datetime]::UtcNow; LastOutputUtc=[datetime]::UtcNow}
$script:Action = [pscustomobject]@{Call=[pscustomobject]@{Prompts=@('PersistIndices','PersistRemove')}; StepId='6d'}
$script:PersistenceOutput = ''
$lines = @($outputText.TrimEnd() -split "`n")
$script:PumpLines = $lines[0..17]; Invoke-Tick
$script:PumpLines = $lines[18..($lines.Count - 1)]; Invoke-Tick
Check (@(Get-PersistenceCandidateChecks $script:PersistenceOutput).Count -eq 12) 'timer retains the current candidate list across output batches without using the console tail'
$pending = [pscustomobject]@{Kind='Known'; Row=[pscustomobject]@{Id='PersistIndices'; Refuse=''}}
Resolve-Prompt $pending
Check ($script:Sent -ceq '2,11') 'only ticked candidate indices reach the engine in display order'
Check ($script:PersistenceSelectionText.Contains('item11.lnk') -and -not $script:PersistenceSelectionText.Contains('item1.lnk')) 'confirmation retains exact selected targets'
$script:CloseLock = $false
Resolve-Prompt ([pscustomobject]@{Kind='Known'; Row=[pscustomobject]@{Id='PersistRemove'; Refuse=''}})
Check ($script:Sent -eq '' -and -not $script:CloseLock) 'closing final confirmation refuses removal'
Check ($script:LastDetail -ceq $script:PersistenceSelectionText) 'confirmation uses the full selected list'
foreach ($choice in @('skip','close','send')) {
    $script:Choice = $choice; $script:Tick = @()
    Resolve-Prompt $pending
    Check ($script:Sent -ceq '') ($choice + ' with no selection removes nothing')
}
foreach ($bad in @(
    $script:PersistenceOutput.Replace('[2]', '[3]'),
    $script:PersistenceOutput.Substring($script:PersistenceOutput.IndexOf('[2]')),
    $script:PersistenceOutput.Replace('    Reason: heuristic; review only', 'missing reason')
)) {
    Check (@(Get-PersistenceCandidateChecks $bad).Count -eq 0) 'incomplete or ambiguous candidate output cannot authorize selection'
}
$script:PersistenceOutput = 'unreadable output'
Resolve-Prompt $pending
Check ($script:Sent -ceq '') 'unreadable list sends the refusing answer'
$win.Close()
