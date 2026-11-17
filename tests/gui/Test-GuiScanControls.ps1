# Real owned child/worker processes and WPF controls; no engine or vendor AV runs.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repo 'gui\Gui.Core.psm1') -Force
Add-Type -AssemblyName PresentationFramework
$xml=[xml](Get-Content (Join-Path $repo 'gui\MainWindow.xaml') -Raw)
$reader=New-Object Xml.XmlNodeReader $xml
$window=[Windows.Markup.XamlReader]::Load($reader)
$ui=@{}
foreach($name in @('ScanControls','BtnPauseScan','BtnStopScan','ScanControlHint','Busy','StatusDetail')){
    $ui[$name]=$window.FindName($name)
    if(-not $ui[$name]){throw ('Missing scan control: '+$name)}
}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'gui\Start-CleanupGui.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Update-ScanControls','Invoke-ScanPause','Continue-AfterScan','Invoke-ScanStop')){
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
foreach($name in @('BtnPauseScan','BtnStopScan')){
    $binding=@($ast.EndBlock.Statements | Where-Object {$_.Extent.Text -match ('^\$ui\.'+$name+'\.add_Click\(')})
    if($binding.Count -ne 1){throw ('Missing actual click binding for '+$name)}
    . ([scriptblock]::Create($binding[0].Extent.Text))
}
function Click-ScanControl($Name){$ui[$Name].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
$script:Moves=0;$script:Completes=0;$script:Answer=$null
function Move-Next {$script:Moves++}
function Complete-Run {$script:Completes++}
function Add-ConsoleNote {param($Text)}
function Show-Dialog {param($Id,$Title,$Message,$Buttons) $script:Answer}
function Check {param([bool]$Ok,[string]$Text) if(-not $Ok){throw $Text};Write-Host ('PASS: '+$Text)}
function Read-Beat($Path){
    for($i=0;$i -lt 10;$i++){
        try {
            $s=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            $r=New-Object IO.StreamReader $s
            try {$v=$r.ReadToEnd();if($v){return $v}} finally {$r.Dispose()}
        } catch { }
        Start-Sleep -Milliseconds 20
    }
    throw 'Fixture heartbeat unavailable'
}
$work=Join-Path $env:TEMP ('scc-gui-controls-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $work
$parent=$null;$sibling=$null
try {
    $worker=Join-Path $work 'worker.ps1'
    [IO.File]::WriteAllText($worker,'param($OutFile) while($true){[IO.File]::WriteAllText($OutFile,[guid]::NewGuid().ToString());Start-Sleep -Milliseconds 100}',[Text.Encoding]::ASCII)
    $fixture=Join-Path $work 'collect-snapshot.ps1'
    $source=@'
param($Worker,$ChildBeat,$PidFile,$ParentBeat)
$p=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Worker,'-OutFile',$ChildBeat) -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($PidFile,[string]$p.Id)
while($true){[IO.File]::WriteAllText($ParentBeat,[guid]::NewGuid().ToString());Start-Sleep -Milliseconds 100}
'@
    [IO.File]::WriteAllText($fixture,$source,[Text.Encoding]::ASCII)
    $childBeat=Join-Path $work 'child.beat';$parentBeat=Join-Path $work 'parent.beat';$siblingBeat=Join-Path $work 'sibling.beat';$pidFile=Join-Path $work 'child.pid'
    $parent=Start-GuiChild -ScriptPath $fixture -ArgumentList @('-Worker',$worker,'-ChildBeat',$childBeat,'-PidFile',$pidFile,'-ParentBeat',$parentBeat)
    $sibling=Start-GuiChild -ScriptPath $worker -ArgumentList @('-OutFile',$siblingBeat)
    $deadline=(Get-Date).AddSeconds(30)
    while((Get-Date) -lt $deadline -and (-not (Test-Path $childBeat) -or -not (Test-Path $siblingBeat))){Start-Sleep -Milliseconds 100}
    Check ((Test-Path $childBeat) -and (Test-Path $siblingBeat)) 'owned collector worker and unrelated fixture started'
    $workerPid=[int](Get-Content $pidFile -Raw)
    $script:Session=New-GuiSession -Mode Offline -ToolRoot $repo
    $entry=@($script:Session.Plan | Where-Object {$_.StepId -eq '3'})[0]
    $script:Action=[pscustomobject]@{Kind='Run';StepId='3';ScriptPath=$fixture;Destructive=$false;Call=$entry.Call;Entry=$entry;Index=0}
    $scanAction=$script:Action
    $script:Child=$parent;$script:CloseLock=$false;$script:InDialog=$false
    $script:ScanPauseRequested=$false;$script:ScanWaiting=$false
    foreach($leaf in @('collect-snapshot.ps1','detect-remote-access.ps1','Invoke-PersistenceScan.ps1','diff-snapshots.ps1')){
        $script:Action.ScriptPath=Join-Path $work $leaf
        Check (Test-GuiScanAction $script:Action) ('controls allowed for '+$leaf)
    }
    foreach($leaf in @('Invoke-GUIScanner.ps1','Invoke-AVUninstaller.ps1','Invoke-ReviewAndRemove.ps1','Repair-PowerOptions.ps1')){
        $script:Action.ScriptPath=Join-Path $work $leaf
        Check (-not (Test-GuiScanAction $script:Action)) ('controls excluded for '+$leaf)
    }
    $script:Action.ScriptPath=$fixture
    Check (-not (Test-GuiScanAction $script:Action -CloseLock $true)) 'approved persistence cleanup cannot be stopped by scan controls'
    Update-ScanControls
    Check ($ui.ScanControls.Visibility -eq 'Visible') 'real scan buttons are shown for our collector'
    $beat=Read-Beat $parentBeat
    Click-ScanControl 'BtnPauseScan'
    Start-Sleep -Milliseconds 400
    Check ($script:ScanPauseRequested -and (Read-Beat $parentBeat) -ne $beat) 'Pause after scan leaves the current collector running with its watchdogs intact'
    Click-ScanControl 'BtnPauseScan'
    Check (-not $script:ScanPauseRequested) 'a pending pause can be cleared without interrupting the collector'
    Click-ScanControl 'BtnPauseScan'
    $script:CloseLock=$true;Update-ScanControls;Click-ScanControl 'BtnStopScan'
    Check ($ui.ScanControls.Visibility -eq 'Collapsed' -and -not $parent.Process.HasExited) 'controls are hidden and inert after cleanup approval'
    $script:CloseLock=$false
    Click-ScanControl 'BtnStopScan'
    Check (-not $parent.Process.HasExited -and -not $script:Session.Stopped) 'closing the stop confirmation keeps the scan running'
    $script:Answer=[pscustomobject]@{Value='stop'}
    Click-ScanControl 'BtnStopScan'
    Check ($parent.Process.HasExited -and -not (Get-Process -Id $workerPid -ErrorAction SilentlyContinue)) 'Stop ends only the owned scan process tree'
    Check (-not $sibling.Process.HasExited) 'Stop leaves an unrelated process untouched'
    Check ($script:Session.Stopped -and (Get-GuiFinalStatus $script:Session) -ne 0 -and $script:Moves -eq 0) 'a cancelled scan cannot advance into later cleanup steps or return success'
    Check ($script:Session.Results[-1].Status -eq 'Cancelled') 'interrupted scan evidence is explicitly cancelled'
    $script:Session=New-GuiSession -Mode Offline -ToolRoot $repo
    $script:Child=$null;$script:Action=$null;$script:ScanPauseRequested=$true;$script:ScanWaiting=$false
    Continue-AfterScan -Action $scanAction
    Check ($script:ScanWaiting -and $script:Moves -eq 0 -and $ui.BtnPauseScan.Content -eq 'Resume') 'completed scan waits at the boundary before starting any later step'
    Click-ScanControl 'BtnPauseScan'
    Check (-not $script:ScanWaiting -and -not $script:ScanPauseRequested -and $script:Moves -eq 1) 'Resume advances the workflow exactly once'
    $script:ScanPauseRequested=$true
    $script:Session.RunRoot=$work
    [IO.File]::WriteAllText((Join-Path $work 'snapshot_before.json'),'{}')
    [void](Complete-GuiAction -Session $script:Session -Action $scanAction -ExitCode 0)
    Continue-AfterScan -Action $scanAction
    Click-ScanControl 'BtnStopScan'
    Check ($script:Session.Stopped -and $script:Session.Results[-1].Status -eq 'Done' -and $script:Session.StopMessage -match 'Completed scan results are kept') 'stopping between steps preserves completed scan evidence'
    Write-Host 'PASS: internal scan controls preserve cancellation, process ownership, pause boundaries and cleanup locks.'
} finally {
    if($parent){Stop-GuiChild $parent}
    if($sibling){Stop-GuiChild $sibling}
    $window.Close()
    $resolved=[IO.Path]::GetFullPath($work)
    if($resolved.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -match '^scc-gui-controls-[0-9a-f]{32}$') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
