# Normalize attended scanner outcomes for both guided launchers. No scanner is run here.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkDir,
    [string]$KvrtState='NotRun',
    [string]$EsetState='NotRun',
    [string]$MalwarebytesState='NotRun'
)
$ErrorActionPreference='Stop'
if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { throw 'Scanner run folder does not exist.' }
$rows = foreach ($pair in @(@('KVRT',$KvrtState), @('ESET',$EsetState), @('Malwarebytes',$MalwarebytesState))) {
    $name=$pair[0]; $state=$pair[1]
    $record=[ordered]@{Scanner=$name;Tool=$name;Status=$state;ExitCode=$null;ResultPath=$null}
    if ($state -match '^Exit:(-?[0-9]+)$') {
        $rc=[int]$Matches[1]
        $record.ExitCode=$rc
        $record.Status=switch($rc){0{'UnverifiedResult'} 2{'LaunchFailed'} 3{'NotAvailable'} 4{'Timeout'} 5{'ExitedEarly'} 6{'InstallFailed'} default{'Failed'}}
        $path=Join-Path $WorkDir ('logs\scanner-'+$name+'-result.json')
        $record.ResultPath=$path
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $raw=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($null -eq $raw -or $raw -is [array]) { throw 'Expected one scanner result object.' }
                foreach ($p in $raw.PSObject.Properties) {
                    if ($p.Name -notin @('Scanner','Status','ExitCode','ResultPath')) { $record[$p.Name]=$p.Value }
                }
                $status=$raw.PSObject.Properties['Status']
                if ($status) {
                    $record.ChildStatus=[string]$status.Value
                    if ($rc -eq 0 -and $status.Value) { $record.Status=[string]$status.Value }
                }
            } catch {
                $record.ResultReadError=$_.Exception.Message
                if ($rc -eq 0) { $record.Status='InvalidResult' }
            }
        }
    } elseif ($state -notin @('NotRun','Skipped','NotStaged')) { throw ('Invalid scanner state: '+$state) }
    [pscustomobject]$record
}
ConvertTo-Json -InputObject @($rows) -Depth 16 | Set-Content -LiteralPath (Join-Path $WorkDir 'scanner_results.json') -Encoding UTF8
