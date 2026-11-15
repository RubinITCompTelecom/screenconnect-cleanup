# test_clean_persistence.ps1 - Clean-Persistence (remove-screenconnect.ps1)
# (code review 2026-11-12, items 7 and 13).
#
# Item 7: a scheduled task whose action launches the ScreenConnect exe must be
# removed even when the install folder no longer exists (it has usually been
# quarantined before persistence is cleaned).
#
# Clean-Persistence and its helpers are loaded from the script's AST. The
# scheduled-task and CIM cmdlets are replaced by in-test functions that work on
# fake objects, and the Run-key sweep is pointed at a throwaway HKCU key, so
# no real task, Run key or WMI subscription is read or changed.
# PowerShell 5.1 compatible. Pure ASCII, no BOM.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'remove-screenconnect.ps1'

$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
foreach ($name in @('Expand-Env', 'Test-PathContained', 'Test-LiteralPathReference', 'Get-EntryPropertySafe', 'Clean-Persistence')) {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "$name not found in remove-screenconnect.ps1" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

$failures = New-Object System.Collections.Generic.List[string]
function Check {
    param([string]$Name, [bool]$Condition, [string]$Details)
    if ($Condition) { Write-Host ("PASS  " + $Name) }
    else {
        $message = "FAIL  " + $Name
        if ($Details) { $message += " - " + $Details }
        Write-Host $message
        $script:failures.Add($message)
    }
}

# --- stubs (functions win over cmdlets of the same name) -------------------
$script:Manifest = New-Object System.Collections.Generic.List[object]
$script:FakeTasks = @()
$script:Unregistered = New-Object System.Collections.Generic.List[string]
function Write-Log { param([string]$Message, [string]$Level = 'Info') }
function Add-ManifestEntry {
    param($InstanceId, $Action, $Target, $Result, $Details)
    $script:Manifest.Add([pscustomobject]@{ InstanceId = $InstanceId; Action = $Action; Target = $Target; Result = $Result; Details = $Details })
}
function Get-ScheduledTask { param([string]$ErrorAction) return $script:FakeTasks }
function Unregister-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath, [switch]$Confirm, [string]$ErrorAction)
    $script:Unregistered.Add($TaskPath + $TaskName)
}
function Get-CimInstance { param($Namespace, $ClassName, $Filter, $ErrorAction) return @() }
function Remove-CimInstance { throw 'Remove-CimInstance must not be reached in this test' }

function New-FakeTask {
    param([string]$Name, [object[]]$Actions)
    return [pscustomobject]@{ TaskName = $Name; TaskPath = '\'; Actions = $Actions }
}
function New-ExecAction {
    param([string]$Execute, [string]$Arguments)
    return [pscustomobject]@{ Execute = $Execute; Arguments = $Arguments }
}

$missingDir = 'C:\RIT-SCC-Test-' + [guid]::NewGuid().ToString('N') + '\ScreenConnect Client (abc123)'
if (Test-Path -LiteralPath $missingDir) { throw 'test install dir unexpectedly exists' }
$exe = $missingDir + '\ScreenConnect.ClientService.exe'

$script:FakeTasks = @(
    (New-FakeTask -Name 'SC-Exe' -Actions @(New-ExecAction -Execute $exe -Arguments '')),
    (New-FakeTask -Name 'SC-QuotedExe' -Actions @(New-ExecAction -Execute ('"' + $exe + '"') -Arguments '?e=Access')),
    (New-FakeTask -Name 'SC-InArgs' -Actions @(New-ExecAction -Execute 'cmd.exe' -Arguments ('/c start "" "' + $exe + '"'))),
    (New-FakeTask -Name 'Sibling-Folder' -Actions @(New-ExecAction -Execute ($missingDir + ' Evil\x.exe') -Arguments '')),
    (New-FakeTask -Name 'DotDot-Escape' -Actions @(New-ExecAction -Execute ($missingDir + '\..\other.exe') -Arguments '')),
    (New-FakeTask -Name 'Unrelated' -Actions @(New-ExecAction -Execute 'C:\Windows\System32\notepad.exe' -Arguments '')),
    (New-FakeTask -Name 'ComHandler' -Actions @([pscustomobject]@{ ClassId = '{00000000-0000-0000-0000-000000000000}'; Data = '' }))
)

$Execute = $true
$ok = Clean-Persistence -InstallDir $missingDir -InstanceId 'abc123' -RunKeys @()
$removed = @($script:Unregistered)
Check 'Clean-Persistence reports success' ($ok -eq $true) ''
Check 'task launching the exe is removed though the install folder is gone' ($removed -contains '\SC-Exe') ($removed -join ', ')
Check 'quoted Execute path is removed' ($removed -contains '\SC-QuotedExe') ($removed -join ', ')
Check 'exe referenced in Arguments is removed' ($removed -contains '\SC-InArgs') ($removed -join ', ')
Check 'sibling folder sharing a name prefix is kept' ($removed -notcontains '\Sibling-Folder') ($removed -join ', ')
Check '.. escaping the install folder is kept' ($removed -notcontains '\DotDot-Escape') ($removed -join ', ')
Check 'unrelated task is kept' ($removed -notcontains '\Unrelated') ($removed -join ', ')
Check 'COM-handler action does not fail the run' (@($script:Manifest | Where-Object { $_.Result -eq 'Failed' }).Count -eq 0) ''
Check 'three DeleteScheduledTask Success entries' (@($script:Manifest | Where-Object { $_.Action -eq 'DeleteScheduledTask' -and $_.Result -eq 'Success' }).Count -eq 3) ''

# Dry-run records the same matches without unregistering anything.
$script:Unregistered.Clear(); $script:Manifest.Clear()
$Execute = $false
$null = Clean-Persistence -InstallDir $missingDir -InstanceId 'abc123' -RunKeys @()
Check 'dry-run unregisters nothing' ($script:Unregistered.Count -eq 0) ''
Check 'dry-run records three DryRun task entries' (@($script:Manifest | Where-Object { $_.Action -eq 'DeleteScheduledTask' -and $_.Result -eq 'DryRun' }).Count -eq 3) ''

if ($failures.Count -gt 0) {
    Write-Host ("$($failures.Count) clean-persistence test(s) failed")
    exit 1
}
Write-Host 'ALL CLEAN-PERSISTENCE TESTS PASSED'
exit 0
