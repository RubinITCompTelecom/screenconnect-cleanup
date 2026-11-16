$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'collect-snapshot.ps1'),[ref]$null,[ref]$null)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CachedUserProfiles'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Get-UserProfileRoots { [pscustomobject]@{Sid=$sid;Loaded=$true;AppData='C:\default\roaming';LocalAppData='C:\default\local'} }
function Add-CollectionError {param($Section,$ErrorText) throw $ErrorText}
function Add-CollectionWarning {param($Section,$WarningText)}
$script:UserProfileCache=$null
$profile=@(Get-CachedUserProfiles)[0]
if($profile.AppData -ne $env:APPDATA -or $profile.LocalAppData -ne $env:LOCALAPPDATA){throw 'A loaded current profile lost its real environment paths'}
Write-Host 'PASS: current-user redirected AppData is retained even with a loaded ProfileList entry.'
