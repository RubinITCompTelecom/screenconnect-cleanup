[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'remove-screenconnect.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
function Get-FunctionText {
    param([string]$Name)
    $node = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $node) { throw "Missing function: $Name" }
    return $node.Extent.Text
}
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw "FAIL: $Message" } else { Write-Host "PASS: $Message" } }

# Bug 1: execute the parsed function with a mocked HKEY_USERS hive. The `-match`
# in that loop must not replace the ArrayList that accumulates uninstall entries.
. ([scriptblock]::Create((Get-FunctionText 'Get-UninstallEntriesForInstance')))
function Get-ChildItem {
    param([string]$LiteralPath, [string]$ErrorAction)
    if ($LiteralPath -eq 'Registry::HKEY_USERS') { return [pscustomobject]@{ PSChildName = 'S-1-5-21-1-2-3-1001' } }
    return [pscustomobject]@{ PSPath = 'fake-key'; PSChildName = 'one' }
}
function Test-Path { param([string]$LiteralPath) return ($LiteralPath -like '*HKEY_USERS*') }
function Get-ItemProperty { param([string]$LiteralPath, [string]$ErrorAction) return [pscustomobject]@{ DisplayName='ScreenConnect Client'; InstallLocation='C:\ScreenConnect\one' } }
$single = @(Get-UninstallEntriesForInstance -InstanceIdentifier 'one')
Assert-True ($single.Count -eq 1 -and $single[0].DisplayName -eq 'ScreenConnect Client') 'HKEY_USERS match returns a single uninstall entry as a one-item array'
Remove-Item Function:\Get-ChildItem,Function:\Test-Path,Function:\Get-ItemProperty

# Bug 2: prior entries come first, preserve structured paths/hashes/destinations,
# and repeated resume merges do not duplicate prior/current exact entries.
. ([scriptblock]::Create((Get-FunctionText 'Merge-ManifestEntries')))
$prior = [pscustomobject]@{ Action='Quarantine'; Result='Deferred'; SourcePath='C:\old\a'; DestinationPath='C:\q\a'; SourceIdentity='sha256:abc' }
$current = [pscustomobject]@{ Action='ResumeVerify'; Result='Success'; SourcePath='C:\old\a'; DestinationPath='C:\q\a'; SourceIdentity='sha256:abc' }
$merged = @(Merge-ManifestEntries -PriorEntries @($prior) -CurrentEntries @($current))
$again = @(Merge-ManifestEntries -PriorEntries $merged -CurrentEntries @($current))
Assert-True ($merged.Count -eq 2 -and $merged[0].Action -eq 'Quarantine' -and $merged[0].DestinationPath -eq 'C:\q\a' -and $again.Count -eq 2) 'resume manifest merge retains prior evidence first and deduplicates repeat resumes'

# Bug 3: the terminal cleanup is after processing, gated to resume+execute,
# and leaves every still-pending reboot task registered.
$source = [IO.File]::ReadAllText($scriptPath)
$cleanup = [regex]::Match($source, '(?s)if \(\$Resume -and \$Execute\)\s*\{\s*foreach \(\$resumeStatus in @\(\$script:ResumeStatuses\)\).*?\n\}')
Assert-True ($cleanup.Success -and ($cleanup.Value -match '\$resumeStatus\.Status -ne ''RebootPending''') -and $cleanup.Value.Contains('Remove-ResumeTask')) 'terminal resume statuses remove task while RebootPending retains it'

# Bug 4: invoke a harmless child that exceeds a short timeout; function output
# must be one structured object, not include WaitForExit(Boolean).
. ([scriptblock]::Create((Get-FunctionText 'Run-BoundedProcess')))
function Write-Log { param([string]$Message, [string]$Level) }
$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'powershell.exe is unavailable for the bounded child test' }
$result = @(Run-BoundedProcess -FilePath $exe -Arguments '-NoProfile -Command "Start-Sleep -Seconds 3"' -TimeoutMs 1000)
Assert-True ($result.Count -eq 1 -and $result[0].TimedOut -eq $true -and $result[0].ExitCode -eq -1) 'bounded timeout returns only its structured result'

# Bug 5: omitted ExitCode must remain null in both in-memory manifest and JSON.
. ([scriptblock]::Create((Get-FunctionText 'Add-ManifestEntry')))
$script:Manifest = New-Object System.Collections.ArrayList
Add-ManifestEntry -InstanceId 'i' -Action 'Test' -Target 't' -Result 'Failed'
$entry = $script:Manifest[0]
$json = $entry | ConvertTo-Json -Compress
$roundTrip = $json | ConvertFrom-Json
Assert-True ($null -eq $entry.ExitCode -and $null -eq $roundTrip.ExitCode) 'omitted exit code serializes as JSON null'
Assert-True ($source.Contains('$null -ne $p.ExitCode')) 'text report suppresses null exit codes'

# Bug 2 (end to end): run the script's real manifest-building block. A plain
# object[] has no ToArray(), so the block must build Entries without it, for
# zero, one and several merged entries.
$block = [regex]::Match($source, '(?s)\$manifestEntries = @\(Merge-ManifestEntries.*?\n\$manifestObj = \[PSCustomObject\]@\{.*?\n\}')
Assert-True $block.Success 'manifest-building block located'
$ScriptName = 'remove-screenconnect.ps1'; $ScriptVersion = 'test'; $PlanFile = 'p'; $WorkDir = 'w'; $quarantineDir = 'q'
$Execute = [switch]$true; $Resume = [switch]$true
foreach ($priorCount in 0, 1, 2) {
    $script:PriorManifestEntries = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $priorCount; $i++) { [void]$script:PriorManifestEntries.Add([pscustomobject]@{ Action = 'Quarantine'; Target = "t$i" }) }
    $script:Manifest = New-Object System.Collections.ArrayList
    [void]$script:Manifest.Add([pscustomobject]@{ Action = 'ResumeVerify'; Target = 'now' })
    . ([scriptblock]::Create($block.Value))
    $written = ($manifestObj | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    Assert-True (@($written.Entries).Count -eq ($priorCount + 1)) "manifest object holds $priorCount prior entr(ies) plus the current one"
}

Write-Host 'PASS: all reviewed removal bug regressions'
exit 0
