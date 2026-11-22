[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$failures = 0
function Check { param([string]$Name, [bool]$Ok) if ($Ok) { Write-Host "PASS: $Name" } else { Write-Host "FAIL: $Name"; $script:failures++ } }
function Get-Function { param([string]$File,[string]$Name) $t=$null;$e=$null;$a=[System.Management.Automation.Language.Parser]::ParseFile($File,[ref]$t,[ref]$e);$f=$a.Find({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true);if(-not $f){throw "Missing function $Name"};return [scriptblock]::Create($f.Extent.Text) }

$collect = Join-Path $repo 'collect-snapshot.ps1'
$detect = Join-Path $repo 'detect-remote-access.ps1'
$diff = Join-Path $repo 'diff-snapshots.ps1'

# Bug 1: actual LocalAccounts function with CIM reference-shaped properties.
. (Get-Function $collect 'Get-LocalAccountsSection')
function Add-CollectionWarning { param($Section,$WarningText) }
function Add-CollectionError { param($Section,$ErrorText) }
function ConvertTo-NullSafeString { param($Value) if ($null -eq $Value) { return '' }; return [string]$Value }
function Get-CimInstance {
    param([string]$ClassName,[string]$Filter,[string]$ErrorAction)
    if ($ClassName -eq 'Win32_GroupUser') {
        return @(
            [pscustomobject]@{ GroupComponent=[pscustomobject]@{Name='Administrators';Domain=$env:COMPUTERNAME}; PartComponent=[pscustomobject]@{Name='localuser'} },
            [pscustomobject]@{ GroupComponent=[pscustomobject]@{Name='Administrators';Domain='OTHERDOMAIN'}; PartComponent=[pscustomobject]@{Name='foreignuser'} }
        )
    }
    return @([pscustomobject]@{ SID='S-1-5-21-1'; Name='localuser'; Domain=$env:COMPUTERNAME; FullName=''; Disabled=$false; Lockout=$false; PasswordRequired=$true })
}
$acct = @(Get-LocalAccountsSection)
Check 'CIM GroupUser properties identify local admin membership and reject another domain' ($acct.Count -eq 1 -and $acct[0].IsLocalAdmin -eq $true)

# Bug 2: run actual diff script as a child process for missing and malformed input.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('snapshotfix-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$missing = Join-Path $tmp 'missing.json'
$corrupt = Join-Path $tmp 'corrupt.json'
$after = Join-Path $tmp 'after.json'
[IO.File]::WriteAllText($corrupt, '{broken')
[IO.File]::WriteAllText($after, '{}')
$exe = Join-Path $PSHOME 'powershell.exe'
foreach ($case in @(@($missing,'missing'),@($corrupt,'corrupt'))) {
    $p = Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$diff,'-BeforeFile',$case[0],'-AfterFile',$after) -Wait -PassThru -NoNewWindow -RedirectStandardError (Join-Path $tmp ($case[1]+'.err')) -RedirectStandardOutput (Join-Path $tmp ($case[1]+'.out'))
    Check "diff input error ($($case[1])) exits 2" ($p.ExitCode -eq 2 -and (Get-Content (Join-Path $tmp ($case[1]+'.err')) -Raw).Length -gt 0)
}
Remove-Item -LiteralPath $tmp -Recurse -Force

# Bug 3: roots normalized case-insensitively, trimming separators, and nesting removed.
. (Get-Function $collect 'Remove-NestedRecentFileRoots')
$pruned = @(Remove-NestedRecentFileRoots @('C:\Users\u\AppData\Local\Temp\','c:\users\U\AppData\Local','D:\Data','D:\Data2'))
Check 'RecentFiles removes nested and case/trailing-slash duplicate roots' ($pruned.Count -eq 3 -and ($pruned -contains 'c:\users\U\AppData\Local') -and ($pruned -contains 'D:\Data2'))

# Bug 4: no matching events is non-error; singleton event count remains one at call site.
. (Get-Function $detect 'Get-ServiceInstallEvents')
$script:EventLogError = $null
function Get-WinEvent { $ex = New-Object System.Exception('fixture'); $er = New-Object System.Management.Automation.ErrorRecord($ex,'NoMatchingEventsFound',[System.Management.Automation.ErrorCategory]::ObjectNotFound,$null); throw $er }
$none = @(Get-ServiceInstallEvents)
Check '7045 no matching events returns empty without EventLogError' ($none.Count -eq 0 -and -not $script:EventLogError)
$detectText = Get-Content -LiteralPath $detect -Raw
Check '7045 singleton result is array-wrapped at inventory call site' ($detectText -match '\$events\s*=\s*@\(Get-ServiceInstallEvents\)')

# Bug 5: creation time assignment is guarded by first-wins InstallDir.
$dirBlock = [regex]::Match($detectText,'(?s)if \(-not \$slot\.InstallDir\)\s*\{\s*\$slot\.InstallDir\s*=\s*\$dir\.FullName\s*\$slot\.InstallDirCreatedUtc\s*=.*?\}').Value
Check 'InstallDirCreatedUtc is set with first InstallDir only' ($dirBlock -match 'InstallDirCreatedUtc')

if ($failures) { throw "$failures snapshotfix regression(s) failed" }
Write-Host 'PASS: snapshotfix regressions'

