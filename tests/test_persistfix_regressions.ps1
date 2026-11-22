# Regression coverage for reviewed persistence and power repair bugs.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok) { if ($ok) { Write-Host "PASS $name" } else { [void]$failures.Add($name); Write-Host "FAIL $name" } }

# Use the existing adapter seam. A real reset operation is never called.
Import-Module (Join-Path $root 'PowerOptionsRepair.Core.psm1') -Force
$script:gotResetPaths = @()
$adapter = @{
 TestRegistryKey={ $true }; BackupRegistryKey={ $true }; GetRegistryValue={ $null }
 RemoveRegistryValue={ $true }; RemoveRegistryTree={ $true }; SetRegistryDword={ $true }
 BackupPowerSchemes={ $true }; RestoreDefaultPowerSchemes={ $true }; EnableHibernate={ $true }
 SetDefaultButtonActions={ $true }; BackupShutdownRights={ $true }; GrantShutdownRight={ $true }
 BackupLocalGpo={ param($backup,$paths) (@($paths).Count -eq 2) }
 ResetLocalGpo={ param($paths) $script:gotResetPaths=@($paths); (@($paths).Count -eq 2) }
 RunGpUpdate={ $true }; RestartExplorer={ $true }
}
$plan=Get-PowerOptionsRepairPlan -LoadedUserSids @() -ResetLocalGpo
$result=Invoke-PowerOptionsRepairPlan -Plan $plan -Adapter $adapter -BackupRoot 'fixture'
$resetAction=@($result.Actions | Where-Object { $_.Action -eq 'ResetLocalGpo' -and $_.Status -eq 'Completed' }).Count -eq 1
Check 'ResetLocalGpo receives both paths as one argument' ($script:gotResetPaths.Count -eq 2 -and $resetAction)
Remove-Module PowerOptionsRepair.Core

# Full-shape SID matching preserves the _Classes exclusion.
Import-Module (Join-Path $root 'Persistence.Inventory.psm1') -Force
$invModule=Get-Module Persistence.Inventory
& $invModule {
 function script:Test-Path { param($LiteralPath) return ([string]$LiteralPath -like '*ProfileList*') }
 function script:Get-ChildItem { param($LiteralPath,$ErrorAction) @(
  [pscustomobject]@{PSChildName='S-1-12-1-10-20-30-40';PSPath='fixture'}
  [pscustomobject]@{PSChildName='S-1-12-1-10-20-30-40_Classes';PSPath='fixture'}
  [pscustomobject]@{PSChildName='S-1-12-1-bad';PSPath='fixture'}) }
 function script:Get-ItemProperty { param($LiteralPath,$Name,$ErrorAction) [pscustomobject]@{ProfileImagePath='C:\Users\EntraFixture'} }
}
$profiles=& $invModule { Get-SccProfileRoots }
Check 'Entra profile included and Classes/malformed SIDs excluded' ($profiles.Profiles.Count -eq 1 -and $profiles.Profiles[0].Sid -eq 'S-1-12-1-10-20-30-40')
$remModule=Import-Module (Join-Path $root 'Persistence.Removal.psm1') -Force -PassThru
$entraPath='Registry::HKEY_USERS\S-1-12-1-10-20-30-40\Software\Microsoft\Windows\CurrentVersion\Run'
$allowed=& $remModule { param($p) Test-SccRegistryPath $p } $entraPath
Check 'Entra Run key passes removal allowlist validation' ([string]$allowed -eq $entraPath)
Check 'review-only kinds remain excluded from removable candidates' ((Get-Content (Join-Path $root 'Persistence.Removal.psm1') -Raw) -match "\@\('ScheduledTask','RunKey','StartupFile'\)")

# Collection timeout is distinct from the script-file sweep cap.
$inventorySource=Get-Content (Join-Path $root 'Persistence.Inventory.psm1') -Raw
Check 'overall budget is separate from the 30-second sweep cap' ($inventorySource -match '\$script:InventoryMaxSeconds\s*=\s*30' -and $inventorySource -match '\$script:InventoryMaxCollectionSeconds\s*=\s*270' -and $inventorySource -match 'TotalSeconds -ge \$script:InventoryMaxCollectionSeconds')

$reviewSource=Get-Content (Join-Path $root 'Show-PersistenceReview.ps1') -Raw
Check 'startup folder review reads producer property User' ($reviewSource -match 'Get-Value \$item ''User''' -and $reviewSource -notmatch 'Get-Value \$item ''UserName''')

# The manifest function's output and caller comparison use flat arrays.
$winModule=Import-Module (Join-Path $root 'PowerOptionsRepair.Windows.psm1') -Force -PassThru
$temp=Join-Path ([IO.Path]::GetTempPath()) ('persistfix-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temp
try {
 $empty=Join-Path $temp 'empty';$one=Join-Path $temp 'one'
 $null=New-Item -ItemType Directory -Path $empty,$one
 [IO.File]::WriteAllText((Join-Path $one 'fixture.txt'),'x')
 foreach($dir in @($empty,$one)) {
  $manifest=@(& $winModule { param($p) Get-PowerRepairTreeManifest -Path $p } $dir)
  Check ('manifest stays flat for '+$manifest.Count+' records') (@($manifest | Where-Object { $_ -is [array] }).Count -eq 0)
 }
 $treeSource=Get-Content (Join-Path $root 'PowerOptionsRepair.Windows.psm1') -Raw
 Check 'source and backup manifests still use the same JSON comparison' ($treeSource -match 'return \$sorted' -and $treeSource -match '\$sourceJson -cne \$backupJson')
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }

if($failures.Count){throw ($failures.Count.ToString()+' persistfix regression(s) failed: '+($failures -join '; '))}
Write-Host 'All persistence fix regressions passed.'
