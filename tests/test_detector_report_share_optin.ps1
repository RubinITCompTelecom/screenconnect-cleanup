# test_detector_report_share_optin.ps1 - review #8 regression test.
# A standalone detect run must upload nothing unless -ShareReport is given,
# and -NoReportShare must always win. Runs the REAL detector (read-only
# inventory) from a disposable copy whose Submit-ConnectWiseReport.ps1 is a
# stub that only drops a marker file, so no network request is possible.
# PowerShell 5.1 compatible. Pure ASCII, no BOM. No admin needed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$detectSource = Join-Path $repoRoot 'detect-remote-access.ps1'

$failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Details)
    if ($Ok) { Write-Host ("PASS  " + $Name) }
    else { Write-Host ("FAIL  " + $Name + $(if ($Details) { ' - ' + $Details } else { '' })); $script:failures++ }
}

# ---- Decision function, loaded from the real script ------------------------
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($detectSource, [ref]$tokens, [ref]$errors)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ReportShareRequested' }, $true)
Check 'detector defines Test-ReportShareRequested' ($null -ne $fn)
if ($fn) {
    . ([scriptblock]::Create($fn.Extent.Text))
    Check 'default does not share' (-not (Test-ReportShareRequested))
    Check '-ShareReport shares' (Test-ReportShareRequested -ShareReport)
    Check '-NoReportShare alone does not share' (-not (Test-ReportShareRequested -NoReportShare))
    Check '-NoReportShare wins over -ShareReport' (-not (Test-ReportShareRequested -ShareReport -NoReportShare))
}
$paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Check 'detector declares -ShareReport' ($paramNames -contains 'ShareReport')
Check 'detector still accepts -NoReportShare' ($paramNames -contains 'NoReportShare')

# ---- Real detector runs with a stub uploader --------------------------------
$probe = Join-Path ([IO.Path]::GetTempPath()) ('scc-detect-share-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $probe -Force
try {
    $toolDir = Join-Path $probe 'tool'
    $profileDir = Join-Path $probe 'userprofile'
    $null = New-Item -ItemType Directory -Path $toolDir, (Join-Path $profileDir 'Desktop') -Force
    Copy-Item -LiteralPath $detectSource -Destination $toolDir
    Copy-Item -LiteralPath (Join-Path $repoRoot 'targets.json') -Destination $toolDir
    $marker = Join-Path $probe 'uploader-called.txt'
    $stub = "param([string]`$FindingsJson,[string]`$WorkDir,[string]`$MicroBinUrl,[string]`$MicroBinUploaderPasswordFile)`r`n[IO.File]::WriteAllText('" + $marker.Replace("'", "''") + "', [string]`$FindingsJson)`r`nexit 0`r`n"
    [IO.File]::WriteAllText((Join-Path $toolDir 'Submit-ConnectWiseReport.ps1'), $stub)
    $psHost = (Get-Process -Id $PID).Path

    function Invoke-Detect {
        param([string[]]$Extra)
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
        $outRoot = Join-Path $probe ('out-' + [guid]::NewGuid().ToString('N'))
        $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $toolDir 'detect-remote-access.ps1'),
                       '-Target', 'teamviewer', '-NoPause', '-NoZip', '-OutRoot', $outRoot) + @($Extra)
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = $profileDir
            $output = & $psHost @arguments 2>&1
            $rc = $LASTEXITCODE
        } finally { $env:USERPROFILE = $saved }
        [pscustomobject]@{ ExitCode = $rc; Text = ($output -join "`n"); Uploaded = (Test-Path -LiteralPath $marker) }
    }

    $default = Invoke-Detect @()
    Check 'default run exits 0' ($default.ExitCode -eq 0) $default.Text
    Check 'default run makes no upload request' (-not $default.Uploaded) $default.Text
    Check 'default run says nothing was uploaded' ($default.Text -match 'Report not shared') $default.Text

    $optIn = Invoke-Detect @('-ShareReport')
    Check '-ShareReport run calls the uploader' ($optIn.Uploaded) $optIn.Text

    $both = Invoke-Detect @('-ShareReport', '-NoReportShare')
    Check '-NoReportShare suppresses an explicit -ShareReport' (-not $both.Uploaded) $both.Text

    $caller = Invoke-Detect @('-NoReportShare')
    Check 'pipeline callers (-NoReportShare) make no upload request' (-not $caller.Uploaded) $caller.Text
} finally {
    Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host ("FAILED: " + $failures + " check(s)"); exit 1 }
Write-Host 'PASS: standalone detector report sharing is opt-in'
