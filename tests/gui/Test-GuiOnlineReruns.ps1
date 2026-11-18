# Real directory reservations, report generation and persistence WhatIf; no scans/removal/upload.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repo 'gui/Gui.Core.psm1') -Force
$work = Join-Path $env:TEMP ('scc-online-rerun-' + [guid]::NewGuid().ToString('N'))
function Check { param([bool]$Ok,[string]$Message) if (-not $Ok) { throw $Message }; Write-Host ('PASS: ' + $Message) }
function Run-Child {
    param([string]$Script,$Arguments)
    $child = Start-GuiChild -ScriptPath $Script -ArgumentList $Arguments -WorkingDirectory $repo
    $end = (Get-Date).AddSeconds(45)
    do { Start-Sleep -Milliseconds 40; $update = Update-GuiChild $child } until ($update.Exited -or (Get-Date) -gt $end)
    if (-not $update.Exited) { Stop-GuiChild $child; throw 'Fixture child timed out' }
    return [int]$update.ExitCode
}
try {
    # Adapt ownership in a throwaway module only, as the existing phase-split harness does.
    $tool = Join-Path $work 'tool'
    $null = New-Item -ItemType Directory -Path (Join-Path $tool 'tools') -Force
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $security = [IO.File]::ReadAllText((Join-Path $repo 'tools/RunRootSecurity.psm1'))
    $security = $security.Replace("`$script:SccTrustedWriterSids = @('S-1-5-32-544', 'S-1-5-18')", "`$script:SccTrustedWriterSids = @('$me', 'S-1-5-32-544', 'S-1-5-18')").Replace("`$script:SccRunRootOwnerSid = 'S-1-5-32-544'", "`$script:SccRunRootOwnerSid = '$me'")
    [IO.File]::WriteAllText((Join-Path $tool 'tools/RunRootSecurity.psm1'), $security)
    Import-Module (Join-Path $tool 'tools/RunRootSecurity.psm1') -Force
    foreach ($name in @('New-InvestigationReport.ps1','Write-ScannerSummary.ps1')) { Copy-Item -LiteralPath (Join-Path $repo $name) -Destination (Join-Path $tool $name) }
    '# Never executed: upload is intercepted at the action boundary.' | Set-Content -LiteralPath (Join-Path $tool 'Submit-ConnectWiseReport.ps1') -Encoding ASCII
    $run = New-SccProtectedRunRoot -Root (Join-Path $work 'runs')
    $findings = Join-Path $run 'findings.json'
    '{"ComputerName":"FIXTURE","ScreenConnect":{"Instances":[],"ParseIssues":[]},"OtherTargets":[]}' | Set-Content -LiteralPath $findings -Encoding ASCII
    $null = New-Item -ItemType Directory -Path (Join-Path $run 'after-scans/persistence') -Force
    'earlier partial collection' | Set-Content -LiteralPath (Join-Path $run 'after-scans/persistence/collection-progress.log') -Encoding ASCII
    'offline report sentinel' | Set-Content -LiteralPath (Join-Path $run 'report.html') -Encoding ASCII
    'earlier online report sentinel' | Set-Content -LiteralPath (Join-Path $run 'report-after-scans.html') -Encoding ASCII
    'offline scanner summary sentinel' | Set-Content -LiteralPath (Join-Path $run 'scanner_results.json') -Encoding ASCII
    $prior = [pscustomobject]@{RunRoot=$run; FindingsJson=$findings}
    $session = New-GuiSession -Mode Online -ToolRoot $tool -RitRoot $work -Answers @{ScanKvrt=$false; ScanEset=$false; ScanMalwarebytes=$false}
    [void](Initialize-GuiRunRoot -Session $session -Prior $prior)
    Check ((Split-Path -Leaf $session.OnlineWorkDir) -eq 'after-scans-2') 'partial earlier attempt is preserved and bypassed'
    Check ((Expand-GuiTokens $session '{ScanWorkDir}') -eq $session.OnlineWorkDir) 'scanner results belong to the current attempt'
    $session.Plan = @($session.Plan | Where-Object { $_.StepId -in '6a','6b','6c','9r','9o' })
    $sawShare = $false
    while ($null -ne ($action = Get-GuiNextAction $session)) {
        if ($action.StepId -eq '9o') {
            $sawShare = $true
            Check (($action.Args -join ' ') -like '*report-after-scans-2.html*' -and ($action.Args -join ' ') -like '*after-scans-2\persistence\result.json*') 'sharing binds the new report and current persistence evidence'
            [void](Complete-GuiAction $session $action -ExitCode 0)
        } else {
            $rc = Run-Child $action.ScriptPath $action.Args
            Check ($rc -eq 0) 'current scanner summary and report can be built with missing persistence evidence'
            [void](Complete-GuiAction $session $action -ExitCode $rc)
        }
    }
    Check $sawShare 'fresh warning report is eligible for sharing without falling back to Offline'
    $html = [IO.File]::ReadAllText((Expand-GuiTokens $session '{ShareReport}'))
    Check ($html.Contains('Missing or unavailable') -and $html.Contains('Skipped')) 'new report states missing persistence and skipped scanners'
    Check (([IO.File]::ReadAllText((Join-Path $run 'scanner_results.json'))).Trim() -eq 'offline scanner summary sentinel') 'Offline scanner summary is not overwritten'
    $summary = Get-Content -LiteralPath (Join-Path $session.OnlineWorkDir 'scanner_results.json') -Raw | ConvertFrom-Json
    Check (@($summary | Where-Object { $_.Status -eq 'Skipped' }).Count -eq 3) 'current scanner summary cannot inherit earlier success'

    $failed = New-GuiSession -Mode Online -ToolRoot $tool -RitRoot $work
    [void](Initialize-GuiRunRoot -Session $failed -Prior $prior)
    Check ((Split-Path -Leaf $failed.OnlineWorkDir) -eq 'after-scans-3') 'another Online run reserves another fresh attempt'
    $failed.Plan = @($failed.Plan | Where-Object { $_.StepId -in '9r','9o' })
    $action = Get-GuiNextAction $failed
    [void](Complete-GuiAction $failed $action -ExitCode 0) # summary boundary
    $action = Get-GuiNextAction $failed
    $partialReport = Expand-GuiTokens $failed '{OnlineReport}'
    'partial report sentinel' | Set-Content -LiteralPath $partialReport -Encoding ASCII
    [void](Complete-GuiAction $failed $action -ExitCode 1)
    Check (-not $failed.AfterScansReportReady -and $failed.PipeRc -ne 0) 'failed report is not accepted just because a file exists'
    Check ($null -eq (Get-GuiNextAction $failed)) 'report failure prevents upload of both partial and Offline reports'

    $persist = Join-Path $repo 'Invoke-PersistenceScan.ps1'
    Check ((Run-Child $persist @('-WorkDir',$failed.OnlineWorkDir,'-WhatIf')) -eq 0) 'real persistence WhatIf accepts a fresh attempt'
    Check ((Run-Child $persist @('-WorkDir',$failed.OnlineWorkDir,'-WhatIf')) -ne 0) 'persistence overwrite protection remains in place'
    Check (([IO.File]::ReadAllText((Join-Path $run 'report.html'))).Trim() -eq 'offline report sentinel') 'Offline report is unchanged'
    Check (([IO.File]::ReadAllText((Join-Path $run 'report-after-scans.html'))).Trim() -eq 'earlier online report sentinel') 'earlier Online report is unchanged'
    Check (([IO.File]::ReadAllText((Join-Path $run 'after-scans/persistence/collection-progress.log'))).Trim() -eq 'earlier partial collection') 'interrupted evidence remains unchanged'
} finally {
    $expectedParent = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($work)
    if ($full.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $full) -match '^scc-online-rerun-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $full)) { Remove-Item -LiteralPath $full -Recurse -Force }
}
