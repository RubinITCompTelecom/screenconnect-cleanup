# collect-snapshot.ps1: the Administrators group is found by its well-known SID, not its
# English name (review #23), and processes/connections share one PID map instead of one
# CIM call per process and one Get-Process per connection. Static + function-level checks;
# no admin rights needed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$snap = Join-Path $repoRoot 'collect-snapshot.ps1'
$failures = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { Write-Host "PASS: $Name" } else { Write-Host "FAIL: $Name"; $script:failures++ }
}
function Get-FunctionText {
    param([string]$File, [string[]]$Names)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    $parts = foreach ($name in $Names) {
        $f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $f) { throw "function not found: $name" }
        $f.Extent.Text
    }
    return ($parts -join "`n")
}
$snapText = Get-Content -LiteralPath $snap -Raw
# ---- admin group by SID (#23) ----
$snapText = Get-Content -LiteralPath $snap -Raw
Check 'LocalAccounts: group resolved from S-1-5-32-544' ($snapText -match 'S-1-5-32-544')
Check 'LocalAccounts: no hard-coded English group name left in the queries' ($snapText -notmatch "Name=`"Administrators`"" -and $snapText -notmatch 'net localgroup Administrators')

# ---- PID map (optimization) ----
. ([scriptblock]::Create((Get-FunctionText $snap @('Test-IsAdmin', 'Get-ProcessInfoMap'))))
$script:ProcessInfoMap = $null
$m1 = Get-ProcessInfoMap; $m2 = Get-ProcessInfoMap
Check 'PID map: built once and reused' ([object]::ReferenceEquals($m1, $m2) -and $m1.ByPid.ContainsKey([int]$PID) -and $m1.ByPid[[int]$PID].Name)
$connBody = ([regex]::Match($snapText, '(?s)function Get-ConnectionsSection \{.*?\r?\n\}\r?\n')).Value
Check 'Connections: no Get-Process per connection' ($connBody -and $connBody -notmatch 'Get-Process\b')
$procBody = ([regex]::Match($snapText, '(?s)function Get-ProcessesSection \{.*?\r?\n\}\r?\n')).Value
Check 'Processes: owner comes from the PID map when elevated' ($procBody -match 'HaveOwners')


if ($failures -gt 0) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'All snapshot admin-SID / PID-map checks passed.'