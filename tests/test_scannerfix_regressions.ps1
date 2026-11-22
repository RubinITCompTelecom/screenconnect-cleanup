$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $env:TEMP ('scannerfix-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp
$failures = 0
function Check($name, $ok) { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name"; $script:failures++ } }
$parser = Join-Path $repo 'Get-ScannerFindings.ps1'
$reportScript = Join-Path $repo 'New-InvestigationReport.ps1'
try {
    $missing = & $parser -Scanner ESET -EsetLogPath (Join-Path $tmp 'absent.log')
    Check 'missing ESET log is not a verdict' ($missing.NotParseable -and $missing.Error)
    $kvrt = Join-Path $tmp 'kvrt.klr'
    $kvrtText = "[WARN] Object C:\Program Files\A\x.exe detected: HEUR:Trojan.Win32.A, action: skipped`r`n[WARN] Object C:\Program Files\B\y.exe detected: HEUR:Trojan.Win32.A, action: skipped`r`n"
    [IO.File]::WriteAllText($kvrt, $kvrtText, (New-Object Text.UTF8Encoding($false)))
    $kvrtResult = & $parser -Scanner KVRT -KvrtReportPath $kvrt
    Check 'KVRT paths containing spaces remain distinct' ($kvrtResult.ThreatCount -eq 2 -and $kvrtResult.Threats[0].Object -eq 'C:\Program Files\A\x.exe' -and $kvrtResult.Threats[1].Object -eq 'C:\Program Files\B\y.exe')
    (Get-Item $kvrt).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    $staleKvrt = & $parser -Scanner KVRT -KvrtReportPath $kvrt -SessionStartTimeUtc ([DateTime]::UtcNow.AddDays(-1).ToString('o'))
    Check 'KVRT report older than scanner session is unavailable' ($staleKvrt.NotParseable -and $staleKvrt.Error -match 'No report from this scan session')
    # Session binding must be timezone- and format-safe: a report written during
    # the session is accepted whether the start time is 'yyyy-MM-dd HH:mm:ss'
    # (what Invoke-GUIScanner writes) or round-trip 'o' with Z.
    (Get-Item $kvrt).LastWriteTimeUtc = [DateTime]::UtcNow
    foreach ($fmt in 'yyyy-MM-dd HH:mm:ss', 'o') {
        $fresh = & $parser -Scanner KVRT -KvrtReportPath $kvrt -SessionStartTimeUtc ([DateTime]::UtcNow.AddMinutes(-10).ToString($fmt))
        Check "KVRT report written during the session is accepted ($fmt)" ((-not $fresh.NotParseable) -and $fresh.ThreatCount -eq 2)
        $late = & $parser -Scanner KVRT -KvrtReportPath $kvrt -SessionStartTimeUtc ([DateTime]::UtcNow.AddMinutes(10).ToString($fmt))
        Check "KVRT report written before the session is refused ($fmt)" ($late.NotParseable -and $late.Error -match 'No report from this scan session')
    }
    $badStart = & $parser -Scanner KVRT -KvrtReportPath $kvrt -SessionStartTimeUtc 'not a date'
    Check 'unreadable session start fails closed' ($badStart.NotParseable -and $badStart.ThreatCount -eq 0)
    $esetLog = Join-Path $tmp 'eset-log.txt'
    $esetText = "ESET Online Scanner v1.4.0.0`r`nstarted at 2026-09-09 10:00:00`r`n================ detected =================`r`nname = `"Win32/Adware.SomeAd`"`r`nobject = `"C:\Users\test\file1.exe`"`r`n================ cleaned =================`r`n"
    [IO.File]::WriteAllText($esetLog, $esetText, [Text.Encoding]::Unicode)
    $esetFresh = & $parser -Scanner ESET -EsetLogPath $esetLog -SessionStartTimeUtc ([DateTime]::UtcNow.AddMinutes(-10).ToString('yyyy-MM-dd HH:mm:ss'))
    Check 'ESET log written during the session is parsed (no date= line needed)' ((-not $esetFresh.NotParseable) -and $esetFresh.ThreatCount -eq 1)
    (Get-Item $esetLog).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-2)
    $esetStale = & $parser -Scanner ESET -EsetLogPath $esetLog -SessionStartTimeUtc ([DateTime]::UtcNow.AddMinutes(-10).ToString('yyyy-MM-dd HH:mm:ss'))
    Check 'ESET log untouched since before the session is refused' ($esetStale.NotParseable -and $esetStale.Error -match 'No report from this scan session')
    $kvrtBare = Join-Path $tmp 'kvrt-bare.klr'
    [IO.File]::WriteAllText($kvrtBare, "C:\Program Files\A B\x.exe HEUR:Trojan.Win32.A`r`n", (New-Object Text.UTF8Encoding($false)))
    $bare = & $parser -Scanner KVRT -KvrtReportPath $kvrtBare
    Check 'KVRT path stops before a verdict that follows it' ($bare.ThreatCount -eq 1 -and $bare.Threats[0].Object -eq 'C:\Program Files\A B\x.exe')
    $findings = Join-Path $tmp 'findings.json'
    @{ ComputerName='TEST'; TargetsSelected=@('screenconnect'); TargetsSource='test'; ScreenConnect=@{Instances=@();ParseIssues=@();Historical=@();RawFilesSaved=@()}; OtherTargets=@() } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $findings -Encoding UTF8
    $errorFindings = Join-Path $tmp 'error-findings.json'
    @{ Scanner='ESET'; NotParseable=$false; Error='<unavailable>'; ThreatCount=0; Threats=@() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $errorFindings -Encoding UTF8
    $summary = Join-Path $tmp 'scanner.json'
    ConvertTo-Json -InputObject @(@{Scanner='ESET';Tool='ESET';Status='Completed';ExitCode=0;FindingsPath=$errorFindings}) -Depth 5 | Set-Content -LiteralPath $summary -Encoding UTF8
    $out = Join-Path $tmp 'report.html'
    & $reportScript -FindingsJson $findings -ScannerSummary $summary -OutputPath $out | Out-Null
    $html = Get-Content -LiteralPath $out -Raw
    $scannerHtml = [regex]::Match($html, '(?s)<section id="scanners">.*?</section>').Value
    Check 'report error is not clean or no-threats' ($scannerHtml -notmatch 'Clean|No threats detected' -and $scannerHtml.Contains('Results not available') -and $scannerHtml.Contains('&lt;unavailable&gt;'))
    Check 'report labels AV times local' ((Get-Content -LiteralPath $reportScript -Raw).Contains('Opened (local time)'))
    $guiSource = Get-Content -LiteralPath (Join-Path $repo 'Invoke-GUIScanner.ps1') -Raw
    $diagSource = Get-Content -LiteralPath (Join-Path $repo 'Get-MalwarebytesDownloadDiagnostics.ps1') -Raw
    Check 'fallback enables TLS 1.2 additively' ($guiSource.Contains('::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12'))
    Check 'diagnostics enables TLS 1.2 additively' ($diagSource.Contains('::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12'))
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
if ($failures) { exit 1 }
Write-Host 'ALL SCANNERFIX REGRESSION TESTS PASSED'