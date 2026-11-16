# test_review_wrapper_outcome.ps1 - Invoke-ReviewAndRemove.ps1 final message
# (code review 2026-11-12, item 3).
#
# A product-verification failure means an instance the technician approved for
# removal was left installed. The wrapper must never print "Removal completed"
# for such a run, even if an (older) engine exited 0.
#
# The wrapper is copied into a throwaway folder next to a FAKE
# remove-screenconnect.ps1 that only writes a canned removal-manifest.json and
# exits with a chosen code. Nothing is removed and the real engine never runs.
# PowerShell 5.1 compatible. Pure ASCII, no BOM.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$reviewSource = Join-Path $repoRoot 'Invoke-ReviewAndRemove.ps1'
$psHost = $null
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $psHost = Join-Path $PSHOME 'powershell.exe'
} else {
    $psHost = (Get-Command pwsh -ErrorAction Stop).Source
}

$probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('scc-review-outcome-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $probeRoot -Force
$failures = @()
function Check {
    param([string]$Name, [bool]$Condition, [string]$Details)
    if ($Condition) { Write-Host ("PASS  " + $Name) }
    else {
        $message = "FAIL  " + $Name
        if ($Details) { $message += " - " + $Details }
        Write-Host $message
        $script:failures += $message
    }
}

function Invoke-OutcomeProbe {
    param([string]$Name, [string]$EntriesJson, [int]$EngineExit)
    $dir = Join-Path $probeRoot $Name
    $null = New-Item -ItemType Directory -Path $dir -Force
    Copy-Item -LiteralPath $reviewSource -Destination (Join-Path $dir 'Invoke-ReviewAndRemove.ps1')
    $manifestText = '{"Script":"fake","Entries":' + $EntriesJson + '}'
    $fake = @(
        'param([Alias(''PlanJson'')][string]$PlanFile, [string]$WorkDir, [switch]$Execute)',
        '$text = ''' + $manifestText.Replace("'", "''") + '''',
        '[IO.File]::WriteAllText((Join-Path $WorkDir ''removal-manifest.json''), $text)',
        ('exit ' + $EngineExit)
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $dir 'remove-screenconnect.ps1'), $fake)

    $findingsPath = Join-Path $dir 'findings.json'
    $findings = [ordered]@{
        RunId = 'synthetic-outcome-run'
        ComputerName = 'synthetic-host'
        ScreenConnect = [ordered]@{
            Instances = @(
                [ordered]@{
                    Identifier = 'synthetic-instance'
                    InstallDir = 'C:\Program Files\ScreenConnect'
                    ServiceName = 'ScreenConnect'
                    RelayHost = 'relay.example.test'
                }
            )
        }
    }
    $findings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $findingsPath -Encoding ASCII
    $workDir = Join-Path $dir 'work'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $dir 'Invoke-ReviewAndRemove.ps1'),
        '-FindingsJson', $findingsPath,
        '-WorkDir', $workDir,
        '-MinFreeGB', '0'
    )
    $output = @('Y') | & $psHost @arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($output -join "`n") }
}

$verifFail = '{"InstanceId":"abc123","Action":"ProductVerification","Target":"N/A","Result":"PRODUCT_VERIFICATION_FAILED","Details":"no binary"}'
$verifPass = '{"InstanceId":"abc123","Action":"ProductVerification","Target":"N/A","Result":"Passed","Details":""}'
$quarantined = '{"InstanceId":"abc123","Action":"Quarantine","Target":"C:\\x","Result":"Success","Details":""}'

try {
    $r = Invoke-OutcomeProbe -Name 'unverified-exit1' -EntriesJson ('[' + $verifFail + ']') -EngineExit 1
    Check 'unverified instance: exit 1' ($r.ExitCode -eq 1) $r.Text
    Check 'unverified instance: distinct NOT REMOVED message names the instance' ($r.Text -match 'NOT REMOVED: 1 instance' -and $r.Text -match '- abc123') $r.Text
    Check 'unverified instance: never says Removal completed' ($r.Text -notmatch 'Removal completed') $r.Text

    # Older engine that still exited 0 on a verification failure: the wrapper
    # must not trust the exit code alone.
    $r = Invoke-OutcomeProbe -Name 'unverified-exit0' -EntriesJson $verifFail -EngineExit 0
    Check 'unverified + engine exit 0 (single-object Entries): wrapper exits 1' ($r.ExitCode -eq 1) $r.Text
    Check 'unverified + engine exit 0: NOT REMOVED, not Removal completed' ($r.Text -match 'NOT REMOVED' -and $r.Text -notmatch 'Removal completed') $r.Text

    $r = Invoke-OutcomeProbe -Name 'clean' -EntriesJson ('[' + $verifPass + ',' + $quarantined + ']') -EngineExit 0
    Check 'clean run: exit 0 and Removal completed' ($r.ExitCode -eq 0 -and $r.Text -match 'Removal completed' -and $r.Text -notmatch 'NOT REMOVED') $r.Text

    $r = Invoke-OutcomeProbe -Name 'other-failure' -EntriesJson ('[' + $verifPass + ']') -EngineExit 1
    Check 'other failure: problems message, exit 1' ($r.ExitCode -eq 1 -and $r.Text -match 'Removal reported problems' -and $r.Text -notmatch 'NOT REMOVED') $r.Text
} finally {
    Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ("$($failures.Count) review-wrapper outcome test(s) failed")
    exit 1
}
Write-Host 'ALL REVIEW-WRAPPER OUTCOME TESTS PASSED'
exit 0
