Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bat = [IO.File]::ReadAllText((Join-Path $root 'START-HERE.bat'))
$json = Get-Content -LiteralPath (Join-Path $root 'gui\steps.json') -Raw | ConvertFrom-Json
$core = [IO.File]::ReadAllText((Join-Path $root 'gui\Gui.Core.psm1'))
$gui = [IO.File]::ReadAllText((Join-Path $root 'gui\Start-CleanupGui.ps1'))
$pre = [IO.File]::ReadAllText((Join-Path $root 'preflight.ps1'))
$sc = [IO.File]::ReadAllText((Join-Path $root 'sc-cleanup.ps1'))
$fail = New-Object System.Collections.ArrayList
function Check([bool]$ok, [string]$message) { if (-not $ok) { [void]$script:fail.Add($message); Write-Error $message -ErrorAction Continue } }
Check ($bat.Contains('Diff INCOMPLETE - some evidence could not be collected')) 'batch labels INCOMPLETE distinctly'
Check ($bat.Contains('RESURRECTION DETECTED - removed items came back')) 'batch retains resurrection warning'
Check ($bat.Contains('Diff result could not be read after exit 1')) 'batch does not claim resurrection when diff output is unreadable'
Check ($bat.Contains('if "!PIPE_RC!"=="0" set "PIPE_RC=!SCC_DIFF_RC!"')) 'batch propagates nonzero diff without overwriting earlier failure'
Check ($bat.Contains('if "!PIPE_RC!"=="0" set "PIPE_RC=!SCC_AFTER_RC!"')) 'batch propagates failed after snapshot'
Check ((-not $bat.Contains('SCC_DIFF_ARG')) -and $bat.Contains('!SCC_AVU_ARG!')) 'batch report paths always pass the diff and add optional AV evidence'
Check ($bat.Contains('-DiffPath "!SCC_RUN_ROOT!\snapshot_diff.json"') -and $bat.Contains('-AVUninstall "!SCC_RUN_ROOT!\logs\av-uninstall-results.json"')) 'batch uses known run-root evidence paths'
Check ($bat.Contains('explorer /select,"!SCC_RUN_ROOT!\report.html"') -and $bat.Contains('set "REPORT_OPENED=1"')) 'batch records attempted report open and uses backslash'
Check (-not $bat.Contains('if not errorlevel 1 set "REPORT_OPENED=1"')) 'batch no longer relies on explorer errorlevel'
foreach ($step in @($json.Steps | Where-Object { $_.Id -eq '8b' -or $_.Id -eq '8c' })) { Check ($step.Calls[0].OnNonZero -eq 'WarnPipe' -or $step.Calls[0].OnNonZero -eq 'Diff') ('GUI propagates ' + $step.Id + ' result') }
$stage = @($json.Steps | Where-Object { $_.Id -eq '1' })[0]
Check (@($stage.Calls | Where-Object { $_.OnNonZero -eq 'Warn' }).Count -eq 3) 'GUI staging calls warn on download failure'
Check ($core.Contains('$verdict -eq ''INCOMPLETE''') -and $core.Contains('$verdict -eq ''RESURRECTION''')) 'GUI reads the diff Verdict to distinguish outcomes'
Check ($core.Contains('DiffPath') -and $core.Contains('AVUninstall')) 'GUI report evidence arguments cover the diff and AV uninstall results'
Check ($gui.Contains('Failed = 5; Resurrection = 4; Warn = 3; Cancelled = 2; Done = 1')) 'GUI stepper chooses worst multi-call status'
Check ($gui.Contains('elseif ($script:ShareSkipped)')) 'GUI reports skipped upload for either share step'
Check ($gui.Contains('Staging incomplete. Missing:')) 'GUI stage banner names missing tools'
Check ($pre.Contains('& $ScriptPath -Verify -Quiet | Out-Null') -and $pre.Contains('$rc = $LASTEXITCODE')) 'preflight verification uses child exit code only'
Check ($sc.Contains('$ScriptVersion = ''1.8.13-beta.2''')) 'sc-cleanup version matches VERSION'
if ($fail.Count) { exit 1 }
Write-Host 'Launcher/gui fix contract checks passed.' -ForegroundColor Green
exit 0
