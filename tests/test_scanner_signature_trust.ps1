# test_scanner_signature_trust.ps1 - Invoke-GUIScanner.ps1 launches scanner
# EXEs elevated, so it must not trust user-writable places or unsigned files:
#   - KVRT/ESET are never picked up from Downloads or %TEMP%,
#   - every staged scanner / fallback installer needs a VALID Authenticode
#     signature whose signer organisation is the vendor (Malwarebytes /
#     Kaspersky / ESET),
#   - the Malwarebytes installer is downloaded into a fresh folder in the run
#     root that only Administrators and SYSTEM can write.
# Nothing is downloaded or launched.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$scannerPath = Join-Path $repoRoot 'Invoke-GUIScanner.ps1'
$source = [IO.File]::ReadAllText($scannerPath)

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scannerPath, [ref]$tokens, [ref]$errors)
foreach ($name in 'Get-SignerOrganization', 'Test-VendorSignature', 'New-LockedDownloadDir', 'Get-RunDownloadParent') {
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if ($null -eq $fn) { throw "$name is missing." }
    . ([scriptblock]::Create($fn.Extent.Text))
}
# The signer table is plain script-scope data; load it from the real file.
foreach ($var in 'VendorSignerPatterns', 'ScannerVendors') {
    $assign = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq ('$script:' + $var) }, $true)
    if ($null -eq $assign) { throw "`$script:$var is missing." }
    . ([scriptblock]::Create($assign.Extent.Text))
}

$script:failures = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { Write-Host ("PASS  " + $Name) }
    else { Write-Host ("FAIL  " + $Name); $script:failures++ }
}

# --- 1. no user-writable search locations ---------------------------------
Check 'KVRT/ESET lookup does not search Downloads' ($source -notmatch "Join-Path \`$homeDir \('Downloads")
Check 'KVRT/ESET lookup does not search %TEMP%' ($source -notmatch 'Join-Path \(Get-TempRoot\) \$name')
Check 'Malwarebytes fallback never stages under %TEMP%' ($source -notmatch 'ScreenConnectCleanup\\Malwarebytes')
Check 'fallback folder comes from the locked run-root helper' ($source -match 'New-LockedDownloadDir -Parent \(Get-RunDownloadParent -ResultPath \$ResultPath\)')
Check 'staged KVRT/ESET are signature-checked before launch' ($source -match 'Test-VendorSignature -Path \$target -Vendor \$script:ScannerVendors\[\$Scanner\]')
Check 'KVRT maps to Kaspersky, ESET to ESET' ($script:ScannerVendors['KVRT'] -eq 'Kaspersky' -and $script:ScannerVendors['ESET'] -eq 'ESET')

# --- 2. signer organisation parsing ---------------------------------------
Check 'plain O= parsed' ((Get-SignerOrganization 'CN=Malwarebytes Inc, O=Malwarebytes Inc, L=Santa Clara, C=US') -eq 'Malwarebytes Inc')
Check 'quoted O= with a comma parsed' ((Get-SignerOrganization 'CN="ESET, spol. s r.o.", O="ESET, spol. s r.o.", L=Bratislava, C=SK') -eq 'ESET, spol. s r.o.')
Check 'OU= is not mistaken for O=' ((Get-SignerOrganization 'CN=x, OU=ESET, O=Evil Corp') -eq 'Evil Corp')
Check 'no O= gives null' ($null -eq (Get-SignerOrganization 'CN=ESET'))

# --- 3. Test-VendorSignature with a stubbed Get-AuthenticodeSignature ------
$script:fakeSig = $null
function Get-AuthenticodeSignature {
    param([string]$LiteralPath, $ErrorAction)
    if ($script:fakeSig -eq 'throw') { throw 'synthetic signature read failure' }
    return $script:fakeSig
}
function New-FakeSig { param([string]$Status, [string]$Subject)
    $cert = $null
    if ($Subject) { $cert = [pscustomobject]@{ Subject = $Subject } }
    return [pscustomobject]@{ Status = $Status; SignerCertificate = $cert }
}
$cases = @(
    @{ N = 'valid Malwarebytes signer accepted';        V = 'Malwarebytes'; S = (New-FakeSig 'Valid' 'CN=Malwarebytes Inc, O=Malwarebytes Inc, C=US'); Ok = $true },
    @{ N = 'valid Kaspersky signer accepted';           V = 'Kaspersky';    S = (New-FakeSig 'Valid' 'CN=AO Kaspersky Lab, O=AO Kaspersky Lab, C=RU'); Ok = $true },
    @{ N = 'valid ESET signer accepted';                V = 'ESET';         S = (New-FakeSig 'Valid' 'CN="ESET, spol. s r.o.", O="ESET, spol. s r.o.", C=SK'); Ok = $true },
    @{ N = 'valid signature by another vendor rejected'; V = 'ESET';        S = (New-FakeSig 'Valid' 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'); Ok = $false },
    @{ N = 'look-alike signer rejected';                V = 'ESET';         S = (New-FakeSig 'Valid' 'CN=NotESET Ltd, O=NotESET Ltd'); Ok = $false },
    @{ N = 'vendor name only in CN rejected';           V = 'Malwarebytes'; S = (New-FakeSig 'Valid' 'CN=Malwarebytes, O=Planted Ltd'); Ok = $false },
    @{ N = 'unsigned file rejected';                    V = 'Malwarebytes'; S = (New-FakeSig 'NotSigned' $null); Ok = $false },
    @{ N = 'tampered (HashMismatch) file rejected';     V = 'Kaspersky';    S = (New-FakeSig 'HashMismatch' 'CN=AO Kaspersky Lab, O=AO Kaspersky Lab'); Ok = $false },
    @{ N = 'untrusted root rejected';                   V = 'Kaspersky';    S = (New-FakeSig 'UnknownError' 'CN=AO Kaspersky Lab, O=AO Kaspersky Lab'); Ok = $false },
    @{ N = 'signature read error rejected';             V = 'ESET';         S = 'throw'; Ok = $false },
    @{ N = 'unknown vendor rejected';                   V = 'Contoso';      S = (New-FakeSig 'Valid' 'CN=Contoso, O=Contoso'); Ok = $false }
)
foreach ($c in $cases) {
    $script:fakeSig = $c.S
    $r = Test-VendorSignature -Path 'C:\fixture\scanner.exe' -Vendor $c.V
    Check $c.N ([bool]$r.Valid -eq $c.Ok)
    if (-not $c.Ok) { Check ($c.N + ' (reason recorded)') (-not [string]::IsNullOrWhiteSpace([string]$r.Error)) }
}
Remove-Item Function:\Get-AuthenticodeSignature

# Real signature API, real signed Windows file: signed, but not by ESET.
$realSigned = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $realSigned) {
    $r = Test-VendorSignature -Path $realSigned -Vendor 'ESET'
    Check 'real Microsoft-signed file is not accepted as ESET' (-not [bool]$r.Valid)
}

# --- 4. locked download folder ---------------------------------------------
$tmpRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$parent = Join-Path $tmpRoot ('scc-sig-trust-' + [guid]::NewGuid().ToString('N'))
try {
    Check 'run-root parent follows -ResultPath' ((Get-RunDownloadParent -ResultPath 'C:\RIT-SCC\PC-1\logs\scanner-Malwarebytes-result.json') -eq 'C:\RIT-SCC\PC-1\logs')
    Check 'run-root parent without -ResultPath is RIT-SCC, not TEMP' ((Get-RunDownloadParent -ResultPath '') -like '*\RIT-SCC')
    $dir = New-LockedDownloadDir -Parent $parent
    Check 'locked folder is a fresh child of the run root' ((Split-Path -Parent $dir) -eq $parent -and (Split-Path -Leaf $dir) -match '^scanner-download-[0-9a-f]{32}$')
    $acl = Get-Acl -LiteralPath $dir
    $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
    Check 'locked folder does not inherit the parent ACL' ([bool]$acl.AreAccessRulesProtected)
    Check 'only Administrators and SYSTEM have access' (($sids -join ',') -eq 'S-1-5-18,S-1-5-32-544')
    Check 'no inherited access entries remain' (@($acl.Access | Where-Object { $_.IsInherited }).Count -eq 0)
    $dir2 = New-LockedDownloadDir -Parent $parent
    Check 'each call creates a new folder' ($dir2 -ne $dir)
    # Hand the folders back so the test can clean up even when not elevated.
    foreach ($d in $dir, $dir2) {
        $null = & icacls.exe $d /reset /T /Q 2>&1
    }
} finally {
    Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -eq 0) { Write-Host 'ALL SCANNER SIGNATURE TRUST TESTS PASSED' } else { Write-Host "$($script:failures) SCANNER SIGNATURE TRUST TEST(S) FAILED"; exit 1 }
