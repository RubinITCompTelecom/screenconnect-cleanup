# Get-AVTools.ps1: a BITS job with no byte progress must be abandoned after
# ~60 s (and removed), not waited on for 20 minutes. No BITS job is created.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$path = Join-Path $repoRoot 'tools/Get-AVTools.ps1'
$source = [IO.File]::ReadAllText($path)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-BitsStall' }, $true)
if ($null -eq $fn) { throw 'Test-BitsStall is missing.' }
. ([scriptblock]::Create($fn.Extent.Text))

$failures = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { Write-Host "PASS: $Name" } else { Write-Host "FAIL: $Name"; $script:failures++ }
}
$t0 = Get-Date
$r = Test-BitsStall -Bytes 100 -LastBytes 50 -LastProgress $t0.AddSeconds(-500) -Now $t0
Check 'growing byte count is progress, never a stall' ($r.Progressed -and -not $r.Stalled)
$r = Test-BitsStall -Bytes 50 -LastBytes 50 -LastProgress $t0.AddSeconds(-30) -Now $t0
Check '30 s without progress is not yet a stall' (-not $r.Progressed -and -not $r.Stalled)
$r = Test-BitsStall -Bytes 50 -LastBytes 50 -LastProgress $t0.AddSeconds(-60) -Now $t0
Check '60 s without progress is a stall' ($r.Stalled)
$r = Test-BitsStall -Bytes 0 -LastBytes -1 -LastProgress $t0 -Now $t0
Check 'first sample (0 bytes) counts as progress' ($r.Progressed -and -not $r.Stalled)

Check 'download loop uses the stall check' ($source -match 'Test-BitsStall -Bytes')
Check 'stall limit is 60 seconds' ($source -match '\$script:BitsStallSeconds = 60\b')
Check 'failed BITS job is removed before the fallback' ($source -match 'Remove-BitsTransfer')
Check 'fallback to Invoke-WebRequest remains' ($source -match 'Invoke-WebRequest -Uri \$Url')
if ($failures) { throw "$failures BITS stall test(s) failed" }
Write-Host 'PASS: BITS stall handling'
