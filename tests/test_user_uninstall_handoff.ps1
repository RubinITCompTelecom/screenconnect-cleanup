$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'remove-screenconnect.ps1'),[ref]$null,[ref]$null)
foreach($name in @('ConvertTo-RegistryProviderPath','Test-AllowedUninstallRegistryPath')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$sid='S-1-5-21-100-200-300-1001'
function Test-Path {param($LiteralPath) $LiteralPath -eq ('Registry::HKEY_USERS\'+$sid)}
$key='HKEY_USERS\'+$sid+'\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ScreenConnect Client (test)'
if(-not (Test-AllowedUninstallRegistryPath $key)){throw 'Detector user-hive registration was rejected'}
if((ConvertTo-RegistryProviderPath $key) -ne ('Registry::'+$key)){throw 'User hive did not become a literal provider path'}
foreach($bad in @($key.Replace($sid,'S-1-5-18'),$key.Replace($sid,$sid+'_Classes'),$key.Replace($sid,'S-1-5-21-100-200-300-9999'),$key.Replace('Uninstall','Run'),($key+'\child'),($key+'\..\..\Run'))){
    if(Test-AllowedUninstallRegistryPath $bad){throw ('Untrusted registration path accepted: '+$bad)}
}
Write-Host 'PASS: detector HKU identity survives handoff; unsupported and unloaded hives and unrelated keys are refused.'
