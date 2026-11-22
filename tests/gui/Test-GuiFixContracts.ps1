Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$core = [IO.File]::ReadAllText((Join-Path $root 'gui\Gui.Core.psm1'))
$gui = [IO.File]::ReadAllText((Join-Path $root 'gui\Start-CleanupGui.ps1'))
$json = Get-Content -LiteralPath (Join-Path $root 'gui\steps.json') -Raw | ConvertFrom-Json
$fail = New-Object System.Collections.ArrayList
function Check([bool]$ok, [string]$message) { if (-not $ok) { [void]$script:fail.Add($message); Write-Error $message -ErrorAction Continue } }
Check ($core.Contains('$verdict -eq ''INCOMPLETE''') -and $core.Contains('$verdict -eq ''RESURRECTION''')) 'diff verdicts distinguish incomplete from resurrection'
Check ($core.Contains('$ExitCode -ge 2') -and $core.Contains('Diff result could not be read')) 'diff failures and unreadable results are separately reported'
Check ($core.Contains("'ReportEvidenceArgs'") -and $core.Contains("'AfterScansReportArgs'")) 'report evidence tokens exist for guided and online reports'
$normal = @($json.Steps | Where-Object { $_.Id -eq '9a' })[0].Calls[1].Args
$online = @($json.Steps | Where-Object { $_.Id -eq '9r' })[0].Calls[1].Args
Check ($normal -contains '{@ReportEvidenceArgs}') 'guided GUI report passes optional evidence arguments'
Check ($online -contains '{@AfterScansReportArgs}') 'online GUI report passes same-run optional evidence arguments'
Check ($gui.Contains('Failed = 5; Resurrection = 4; Warn = 3; Cancelled = 2; Done = 1')) 'stepper displays worst call status'
Check ($gui.Contains('$rank[$r.Status] -gt $rank[$res[$r.StepId].Status]')) 'run summary preserves the worst status when combining call results'
Check ($gui.Contains('elseif ($script:ShareSkipped)')) 'skip message applies to one-go share step too'
Check ($gui.Contains('Staging incomplete. Missing:')) 'stage completion banner reflects missing files'
Import-Module (Join-Path $root 'gui\Gui.Core.psm1') -Force
$diffRoot = Join-Path $env:TEMP ('scc-gui-diff-fix-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $diffRoot -Force
try {
    # RESURRECTION is a finding, not a pipeline failure (same rule as sc-cleanup.ps1);
    # INCOMPLETE and unreadable results do change the run's exit status.
    foreach ($case in @(@('INCOMPLETE','Warn',1),@('RESURRECTION','Resurrection',0),@('INVALID','Warn',1))) {
        $diffPath = Join-Path $diffRoot 'snapshot_diff.json'
        if ($case[0] -eq 'INVALID') { Set-Content -LiteralPath $diffPath -Value '{broken' -Encoding ASCII }
        else { Set-Content -LiteralPath $diffPath -Value ('{"Verdict":"' + $case[0] + '"}') -Encoding ASCII }
        $session = New-GuiSession -Mode Offline -ToolRoot $root -RitRoot $diffRoot
        $session.RunRoot = $diffRoot
        $call = [pscustomobject]@{ OnNonZero = 'Diff' }
        $entry = [pscustomobject]@{ StepId = '8c'; StepTitle = 'Snapshot diff'; Call = $call; Destructive = $false }
        $action = [pscustomobject]@{ Call = $call; Entry = $entry; Index = 0; StepId = '8c' }
        [void](Complete-GuiAction -Session $session -Action $action -ExitCode 1)
        Check ($session.Results[0].Status -eq $case[1]) ('exit 1 verdict ' + $case[0] + ' maps to ' + $case[1])
        Check ((Get-GuiFinalStatus $session) -eq $case[2]) ('exit 1 verdict ' + $case[0] + ' gives run status ' + $case[2])
    }
} finally { Remove-Item -LiteralPath $diffRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($fail.Count) { exit 1 }
Write-Host 'GUI fix contract checks passed.' -ForegroundColor Green
exit 0

