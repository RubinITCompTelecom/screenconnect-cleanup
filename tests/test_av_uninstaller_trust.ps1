# test_av_uninstaller_trust.ps1 - the AV uninstaller (runs elevated) must not
# trust sources the signed-in user can write:
#   - no HKCU uninstall entries,
#   - under ProgramData only "Package Cache" is an accepted uninstaller root,
#   - leftovers are swept only when the uninstall really finished (HKLM key
#     gone) and only by EXACT folder/shortcut name ("Typeset" is not ESET).
# Everything runs against throwaway folders; no registry is read, no
# uninstaller is launched.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$avPath = Join-Path $repoRoot 'Invoke-AVUninstaller.ps1'
$source = [IO.File]::ReadAllText($avPath)

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($avPath, [ref]$tokens, [ref]$errors)
foreach ($name in 'Get-RegValue', 'Test-IsInstalledAv', 'Get-InstalledAv', 'Test-PathContained', 'Test-AllowedAvPath',
                  'Get-LeftoverNames', 'Test-LeftoverNameMatch', 'Test-UninstallEntryGone', 'Clear-ProductLeftovers', 'Invoke-WithSweep') {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $fn) { throw "$name is missing." }
    . ([scriptblock]::Create($fn.Extent.Text))
}
$avKeywords = @('ESET', 'Malwarebytes', 'Windows Defender')
$osExclude = @('Windows Defender')
function Say { param([string]$Message, [string]$Color = 'White') }

$script:failures = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { Write-Host ("PASS  " + $Name) }
    else { Write-Host ("FAIL  " + $Name); $script:failures++ }
}

$tmpRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$tmp = Join-Path $tmpRoot ('scc-av-trust-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp -Force
$savedEnv = @{}
foreach ($v in 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramData', 'APPDATA', 'TEMP') { $savedEnv[$v] = [Environment]::GetEnvironmentVariable($v, 'Process') }
try {
    # --- 1. no HKCU discovery ---------------------------------------------
    $script:queried = @()
    function Test-Path { param([string]$Path, [string]$LiteralPath) return $true }
    function Get-ItemProperty { param([string]$Path, $ErrorAction) $script:queried += $Path; return @() }
    $null = @(Get-InstalledAv)
    Remove-Item Function:\Test-Path, Function:\Get-ItemProperty
    Check 'discovery reads HKLM uninstall keys' (@($script:queried | Where-Object { $_ -like 'HKLM:*' }).Count -eq 2)
    Check 'discovery never reads HKCU uninstall keys' (@($script:queried | Where-Object { $_ -like 'HKCU:*' }).Count -eq 0)
    Check 'source has no HKCU uninstall key' ($source -notmatch "'HKCU:\\SOFTWARE")

    # --- 2. accepted uninstaller roots ------------------------------------
    $pf = Join-Path $tmp 'PF'; $pf86 = Join-Path $tmp 'PF86'; $pd = Join-Path $tmp 'PD'
    $appData = Join-Path $tmp 'AppData'; $userTemp = Join-Path $tmp 'Temp'
    foreach ($d in $pf, $pf86, $pd, $appData, $userTemp) { $null = New-Item -ItemType Directory -Path $d -Force }
    $env:ProgramFiles = $pf
    ${env:ProgramFiles(x86)} = $pf86
    $env:ProgramData = $pd
    $env:APPDATA = $appData
    $env:TEMP = $userTemp
    Check 'Program Files uninstaller accepted' (Test-AllowedAvPath -Path (Join-Path $pf 'ESET\uninstall.exe'))
    Check 'Program Files (x86) uninstaller accepted' (Test-AllowedAvPath -Path (Join-Path $pf86 'ESET\uninstall.exe'))
    Check 'ProgramData\Package Cache uninstaller accepted' (Test-AllowedAvPath -Path (Join-Path $pd 'Package Cache\{GUID}\setup.exe'))
    Check 'other ProgramData uninstaller rejected' (-not (Test-AllowedAvPath -Path (Join-Path $pd 'Evil\uninstall.exe')))
    Check 'ProgramData look-alike of Package Cache rejected' (-not (Test-AllowedAvPath -Path (Join-Path $pd 'Package Cache2\setup.exe')))
    Check 'ProgramData root itself rejected' (-not (Test-AllowedAvPath -Path (Join-Path $pd 'uninstall.exe')))

    # --- 3. exact-name leftover sweep -------------------------------------
    $startMenu = Join-Path $pd 'Microsoft\Windows\Start Menu\Programs'
    $userStartMenu = Join-Path $appData 'Microsoft\Windows\Start Menu\Programs'
    foreach ($d in (Join-Path $pf 'ESET'), (Join-Path $pf 'Typeset'), (Join-Path $pf86 'ESETTools'),
                   (Join-Path $startMenu 'ESET'), (Join-Path $startMenu 'Typeset'), $userStartMenu,
                   (Join-Path $userTemp 'ESET'), (Join-Path $userTemp 'Typesetter')) {
        $null = New-Item -ItemType Directory -Path $d -Force
    }
    Set-Content -LiteralPath (Join-Path $userStartMenu 'ESET Security.lnk') -Value 'x'
    Set-Content -LiteralPath (Join-Path $userStartMenu 'Typeset ESET helper.lnk') -Value 'x'
    $quarantine = Join-Path $tmp 'quarantine'
    $product = [pscustomobject]@{ DisplayName = 'ESET Security'; InstallLocation = $null; RegistryPath = $null }
    $moves = @(Clear-ProductLeftovers -Product $product -QuarantineRoot $quarantine)
    $moved = @($moves | Where-Object { $_.Status -eq 'MovedToQuarantine' } | ForEach-Object { Split-Path -Leaf $_.Source })
    Check 'exact-name Program Files folder ESET swept' (-not (Test-Path -LiteralPath (Join-Path $pf 'ESET')))
    Check 'Program Files Typeset NOT swept' (Test-Path -LiteralPath (Join-Path $pf 'Typeset'))
    Check 'Program Files (x86) ESETTools NOT swept' (Test-Path -LiteralPath (Join-Path $pf86 'ESETTools'))
    Check 'Start Menu ESET folder swept' (-not (Test-Path -LiteralPath (Join-Path $startMenu 'ESET')))
    Check 'Start Menu Typeset NOT swept' (Test-Path -LiteralPath (Join-Path $startMenu 'Typeset'))
    Check 'shortcut named exactly after the product swept' (-not (Test-Path -LiteralPath (Join-Path $userStartMenu 'ESET Security.lnk')))
    Check 'shortcut that only contains ESET NOT swept' (Test-Path -LiteralPath (Join-Path $userStartMenu 'Typeset ESET helper.lnk'))
    Check 'temp ESET folder swept' (-not (Test-Path -LiteralPath (Join-Path $userTemp 'ESET')))
    Check 'temp Typesetter NOT swept' (Test-Path -LiteralPath (Join-Path $userTemp 'Typesetter'))
    Check 'exactly four leftovers moved' ($moved.Count -eq 4)
    Check 'source has no wildcard keyword match' ($source -notmatch '\$_\.Name -like \("\*" \+ \$kw')

    # A registry InstallLocation in user-creatable ProgramData is refused.
    $evilInstall = Join-Path $pd 'ESET'
    $null = New-Item -ItemType Directory -Path $evilInstall -Force
    $moves = @(Clear-ProductLeftovers -Product ([pscustomobject]@{ DisplayName = 'ESET Security'; InstallLocation = $evilInstall; RegistryPath = $null }) -QuarantineRoot $quarantine)
    Check 'InstallLocation under plain ProgramData NOT swept' (Test-Path -LiteralPath $evilInstall)

    # --- 4. sweep only when the uninstall key is really gone --------------
    $script:sweeps = 0
    $script:openStatus = 'ClosedByUser'
    function Open-Uninstaller { param($Product) return [pscustomobject]@{ DisplayName = $Product.DisplayName; Status = $script:openStatus } }
    function Clear-ProductLeftovers { param($Product, [string]$QuarantineRoot) $script:sweeps++; return @() }
    $NoLeftoverSweep = $false
    $quarantineRoot = $quarantine
    $fakeKey = Join-Path $tmp 'fake-uninstall-key'
    $null = New-Item -ItemType Directory -Path $fakeKey -Force
    $prod = [pscustomobject]@{ DisplayName = 'ESET Security'; RegistryPath = $fakeKey }

    $r = Invoke-WithSweep $prod
    Check 'closed but key still present: no sweep' ($script:sweeps -eq 0 -and ([string]$r.LeftoverSweep) -like 'Skipped:*')

    Remove-Item -LiteralPath $fakeKey -Force
    $script:openStatus = 'LaunchRejected'
    $r = Invoke-WithSweep $prod
    Check 'refused launch with key gone: no sweep' ($script:sweeps -eq 0 -and ([string]$r.LeftoverSweep) -like 'Skipped:*')

    $script:openStatus = 'TimeoutLeftRunning'
    $r = Invoke-WithSweep $prod
    Check 'timed-out uninstall: no sweep' ($script:sweeps -eq 0)

    $script:openStatus = 'ClosedByUser'
    $r = Invoke-WithSweep ([pscustomobject]@{ DisplayName = 'ESET Security'; RegistryPath = $null })
    Check 'no recorded uninstall key (cannot verify): no sweep' ($script:sweeps -eq 0 -and ([string]$r.LeftoverSweep) -like 'Skipped:*')

    $r = Invoke-WithSweep $prod
    Check 'closed and key gone: sweep runs' ($script:sweeps -eq 1 -and $r.LeftoverSweep -eq 'Ran')

    $NoLeftoverSweep = $true
    $null = Invoke-WithSweep $prod
    Check '-NoLeftoverSweep still skips the sweep' ($script:sweeps -eq 1)
} finally {
    foreach ($v in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($v, $savedEnv[$v], 'Process') }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -eq 0) { Write-Host 'ALL AV UNINSTALLER TRUST TESTS PASSED' } else { Write-Host "$($script:failures) AV UNINSTALLER TRUST TEST(S) FAILED"; exit 1 }
