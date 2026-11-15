# test_av_uninstaller_product_count.ps1 - the AV-uninstall stage must work
# with 0, 1 and 2 installed products under strict mode (sc-cleanup.ps1 runs it
# under Set-StrictMode -Version 2.0; this test uses Latest, which is stricter).
# Discovery and the uninstall launch are stubbed: nothing reads the real
# registry and no uninstaller is started.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$avPath = Join-Path $repoRoot 'Invoke-AVUninstaller.ps1'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($avPath, [ref]$tokens, [ref]$errors)
$function = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-DiscoveredAvUninstall'
}, $true)
if ($null -eq $function) { throw 'Invoke-DiscoveredAvUninstall is missing.' }
. ([scriptblock]::Create($function.Extent.Text))

$script:failures = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { Write-Host ("PASS  " + $Name) }
    else { Write-Host ("FAIL  " + $Name); $script:failures++ }
}

function Say { param([string]$Message, [string]$Color = 'White') }
$script:stubProducts = @()
$script:sweepCalls = @()
function Get-InstalledAv {
    $out = @()
    foreach ($n in $script:stubProducts) {
        $out += [pscustomobject]@{ DisplayName = $n; UninstallString = 'C:\Program Files\X\uninst.exe'; Publisher = 'Vendor' }
    }
    return $out   # unrolled exactly like the real function
}
function Invoke-WithSweep {
    param($Product)
    $script:sweepCalls += $Product.DisplayName
    return [pscustomobject]@{ DisplayName = $Product.DisplayName; Status = 'ClosedByUser' }
}

Set-StrictMode -Version Latest
foreach ($listOnlyValue in @($false, $true)) {
    $ListOnly = $listOnlyValue
    foreach ($case in @(
        @{ Products = @(); Expect = 1; Status = 'NoneFound' },
        @{ Products = @('ESET Security'); Expect = 1; Status = $null },
        @{ Products = @('ESET Security', 'Malwarebytes'); Expect = 2; Status = $null }
    )) {
        $script:stubProducts = $case.Products
        $script:sweepCalls = @()
        $label = "$($case.Products.Count) product(s), ListOnly=$listOnlyValue"
        $results = $null
        $threw = $null
        try { $results = @(Invoke-DiscoveredAvUninstall) } catch { $threw = $_.Exception.Message }
        Check "$label does not throw under strict mode" ($null -eq $threw)
        if ($null -ne $threw) { Write-Host "      $threw"; continue }
        Check "$label returns $($case.Expect) result(s)" ($results.Count -eq $case.Expect)
        if ($case.Status) { Check "$label records $($case.Status)" ($results[0].Status -eq $case.Status) }
        $expectedLaunches = if ($listOnlyValue) { 0 } else { $case.Products.Count }
        Check "$label opens $expectedLaunches uninstaller(s)" (@($script:sweepCalls).Count -eq $expectedLaunches)
        $json = [pscustomobject]@{ Count = $results.Count; Results = $results } | ConvertTo-Json -Depth 5 -Compress
        Check "$label serializes a results payload" ($json -match ('"Count":' + $case.Expect))
    }
}
Set-StrictMode -Off

# Real discovery against a stubbed registry: most Uninstall subkeys have no
# DisplayName at all, and reading one must not throw under strict mode.
foreach ($name in 'Get-RegValue', 'Test-IsInstalledAv', 'Get-InstalledAv') {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $fn) { throw "$name is missing." }
    . ([scriptblock]::Create($fn.Extent.Text))
}
$avKeywords = @('ESET', 'Windows Defender')
$osExclude = @('Windows Defender')
function Test-Path { param([string]$Path) return $true }
function Get-ItemProperty {
    param([string]$Path, $ErrorAction)
    if ($Path -notlike 'HKLM:\SOFTWARE\Microsoft\*') { return @() }
    return @(
        [pscustomobject]@{ PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\x\NoName' },
        [pscustomobject]@{ PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\x\ESET'; DisplayName = 'ESET Security'; UninstallString = 'MsiExec.exe /X{1}' }
    )
}
Set-StrictMode -Version Latest
$discovered = $null
$threw = $null
try { $discovered = @(Get-InstalledAv) } catch { $threw = $_.Exception.Message }
Set-StrictMode -Off
Check 'discovery skips a subkey with no DisplayName under strict mode' ($null -eq $threw)
Check 'discovery still finds the one AV product' (($null -eq $threw) -and $discovered.Count -eq 1 -and $discovered[0].DisplayName -eq 'ESET Security')
Remove-Item Function:\Test-Path, Function:\Get-ItemProperty

$source = [IO.File]::ReadAllText($avPath)
Check 'main path counts the discovery result through @(...)' ($source -match '\$av = @\(Get-InstalledAv\)')

Write-Host ''
if ($script:failures -eq 0) { Write-Host 'ALL AV UNINSTALLER COUNT TESTS PASSED' } else { Write-Host "$($script:failures) AV UNINSTALLER COUNT TEST(S) FAILED"; exit 1 }
