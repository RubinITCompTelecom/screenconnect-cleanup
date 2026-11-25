# test_revoked_signature_verification.ps1 - remove-screenconnect.ps1 product
# verification, Gate D (the Authenticode check).
#
# Field case (2026-11-25): an intruder's ScreenConnect was signed by
# "Connectwise, LLC" with a certificate Windows no longer confirms (status
# UnknownError), and the gate refused to remove it. Owner decision the same
# day: the signature must never block removal - unsigned, altered, re-signed
# and look-alike copies are removed too, on the directory, binary-name and
# service-name match plus the technician's typed approval. The signature is
# only recorded: every case other than Valid + ConnectWise leaves a warning
# note for the log and the removal manifest.
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
. (Import-RemoverFunction 'Get-ScreenConnectSignatureVerdict')

$script:failures = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { Write-Host ("PASS  " + $Name) }
    else { Write-Host ("FAIL  " + $Name); $script:failures++ }
}

# --- 1. the verdict, with the signature read stubbed -------------------------
$script:fakeSig = $null
function Get-AuthenticodeSignature {
    param([string]$LiteralPath, $ErrorAction)
    if ($script:fakeSig -eq 'throw') { throw 'synthetic signature read failure' }
    return $script:fakeSig
}
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

# the field case
$script:fakeSig = New-FakeSig 'UnknownError' $cw 'The certificate was explicitly revoked by its issuer.'
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\ScreenConnect.ClientService.exe'
Check 'UnknownError + ConnectWise signer is ACCEPTED (the field case)' ([bool]$v.Accepted)
Check 'its note names the status, the Windows message and the signer' ($v.Note -like 'SIGNATURE WARNING*' -and $v.Note -like '*UnknownError*' -and $v.Note -like '*explicitly revoked*' -and $v.Note -like '*Connectwise*')

$cases = @(
    @{ Name = 'another valid signer'; Sig = (New-FakeSig 'Valid' 'CN=Evil Corp, O=Evil Corp'); Like = '*not by ConnectWise*Evil Corp*' },
    @{ Name = 'an unsigned file'; Sig = (New-FakeSig 'NotSigned' ''); Like = '*not signed*Signer: none*' },
    @{ Name = 'a file changed after signing'; Sig = (New-FakeSig 'HashMismatch' $cw); Like = '*changed after it was signed*' },
    @{ Name = 'an untrusted look-alike certificate'; Sig = (New-FakeSig 'NotTrusted' $cw); Like = '*does not confirm the signature*NotTrusted*' },
    @{ Name = 'UnknownError with another signer'; Sig = (New-FakeSig 'UnknownError' 'CN=Evil Corp'); Like = '*UnknownError*Evil Corp*' }
)
foreach ($c in $cases) {
    $script:fakeSig = $c.Sig
    $v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\a.exe'
    Check ($c.Name + ' is accepted, with a warning note that says why it is unusual') ([bool]$v.Accepted -and -not $v.Reason -and $v.Note -like 'SIGNATURE WARNING*' -and $v.Note -like $c.Like)
}

$script:fakeSig = 'throw'
$v = Get-ScreenConnectSignatureVerdict -Path 'C:\x\a.exe'
Check 'a signature read failure is accepted, with a warning note' ([bool]$v.Accepted -and $v.Note -like '*could not be read*synthetic signature read failure*')

# --- 2. wiring ---------------------------------------------------------------
Check 'Gate D uses the verdict helper' ($source -match 'Get-ScreenConnectSignatureVerdict -Path \$signedExe')
Check 'Gate D still requires an existing ScreenConnect executable' ($source -match "execute mode requires an existing ScreenConnect executable")
Check 'the directory, binary-name and service-name gates are still there' ($source -match 'no candidate path under a ScreenConnect directory' -and $source -match 'no binary matching known ScreenConnect executable patterns' -and $source -match 'does not match ScreenConnect service patterns')
Check 'the note reaches the log and the removal manifest' ($source -match 'Write-Log "  NOTE: \$verifyNote"' -and $source -match "\+ \`$\(if \(\`$verifyNote\)")

if ($script:failures -gt 0) { Write-Host ("FAILED: " + $script:failures); exit 1 }
Write-Host 'All signature-recording checks passed.'
exit 0
