# test_revoked_signature_verification.ps1 - remove-screenconnect.ps1 product
# verification, Gate D (the Authenticode check).
#
# Field case (2026-11-25): an intruder's ScreenConnect was signed by
# "Connectwise, LLC" with the certificate that was later revoked. Windows
# reports that as status UnknownError, and the gate refused to remove it.
# The gate must now accept that build, and still refuse:
#   - an unsigned file, a file changed after signing (HashMismatch),
#   - a file signed by someone else,
#   - a look-alike certificate carrying the ConnectWise name that does not
#     chain to a trusted root.
# Nothing is installed, removed or downloaded.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'remove-screenconnect.ps1'
$source = [IO.File]::ReadAllText($scriptPath)

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
function Import-RemoverFunction {
    param([string]$Name)
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if ($null -eq $fn) { throw "$Name not found in remove-screenconnect.ps1" }
    return [scriptblock]::Create($fn.Extent.Text)
}
. (Import-RemoverFunction 'Test-ScreenConnectSignerChain')
. (Import-RemoverFunction 'Get-ScreenConnectSignatureVerdict')

$script:failures = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { Write-Host ("PASS  " + $Name) }
    else { Write-Host ("FAIL  " + $Name); $script:failures++ }
}

# --- 1. the real chain check, against real certificates ---------------------
# A certificate that genuinely chains to a trusted root: any embedded-signed
# Microsoft binary on this PC.
$realSigned = $null
foreach ($candidate in @(
        (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'),
        (Join-Path $env:WINDIR 'explorer.exe'),
        (Join-Path $env:WINDIR 'System32\ntdll.dll'),
        (Join-Path $env:WINDIR 'System32\kernel32.dll'))) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    $s = Get-AuthenticodeSignature -LiteralPath $candidate
    if ($s.Status -eq 'Valid' -and $s.SignerCertificate) { $realSigned = [pscustomobject]@{ Path = $candidate; Cert = $s.SignerCertificate }; break }
}
if ($realSigned) {
    Check 'a real Microsoft code-signing certificate chains to a trusted root' (Test-ScreenConnectSignerChain -Certificate $realSigned.Cert -FilePath $realSigned.Path)
} else {
    Write-Host 'SKIP  no embedded-signed Windows binary found for the positive chain check'
}

# A look-alike: self-signed, carries the ConnectWise name, trusted by nobody.
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
    'CN="Connectwise, LLC", O="Connectwise, LLC", L=Tampa, S=Florida, C=US', $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$eku = New-Object System.Security.Cryptography.OidCollection
[void]$eku.Add((New-Object System.Security.Cryptography.Oid '1.3.6.1.5.5.7.3.3'))
$req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($eku, $false)))
$fakeCert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
Check 'the look-alike subject really says ConnectWise' ($fakeCert.Subject -match 'Connectwise')
Check 'a self-signed look-alike ConnectWise certificate does NOT chain to a trusted root' (-not (Test-ScreenConnectSignerChain -Certificate $fakeCert))

# --- 2. the verdict, with the signature read stubbed -------------------------
$script:fakeSig = $null
function Get-AuthenticodeSignature {
    param([string]$LiteralPath, $ErrorAction)
    if ($script:fakeSig -eq 'throw') { throw 'synthetic signature read failure' }
    return $script:fakeSig
}
$script:chainAnswer = $true
$script:chainCalls = 0
function Test-ScreenConnectSignerChain { param($Certificate, [string]$FilePath) $script:chainCalls++; return $script:chainAnswer }

function New-FakeSig {
    param([string]$Status, [string]$Subject, [string]$Message = '')
    $cert = $null
    if ($Subject) { $cert = [pscustomobject]@{ Subject = $Subject } }
    return [pscustomobject]@{ Status = $Status; StatusMessage = $Message; SignerCertificate = $cert }
}
$cw = 'CN="Connectwise, LLC", O="Connectwise, LLC", L=Tampa, S=Florida, C=US'

$script:fakeSig = New-FakeSig 'Valid' $cw
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\ScreenConnect.ClientService.exe'
Check 'Valid + ConnectWise signer is accepted with no note' ($v.Accepted -and -not $v.Note)

$script:fakeSig = New-FakeSig 'Valid' 'CN=Evil Corp, O=Evil Corp'
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\a.exe'
Check 'Valid + another signer is refused' (-not $v.Accepted -and $v.Reason -like '*not identified as ConnectWise*')

# the field case
$script:chainAnswer = $true; $script:chainCalls = 0
$script:fakeSig = New-FakeSig 'UnknownError' $cw 'The certificate was explicitly revoked by its issuer.'
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\ScreenConnect.ClientService.exe'
Check 'UnknownError + ConnectWise signer + trusted chain is ACCEPTED (revoked-certificate build)' ([bool]$v.Accepted)
Check 'the acceptance is recorded in a note that names the status and the reason' ($v.Note -like '*UnknownError*' -and $v.Note -like '*revoked*' -and $v.Note -like '*Connectwise*')
Check 'the chain was actually checked' ($script:chainCalls -eq 1)

$script:fakeSig = New-FakeSig 'NotTrusted' $cw
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\a.exe'
Check 'NotTrusted + ConnectWise signer + trusted chain is accepted' ([bool]$v.Accepted -and [bool]$v.Note)

$script:chainAnswer = $false
$script:fakeSig = New-FakeSig 'UnknownError' $cw
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\a.exe'
Check 'UnknownError + ConnectWise name + UNTRUSTED chain is refused' (-not $v.Accepted -and $v.Reason -like '*does not chain to a trusted root*')

$script:chainAnswer = $true; $script:chainCalls = 0
$script:fakeSig = New-FakeSig 'UnknownError' 'CN=Evil Corp, O=Evil Corp'
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\a.exe'
Check 'UnknownError + another signer is refused without consulting the chain' (-not $v.Accepted -and $script:chainCalls -eq 0)

foreach ($bad in 'HashMismatch', 'NotSigned', 'NotSupportedFileFormat', 'Incompatible') {
    $script:chainCalls = 0
    $script:fakeSig = New-FakeSig $bad $cw
    $v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\a.exe'
    Check ("$bad is refused even with a ConnectWise signer and a trusted chain") (-not $v.Accepted -and $v.Reason -like "*not Valid: $bad*" -and $script:chainCalls -eq 0)
}

$script:fakeSig = New-FakeSig 'UnknownError' ''
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\a.exe'
Check 'UnknownError with no signer certificate is refused' (-not $v.Accepted)

$script:fakeSig = 'throw'
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\a.exe'
Check 'a signature read failure is refused (fail closed)' (-not $v.Accepted -and $v.Reason -like '*could not verify*')

# --- 3. wiring ---------------------------------------------------------------
Check 'Gate D uses the verdict helper' ($source -match 'Get-ScreenConnectSignatureVerdict -Path \$signedExe')
Check 'the chain check ignores revocation and expiry only' ($source -match 'X509RevocationMode\]::NoCheck' -and $source -match 'X509VerificationFlags\]::IgnoreNotTimeValid' -and $source -notmatch 'AllowUnknownCertificateAuthority|AllFlags')
Check 'the note reaches the log and the removal manifest' ($source -match 'Write-Log "  NOTE: \$verifyNote"' -and $source -match "\+ \`$\(if \(\`$verifyNote\)")

if ($script:failures -gt 0) { Write-Host ("FAILED: " + $script:failures); exit 1 }
Write-Host 'All revoked-signature verification checks passed.'
exit 0
