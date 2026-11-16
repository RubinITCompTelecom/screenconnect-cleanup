$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'diff-snapshots.ps1'),[ref]$null,[ref]$null)
foreach ($name in @('ConvertTo-RegPathNorm','ConvertTo-PathNorm','Get-ItemKey','Get-ItemStrings','Test-TextHasPath','Find-TargetsStillPresent','Test-ScalarEqual')) {
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$a='S-1-5-21-100-200-300-1001'; $b='S-1-5-21-100-200-300-1002'
$suffix='\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\Agent'
$target=[pscustomobject]@{Kind='runkey';Value=('HKEY_USERS\'+$a+$suffix);Action='DeleteRunKey';Result='Success'}
$row=[pscustomobject]@{Key='victim|Agent';Hive='HKCU';UserSid=$a;KeyPath=('Registry::HKEY_USERS\'+$a+'\SOFTWARE\Microsoft\Windows\CurrentVersion\Run');ValueName='Agent'}
if (@(Find-TargetsStillPresent @($target) @{RegistryAutoruns=@($row)}).Count -ne 1) {throw 'Recreated user autorun was missed'}
$row.UserSid=$b; $row.KeyPath=$row.KeyPath.Replace($a,$b)
if (@(Find-TargetsStillPresent @($target) @{RegistryAutoruns=@($row)}).Count -ne 0) {throw 'Different user was conflated with removal target'}
$row.Hive='HKLM';$row.KeyPath='SOFTWARE\Microsoft\Windows\CurrentVersion\Run';$row.UserSid=$null
$target.Value='HKLM:'+ $suffix
if (@(Find-TargetsStillPresent @($target) @{RegistryAutoruns=@($row)}).Count -ne 1) {throw 'Legacy machine autorun shape no longer matches'}
if (Test-ScalarEqual ([long]9007199254740992) ([long]9007199254740993)) {throw 'Adjacent Int64 values lost precision'}
if (Test-ScalarEqual ([decimal]'1.000000000000000000000000001') ([decimal]'1.000000000000000000000000002')) {throw 'Decimal precision was lost'}
if (-not (Test-ScalarEqual ([long]42) ([decimal]42))) {throw 'Equal exact numbers should compare equal'}
if (Test-ScalarEqual ([long]9007199254740993) ([double]9007199254740992)) {throw 'Mixed float/integer comparison lost precision'}
Write-Host 'PASS: per-user registry identities stay distinct; machine aliases work; numeric changes retain precision.'
