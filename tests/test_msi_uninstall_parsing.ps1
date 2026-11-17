<#
  Regression for the MSI uninstall-string parsing in remove-screenconnect.ps1
  (code review 2026-11-12, item 2).

  The old regex required a space after /X, so the standard
  "MsiExec.exe /X{GUID}" was not recognised (recorded Failed, run exit 1), and
  the "/X {GUID}" form captured the GUID WITHOUT braces, which msiexec does not
  accept as a ProductCode. Get-MsiProductCode must return the ProductCode with
  braces for every real-world form, and $null for anything else.

  Pure function test: nothing is executed, nothing on the host is touched.
  Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_msi_uninstall_parsing.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$RepoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $RepoRoot 'remove-screenconnect.ps1'

function Get-FunctionAst {
    param([string]$Path, [string]$Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    return $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
}

$fn = Get-FunctionAst -Path $scriptPath -Name 'Get-MsiProductCode'
if (-not $fn) { Write-Host 'FAIL: Get-MsiProductCode not found in remove-screenconnect.ps1'; exit 1 }
. ([scriptblock]::Create($fn.Extent.Text))

$failures = New-Object System.Collections.Generic.List[string]
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ceq $Actual) { Write-Host ('ok:   ' + $Message) }
    else { $script:failures.Add($Message); Write-Host ('FAIL: ' + $Message + ' (expected [' + $Expected + '], got [' + $Actual + '])') }
}

$g = '{0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9}'
$lower = $g.ToLowerInvariant()

Assert-Equal $g (Get-MsiProductCode -Command ('MsiExec.exe /X' + $g)) '/X{GUID} (no space, the standard form)'
Assert-Equal $g (Get-MsiProductCode -Command ('MsiExec.exe /X ' + $g)) '/X {GUID} keeps the braces'
Assert-Equal $g (Get-MsiProductCode -Command ('MsiExec.exe /I' + $g)) '/I{GUID} (modify entry point)'
Assert-Equal $g (Get-MsiProductCode -Command ('MsiExec.exe /i ' + $g)) '/i {GUID} lower-case switch'
Assert-Equal $g (Get-MsiProductCode -Command ('"C:\Windows\System32\MsiExec.exe" /X' + $g)) 'quoted full msiexec path'
Assert-Equal $g (Get-MsiProductCode -Command ('C:\Windows\system32\msiexec.exe /x' + $lower)) 'unquoted full path and lower-case GUID'
Assert-Equal $g (Get-MsiProductCode -Command ('msiexec /x' + $lower + ' /qn')) 'msiexec without .exe plus trailing flags'
Assert-Equal $g (Get-MsiProductCode -Command ('MsiExec.exe /norestart /X' + $g)) 'switch after another flag'

Assert-Equal $null (Get-MsiProductCode -Command '"C:\Program Files (x86)\ScreenConnect Client (x)\ScreenConnect.ClientService.exe" /s') 'non-MSI uninstaller is not MSI'
Assert-Equal $null (Get-MsiProductCode -Command ('C:\evil\notmsiexec-helper.exe /X' + $g)) 'msiexec only as part of another name is not MSI'
Assert-Equal $null (Get-MsiProductCode -Command 'MsiExec.exe /X{------------------------------------}') '36 dashes is not a GUID'
Assert-Equal $null (Get-MsiProductCode -Command 'MsiExec.exe /X{0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F}') 'short GUID is refused'
Assert-Equal $null (Get-MsiProductCode -Command '') 'empty string'
Assert-Equal $null (Get-MsiProductCode -Command $null) 'null'

# The value handed to msiexec is "/x " + ProductCode: braces must survive.
$code = Get-MsiProductCode -Command ('MsiExec.exe /X ' + $g)
Assert-Equal ('/x ' + $g + ' /qn /norestart') ('/x ' + $code + ' /qn /norestart') 'msiexec arguments carry the braced ProductCode'

# Source contract: a refused (unvalidated) uninstall string is Skipped, not
# Failed, and the old space-requiring regex is gone.
$src = Get-Content -LiteralPath $scriptPath -Raw
$refuseIdx = $src.IndexOf('UninstallString not validated')
$refuseLine = if ($refuseIdx -ge 0) { $src.Substring([Math]::Max(0, $refuseIdx - 200), 200) } else { '' }
Assert-Equal $true ($refuseLine -match "Result 'Skipped'") 'refused uninstall string is recorded as Skipped'
Assert-Equal $false ($src.Contains("'/x\s+\{([A-F0-9-]{36})\}'")) 'old brace-dropping regex removed'

if ($failures.Count -gt 0) { Write-Host ("`n" + $failures.Count + ' failure(s)') -ForegroundColor Red; exit 1 }
Write-Host "`nPASS: MSI uninstall strings parse to a braced ProductCode"
exit 0
