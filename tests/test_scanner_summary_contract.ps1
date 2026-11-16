$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$root=Join-Path $env:TEMP ('scc-summary-'+[guid]::NewGuid().ToString('N'))
try {
    $null=New-Item -ItemType Directory -Path (Join-Path $root 'logs') -Force
    @{Tool='KVRT.exe';Status='Completed';ProcessExitCode=0}|ConvertTo-Json|Set-Content (Join-Path $root 'logs\scanner-KVRT-result.json')
    & (Join-Path $repo 'Write-ScannerSummary.ps1') -WorkDir $root -KvrtState 'Exit:0' -EsetState Skipped -MalwarebytesState 'Exit:3'
    $rows=Get-Content (Join-Path $root 'scanner_results.json') -Raw|ConvertFrom-Json
    if($rows.Count -ne 3){throw 'Summary did not retain all three scanner outcomes'}
    if($rows[0].Scanner -ne 'KVRT' -or $rows[0].ExitCode -ne 0 -or $rows[0].Status -ne 'Completed'){throw 'Raw scanner evidence was not normalized'}
    if($rows[1].Status -ne 'Skipped' -or $rows[2].Status -ne 'NotAvailable'){throw 'Skipped and failed launches were conflated'}
    $findings=Join-Path $root 'findings.json'; $html=Join-Path $root 'report.html'
    @{ComputerName='FIXTURE';ScreenConnect=@{Instances=@();ParseIssues=@()};OtherTargets=@()}|ConvertTo-Json -Depth 6|Set-Content $findings
    & (Join-Path $repo 'New-InvestigationReport.ps1') -FindingsJson $findings -ScannerSummary (Join-Path $root 'scanner_results.json') -OutputPath $html *> $null
    if(-not ([IO.File]::ReadAllText($html).Contains('<td>KVRT</td><td>KVRT.exe</td><td>Completed</td><td>0</td>'))){throw 'Report dropped the completed scanner identity or exit code'}
    # A stale success from an earlier attempt cannot override a refused retry.
    & (Join-Path $repo 'Write-ScannerSummary.ps1') -WorkDir $root -KvrtState 'Exit:3'
    $rows=Get-Content (Join-Path $root 'scanner_results.json') -Raw|ConvertFrom-Json
    if($rows[0].Status -ne 'NotAvailable'){throw 'Stale result overrode current launch failure'}
    Write-Host 'PASS: scanner summary preserves completion, skips, failed launches and retry status.'
} finally {if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
