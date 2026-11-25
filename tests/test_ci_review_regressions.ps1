$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$workflow=[IO.File]::ReadAllText((Join-Path $repo '.github\workflows\windows-ci.yml'))
$required=@('tests/Test-RunRootBaseLock.ps1','tests/test_av_uninstaller_product_count.ps1','tests/test_av_uninstaller_trust.ps1','tests/test_bits_stall.ps1','tests/test_clean_persistence.ps1','tests/test_detector_report_share_optin.ps1','tests/test_msi_uninstall_parsing.ps1','tests/test_per_user_state.ps1','tests/test_quarantine_hash_evidence.ps1','tests/test_review_wrapper_outcome.ps1','tests/test_scanner_signature_trust.ps1','tests/test_revoked_signature_verification.ps1','tests/test_snapshot_admin_sid_pid_map.ps1','tests/test_diff_registry_identity.ps1','tests/test_user_uninstall_handoff.ps1','tests/test_current_profile_redirection.ps1','tests/test_scanner_summary_contract.ps1','tests/gui/Test-GuiUnknownPrompt.ps1','tests/gui/Test-GuiScannerSummary.ps1')
foreach($path in $required){if([regex]::Matches($workflow,[regex]::Escape($path)).Count -lt 2){throw ('Review regression missing from both CI runtime lists: '+$path)}}
Write-Host 'PASS: all review regressions are listed for Windows PowerShell and pwsh CI.'
