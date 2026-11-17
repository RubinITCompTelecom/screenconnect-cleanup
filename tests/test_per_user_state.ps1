# Per-user state must be read for EVERY user profile, not the elevating admin (review #19). Uses fake ProfileList /
# HKEY_USERS trees under HKCU:\Software so no admin rights and no real user data are needed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { Write-Host "PASS: $Name" } else { Write-Host "FAIL: $Name"; $script:failures++ }
}
function Get-FunctionText {
    # Returns the source of the named functions; the caller dot-sources it at script scope.
    param([string]$File, [string[]]$Names)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    $parts = foreach ($name in $Names) {
        $f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $f) { throw "function not found: $name" }
        $f.Extent.Text
    }
    return ($parts -join "`n")
}

$fix = 'HKCU:\Software\SccTest_PerUser_' + [guid]::NewGuid().ToString('N')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('scc_peruser_' + [guid]::NewGuid().ToString('N'))
$sidA = 'S-1-5-21-111-222-333-1001'   # loaded profile (the victim)
$sidB = 'S-1-5-21-111-222-333-1002'   # profile whose hive is not loaded
try {
    $profileList = "$fix\ProfileList"; $hives = "$fix\Hives"
    $dirA = Join-Path $tmp 'Users\victim'; $dirB = Join-Path $tmp 'Users\other'
    foreach ($pair in @(@($sidA, $dirA), @($sidB, $dirB))) {
        New-Item -Path "$profileList\$($pair[0])" -Force | Out-Null
        New-ItemProperty -Path "$profileList\$($pair[0])" -Name ProfileImagePath -Value $pair[1] -PropertyType ExpandString | Out-Null
    }
    New-Item -Path "$profileList\S-1-5-18" -Force | Out-Null   # system profile: must be ignored
    New-ItemProperty -Path "$profileList\S-1-5-18" -Name ProfileImagePath -Value (Join-Path $tmp 'sys') -PropertyType ExpandString | Out-Null
    $runKey = "$hives\$sidA\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runKey -Force | Out-Null
    New-ItemProperty -Path $runKey -Name 'VictimRun' -Value 'C:\Users\victim\evil.exe' | Out-Null
    $wl = "$hives\$sidA\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    New-Item -Path $wl -Force | Out-Null
    New-ItemProperty -Path $wl -Name 'Shell' -Value 'explorer.exe,evil.exe' | Out-Null
    $un = "$hives\$sidA\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VictimApp"
    New-Item -Path $un -Force | Out-Null
    New-ItemProperty -Path $un -Name 'DisplayName' -Value 'ScreenConnect Client (abcdef0123456789)' | Out-Null
    $ua = "$hives\$sidA\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\{CEBFF5CD-ACE2-4F4F-9178-9926F41749EA}\Count"
    New-Item -Path $ua -Force | Out-Null
    New-ItemProperty -Path $ua -Name 'P:\Hfref\ivpgvz\rivy.rkr' -Value ([byte[]](0..71)) -PropertyType Binary | Out-Null
    $startA = Join-Path $dirA 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
    $startB = Join-Path $dirB 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
    New-Item -ItemType Directory -Path $startA, $startB -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $startA 'evil.lnk') -Value 'x'
    Set-Content -LiteralPath (Join-Path $startB 'other.lnk') -Value 'y'
    $acDir = Join-Path $dirA 'AppData\Roaming\AnyDesk'
    New-Item -ItemType Directory -Path $acDir -Force | Out-Null

    # ---- collect-snapshot.ps1 ----
    $snap = Join-Path $repoRoot 'collect-snapshot.ps1'
    $script:CollectionErrors = New-Object System.Collections.Generic.List[object]
    $script:CollectionWarnings = New-Object System.Collections.Generic.List[object]
    $script:CollectionIncomplete = $false
    . ([scriptblock]::Create((Get-FunctionText $snap @('Add-CollectionError', 'Add-CollectionWarning', 'ConvertTo-NullSafeString', 'Get-RegValueSafe',
        'Test-InIncidentWindow', 'Convert-Rot13', 'Convert-UserAssistFileTime', 'Get-UserProfileRoots', 'Get-CachedUserProfiles',
        'Get-RegistryAutorunsSection', 'Get-StartupFoldersSection', 'Get-InstalledProgramsSection', 'Add-UserAssistRows',
        'Get-UserAssistSection'))))

    $profiles = @(Get-UserProfileRoots -ProfileListPath $profileList -HiveRootPrefix $hives)
    Check 'ProfileList: only real user SIDs are returned (system SID skipped)' ($profiles.Count -eq 2)
    $pa = $profiles | Where-Object { $_.Sid -eq $sidA }
    $pb = $profiles | Where-Object { $_.Sid -eq $sidB }
    Check 'ProfileList: loaded flag follows the hive' ($pa.Loaded -and -not $pb.Loaded)
    Check 'ProfileList: name and AppData come from the profile folder' ($pa.Name -eq 'victim' -and $pa.AppData -eq (Join-Path $dirA 'AppData\Roaming'))

    $auto = @(Get-RegistryAutorunsSection -Profiles $profiles)
    $victimRun = @($auto | Where-Object { $_.ValueName -eq 'VictimRun' })
    Check 'Autoruns: Run value of the victim hive is read' ($victimRun.Count -eq 1 -and $victimRun[0].UserSid -eq $sidA -and $victimRun[0].UserName -eq 'victim' -and $victimRun[0].Hive -eq 'HKCU')
    Check 'Autoruns: Key is unique and carries the hive path' ($victimRun[0].Key -like "*$sidA*VictimRun")
    Check 'Autoruns: Winlogon Shell of the victim hive is read' (@($auto | Where-Object { $_.Kind -eq 'Winlogon' -and $_.UserSid -eq $sidA -and $_.ValueName -eq 'Shell' }).Count -eq 1)
    Check 'Autoruns: shape keeps the old fields' (@(@('Key', 'Hive', 'View', 'KeyPath', 'ValueName', 'Value', 'Kind') | Where-Object { -not $victimRun[0].PSObject.Properties[$_] }).Count -eq 0)
    Check 'Autoruns: machine-wide rows have null UserSid' (@($auto | Where-Object { $_.Hive -eq 'HKLM' -and $null -ne $_.UserSid }).Count -eq 0)

    $start = @(Get-StartupFoldersSection -Profiles $profiles)
    Check 'Startup: victim profile folder is read' (@($start | Where-Object { $_.FileName -eq 'evil.lnk' -and $_.UserSid -eq $sidA -and $_.UserName -eq 'victim' -and $_.Scope -eq 'User' }).Count -eq 1)
    Check 'Startup: a profile with an unloaded hive is still read (files)' (@($start | Where-Object { $_.FileName -eq 'other.lnk' -and $_.UserSid -eq $sidB }).Count -eq 1)
    Check 'Startup: shape keeps the old fields' (@(@('Key', 'Scope', 'FileName', 'FullPath', 'LastWriteUtc', 'LengthBytes') | Where-Object { -not $start[0].PSObject.Properties[$_] }).Count -eq 0)

    $prog = @(Get-InstalledProgramsSection -Profiles $profiles)
    $vp = @($prog | Where-Object { $_.SubKeyName -eq 'VictimApp' })
    Check 'InstalledPrograms: per-user Uninstall key of the victim is read' ($vp.Count -eq 1 -and $vp[0].Root -eq 'HKCU' -and $vp[0].UserSid -eq $sidA -and $vp[0].Key -eq "HKCU|$sidA|VictimApp")

    $ass = @(Get-UserAssistSection -WindowDays 0 -Profiles $profiles)
    Check 'UserAssist: victim hive is read, decoded and attributed' ($ass.Count -eq 1 -and $ass[0].UserSid -eq $sidA -and $ass[0].ProgramName -like 'C:\Users\victim*' -and $ass[0].Key -like "$sidA|*")

    # ---- detect-remote-access.ps1 ----
    $det = Join-Path $repoRoot 'detect-remote-access.ps1'
    function Write-Log { param([string]$Message, [string]$Color) }
    . ([scriptblock]::Create((Get-FunctionText $det @('Expand-Env', 'Get-UserProfileRoots', 'Get-PatternExpansions', 'Get-DirsMatchingExpanded', 'Get-DirsMatching', 'Get-AllUninstallEntries'))))
    $script:UserProfileCache = $null
    $dp = @(Get-UserProfileRoots -ProfileListPath $profileList -HiveRootPrefix $hives)
    Check 'Detector: profiles enumerated like the snapshot' ($dp.Count -eq 2 -and @($dp | Where-Object { $_.Loaded }).Count -eq 1)
    $ex = @(Get-PatternExpansions '%APPDATA%\AnyDesk*' $dp)
    Check 'Detector: %APPDATA% pattern expands for every profile' ($ex -contains (Join-Path $dirA 'AppData\Roaming\AnyDesk*') -and $ex -contains (Join-Path $dirB 'AppData\Roaming\AnyDesk*'))
    Check 'Detector: machine-wide patterns are not multiplied' (@(Get-PatternExpansions '%ProgramFiles%\AnyDesk*' $dp).Count -eq 1)
    $script:UserProfileCache = $dp
    $dirs = @(Get-DirsMatching '%APPDATA%\AnyDesk*')
    Check 'Detector: install directory under another user''s AppData is found' (@($dirs | Where-Object { $_.FullName -eq $acDir }).Count -eq 1)
    $un2 = @(Get-AllUninstallEntries -Profiles $dp)
    $vu = @($un2 | Where-Object { $_.KeyName -eq 'VictimApp' })
    Check 'Detector: per-user uninstall entry of the victim is read with its SID' ($vu.Count -eq 1 -and $vu[0].UserSid -eq $sidA -and $vu[0].UserName -eq 'victim' -and $vu[0].RegistryKey)
    Check 'Detector: machine-wide uninstall rows keep UserSid null' (@($un2 | Where-Object { $_.RegistryKey -like 'HKEY_LOCAL_MACHINE*' -and $null -ne $_.UserSid }).Count -eq 0)
    # A loaded victim can have folder redirection independent of the admin's environment.
    $shell = "$hives\$sidA\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
    New-Item -Path $shell -Force | Out-Null
    New-ItemProperty -LiteralPath $shell -Name AppData -Value '%USERPROFILE%\RedirectedRoaming' -PropertyType ExpandString | Out-Null
    New-ItemProperty -LiteralPath $shell -Name 'Local AppData' -Value (Join-Path $tmp 'redirected-local') -PropertyType String | Out-Null
    $redirected = @(Get-UserProfileRoots -ProfileListPath $profileList -HiveRootPrefix $hives) | Where-Object Sid -eq $sidA
    Check 'Detector: redirected roaming path expands the victim profile' ($redirected.AppData -eq (Join-Path $dirA 'RedirectedRoaming'))
    . ([scriptblock]::Create((Get-FunctionText $snap @('Get-UserProfileRoots'))))
    $redirected = @(Get-UserProfileRoots -ProfileListPath $profileList -HiveRootPrefix $hives) | Where-Object Sid -eq $sidA
    Check 'Snapshot: redirected local AppData is preserved' ($redirected.LocalAppData -eq (Join-Path $tmp 'redirected-local'))
} finally {
    Remove-Item -LiteralPath $fix -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures -gt 0) { Write-Host "$failures check(s) failed"; exit 1 }
Write-Host 'All per-user state checks passed.'
