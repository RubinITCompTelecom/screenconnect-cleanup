<#
.SYNOPSIS
    Stage 7 helper: diff two collect-snapshot.ps1 output files (before vs after).

.DESCRIPTION
    Matches items by their stable 'Key' field within each section and reports:
      - Removed : present in Before, absent in After  (proof of removal)
      - Added   : absent in Before, present in After  (catches resurrections)
      - Changed : same Key in both, but compared fields differ (volatile state)
    Sections that are plain objects (SystemSettings, Srum) are compared by value.
    Exit code: 0 = CLEAN, 1 = RESURRECTION or INCOMPLETE, 2 = usage/input
    error. Removed/changed items remain visible in the report for operator
    review.

    Verdict (precedence RESURRECTION > INCOMPLETE > CLEAN):
      - With -ManifestPath (the removal-manifest.json written by
        remove-screenconnect.ps1): RESURRECTION = a removal target recorded in
        the manifest (service name, scheduled task, Run-key value, WMI
        subscription name, uninstall display name, quarantined path) is still
        present in the AFTER snapshot. This also catches a removed item that
        came back under the same name. Unrelated new stable items are reported
        as 'NewSinceBefore' (informational), not as a resurrection.
      - Without a manifest (or one with no usable targets): any stable item
        added in AFTER is a RESURRECTION (original behaviour).
      - INCOMPLETE = a collection failure in a section the verdict depends on
        (the stable sections). Errors recorded for informational, volatile or
        object sections are reported (InformationalCollectionErrors) but never
        change the verdict, and never hide a resurrection.

    PowerShell 5.1 compatible. Pure ASCII.

.PARAMETER BeforeFile
    Path to the 'before' snapshot JSON (Stage 1).

.PARAMETER AfterFile
    Path to the 'after' snapshot JSON (Stage 7).

.PARAMETER OutFile
    Optional path for a JSON diff report. Default: alongside AfterFile,
    named <after-stem>.diff.json.

.PARAMETER ManifestPath
    Optional removal-manifest.json from remove-screenconnect.ps1. Enables the
    "removal target still present" verdict described above. Alias:
    -RemovalManifest (the name the other scripts use for the same file).

.EXAMPLE
    .\diff-snapshots.ps1 -BeforeFile snap-before.json -AfterFile snap-after.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BeforeFile,
    [Parameter(Mandatory = $true)][string]$AfterFile,
    [string]$OutFile,
    [Alias('RemovalManifest')][string]$ManifestPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Sections that are arrays of keyed items.
# VolatileState sections: identity keys are stable but values churn every run
# (PIDs, timestamps, connection tuples) - changes there are EXPECTED and do not
# fail the run; only Added/Removed matter as signals.
# StableState sections: any Added/Removed item is a real signal (possible
# resurrection); Changed is also reported.
# ObjectSections are compared wholesale by serialized value.
# ---------------------------------------------------------------------------
$VolatileSections = @('Processes', 'Connections', 'RecentFiles')
$StableSections   = @('Services', 'ScheduledTasks', 'RegistryAutoruns',
                      'StartupFolders', 'InstalledPrograms', 'LocalAccounts',
                      'FirewallRules', 'WmiPersistence')
$InformationalSections = @('Prefetch', 'ShimCache', 'BamDam', 'UserAssist', 'Amcache')
$ObjectSections   = @('Srum', 'SystemSettings')

function Read-Snapshot {
    param([string]$Path, [string]$Role)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Role file not found: $Path"
    }
    try {
        $obj = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "$Role file is not valid JSON ($Path): $($_.Exception.Message)"
    }
    return $obj
}

function Get-JsonItems {
    param($Value)
    if ($null -eq $Value) { return , @() }
    if ($Value -is [pscustomobject] -and @($Value.PSObject.Properties).Count -eq 0) { return , @() }
    if ($Value -is [System.Array]) { return , @($Value) }
    return , @($Value)
}

function Get-SnapshotSection {
    param($Snapshot, [string]$Name)
    if ($null -eq $Snapshot) { return $null }
    $sectionsProp = $Snapshot.PSObject.Properties['Sections']
    if (-not $sectionsProp -or $null -eq $sectionsProp.Value) { return $null }
    $sectionProp = $sectionsProp.Value.PSObject.Properties[$Name]
    if (-not $sectionProp) { return $null }
    return $sectionProp.Value
}

function Get-SnapshotCollectionComplete {
    param($Snapshot)
    if ($null -eq $Snapshot) { return $false }
    $completeProp = $Snapshot.PSObject.Properties['CollectionComplete']
    if ($completeProp) { return [bool]$completeProp.Value }
    $errorsProp = $Snapshot.PSObject.Properties['CollectionErrors']
    if (-not $errorsProp) { return $true }
    $errors = Get-JsonItems $errorsProp.Value
    return ($errors.Count -eq 0)
}

function Get-SnapshotCollectionErrors {
    param($Snapshot)
    if ($null -eq $Snapshot) { return @('Snapshot object is null') }
    $errorsProp = $Snapshot.PSObject.Properties['CollectionErrors']
    if (-not $errorsProp) { return @() }
    return @(Get-JsonItems $errorsProp.Value)
}

function Get-SnapshotCollectionWarnings {
    param($Snapshot)
    if ($null -eq $Snapshot) { return @() }
    $warningsProp = $Snapshot.PSObject.Properties['CollectionWarnings']
    if (-not $warningsProp) { return @() }
    return @(Get-JsonItems $warningsProp.Value)
}

# Split a snapshot's collection errors into those the verdict depends on and
# those that are informational only. An error is informational when its Section
# names an informational, volatile or object section; anything else (a stable
# section, an unknown or missing section name) gates the verdict, so an
# unrecognised failure still fails closed.
function Get-CollectionStatus {
    param($Snapshot)
    $nonGating = @($InformationalSections) + @($VolatileSections) + @($ObjectSections)
    $gating = New-Object System.Collections.Generic.List[object]
    $informational = New-Object System.Collections.Generic.List[object]
    # Get-SnapshotCollectionErrors can hand back a nested empty array on 5.1; flatten.
    $flat = New-Object System.Collections.Generic.List[object]
    foreach ($x in @(Get-SnapshotCollectionErrors -Snapshot $Snapshot)) {
        if ($x -is [System.Array]) { foreach ($y in $x) { if ($null -ne $y) { $flat.Add($y) } } }
        elseif ($null -ne $x) { $flat.Add($x) }
    }
    foreach ($e in $flat) {
        $sec = $null
        if ($null -ne $e -and $e -isnot [string]) {
            $secProp = $e.PSObject.Properties['Section']
            if ($secProp) { $sec = [string]$secProp.Value }
        }
        if ($sec -and ($nonGating -contains $sec)) { $informational.Add($e) } else { $gating.Add($e) }
    }
    $complete = $false
    if ($null -ne $Snapshot) {
        $flagProp = $Snapshot.PSObject.Properties['CollectionComplete']
        if ($flagProp -and [bool]$flagProp.Value) {
            $complete = $true
        } elseif ($flagProp) {
            # Flag says incomplete: trust that only when at least one error is
            # recorded and none of them is in a section the verdict uses.
            $complete = (($gating.Count -eq 0) -and ($informational.Count -gt 0))
        } else {
            $complete = ($gating.Count -eq 0)
        }
    }
    return [pscustomobject]@{
        Complete      = $complete
        Gating        = $gating.ToArray()
        Informational = $informational.ToArray()
    }
}

# ---- removal-manifest target matching --------------------------------------
function ConvertTo-RegPathNorm {
    param([string]$Text, [string]$Hive = '', [string]$UserSid = '')
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $Text = $Text -replace '(?i)^(Microsoft\.PowerShell\.Core\\)?Registry::', ''
    $s = $Text.ToLowerInvariant().Replace('/', '\').Replace('|', '\').Replace(':', '')
    $s = [regex]::Replace($s, '\\+', '\')
    $s = $s -replace '^hkey_local_machine\\', 'hklm\' -replace '^hkey_current_user\\', 'hkcu\' -replace '^hkey_users\\', 'hku\'
    if ($s -notmatch '^(hklm|hkcu|hku|hkcr)\\' -and $Hive) { $s = $Hive.ToLowerInvariant() + '\' + $s }
    if ($s -match '^hkcu\\' -and $UserSid) { $s = 'hku\' + $UserSid.ToLowerInvariant() + '\' + $s.Substring(5) }
    return $s.Trim('\')
}

function ConvertTo-PathNorm {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $s = $Text.ToLowerInvariant().Replace('/', '\')
    $s = [regex]::Replace($s, '\\+', '\')
    return $s.TrimEnd('\')
}

# Read the removal manifest into a target list. Never throws; Error explains why
# no targets were produced.
function Read-ManifestTargets {
    param([string]$Path)
    $result = [ordered]@{ Targets = @(); Error = $null; IdentityIncomplete = $false }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $result.Error = 'Manifest file not found.'
            return [pscustomobject]$result
        }
        $m = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $entriesProp = $null
        if ($null -ne $m) { $entriesProp = $m.PSObject.Properties['Entries'] }
        if (-not $entriesProp) {
            $result.Error = 'Manifest has no Entries.'
            return [pscustomobject]$result
        }
        $targets = New-Object System.Collections.Generic.List[object]
        $entryItems = Get-JsonItems $entriesProp.Value
        foreach ($e in $entryItems) {
            if ($null -eq $e) { continue }
            $action = [string]$e.Action
            $res = [string]$e.Result
            if ($res -eq 'DryRun' -or $res -eq 'Rejected') { continue }
            $target = [string]$e.Target
            $kind = $null
            $values = @()
            switch ($action) {
                { $_ -in @('StopService', 'DeleteService') } { $kind = 'service'; $values = @($target) }
                'DeleteScheduledTask' { $kind = 'task'; $values = @($target) }
                'DeleteRunKey' { $kind = 'runkey'; $values = @($target) }
                'DeleteWmiSubscription' {
                    $kind = 'wmi'
                    $values = @($target -split '\s+->\s+')
                }
                'Uninstall' { $kind = 'program'; $values = @($target) }
                'Quarantine' {
                    $kind = 'path'
                    $values = @($target)
                    if ($e.PSObject.Properties['SourcePath'] -and $e.SourcePath) { $values = @([string]$e.SourcePath) }
                }
            }
            if (-not $kind) { continue }
            foreach ($v in $values) {
                $v = ([string]$v).Trim()
                if (-not $v -or $v -eq 'N/A' -or $v -eq 'Registry' -or $v -match '^PID \d+$') { continue }
                if ($kind -eq 'path') {
                    $np = ConvertTo-PathNorm $v
                    # Refuse over-broad paths (drive roots, C:\Windows, C:\Program Files...).
                    if (@($np -split '\\' | Where-Object { $_ }).Count -lt 3) { continue }
                }
                if ($kind -eq 'runkey' -and (ConvertTo-RegPathNorm $v) -match '^hkcu\\') {
                    # Old manifests do not identify which user's HKCU was used.
                    # Never guess a SID from the account running this later diff.
                    $result.IdentityIncomplete = $true
                }
                $targets.Add([pscustomobject]@{ Kind = $kind; Value = $v; Action = $action; Result = $res })
            }
        }
        $result.Targets = $targets.ToArray()
    } catch {
        $result.Error = "Could not read manifest: $($_.Exception.Message)"
    }
    return [pscustomobject]$result
}

function Get-ItemStrings {
    # All string values of an item (nested objects/arrays to a small depth).
    param($Item)
    $out = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@($Item, 0))
    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $v = $frame[0]; $d = [int]$frame[1]
        if ($null -eq $v) { continue }
        if ($v -is [string]) { $out.Add($v); continue }
        if ($d -ge 4) { continue }
        if ($v -is [System.Array]) {
            foreach ($x in $v) { $stack.Push(@($x, ($d + 1))) }
        } elseif ($v -is [pscustomobject]) {
            foreach ($p in $v.PSObject.Properties) { $stack.Push(@($p.Value, ($d + 1))) }
        }
    }
    return , $out.ToArray()
}

function Test-TextHasPath {
    param([string]$Haystack, [string]$NormPath)
    $h = ConvertTo-PathNorm $Haystack
    $start = 0
    while ($start -lt $h.Length) {
        $i = $h.IndexOf($NormPath, $start, [System.StringComparison]::Ordinal)
        if ($i -lt 0) { return $false }
        $before = if ($i -eq 0) { [char]32 } else { $h[$i - 1] }
        $endIdx = $i + $NormPath.Length
        $after = if ($endIdx -ge $h.Length) { [char]32 } else { $h[$endIdx] }
        if (-not [char]::IsLetterOrDigit($before) -and ($after -match '[\\\s",;'')\]]')) { return $true }
        $start = $i + 1
    }
    return $false
}

# Return the AFTER-snapshot stable items that still match a manifest target.
function Find-TargetsStillPresent {
    param($Targets, $AfterItemsBySection)
    $found = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $byKind = @{}
    foreach ($t in @($Targets)) {
        if (-not $byKind.ContainsKey($t.Kind)) { $byKind[$t.Kind] = New-Object System.Collections.Generic.List[object] }
        $byKind[$t.Kind].Add($t)
    }
    foreach ($section in $AfterItemsBySection.Keys) {
        foreach ($it in @($AfterItemsBySection[$section])) {
            if ($null -eq $it) { continue }
            $key = Get-ItemKey $it
            $hits = New-Object System.Collections.Generic.List[object]
            if ($section -eq 'Services' -and $byKind.ContainsKey('service')) {
                foreach ($t in $byKind['service']) {
                    if (("$($it.Name)" -ieq $t.Value) -or ($key -ieq $t.Value)) { $hits.Add($t) }
                }
            }
            if ($section -eq 'ScheduledTasks' -and $byKind.ContainsKey('task')) {
                $full = ConvertTo-PathNorm ("$($it.TaskPath)".TrimEnd('\') + '\' + "$($it.TaskName)")
                foreach ($t in $byKind['task']) {
                    $tv = (ConvertTo-PathNorm $t.Value).TrimStart('\')
                    if ($tv -and ($full.TrimStart('\') -eq $tv)) { $hits.Add($t) }
                }
            }
            if ($section -eq 'RegistryAutoruns' -and $byKind.ContainsKey('runkey')) {
                $itemNorm = ConvertTo-RegPathNorm ("$($it.KeyPath)\$($it.ValueName)") -Hive ([string]$it.Hive) -UserSid ([string]$it.UserSid)
                foreach ($t in $byKind['runkey']) {
                    if ($itemNorm -and ($itemNorm -eq (ConvertTo-RegPathNorm $t.Value))) { $hits.Add($t) }
                }
            }
            if ($section -eq 'WmiPersistence' -and $byKind.ContainsKey('wmi') -and ($key -notmatch '\|Binding\|')) {
                $leaf = ($key -split '\|')[-1]
                foreach ($t in $byKind['wmi']) {
                    if ($leaf -and ($leaf -ieq $t.Value)) { $hits.Add($t) }
                }
            }
            if ($section -eq 'InstalledPrograms' -and $byKind.ContainsKey('program')) {
                foreach ($t in $byKind['program']) {
                    if ("$($it.DisplayName)" -ieq $t.Value) { $hits.Add($t) }
                }
            }
            if ($byKind.ContainsKey('path')) {
                $strings = $null
                foreach ($t in $byKind['path']) {
                    if ($null -eq $strings) { $strings = Get-ItemStrings $it }
                    $np = ConvertTo-PathNorm $t.Value
                    foreach ($s in $strings) {
                        if (Test-TextHasPath -Haystack $s -NormPath $np) { $hits.Add($t); break }
                    }
                }
            }
            foreach ($t in $hits) {
                $id = "$section|$key|$($t.Kind)|$($t.Value)"
                if ($seen.ContainsKey($id)) { continue }
                $seen[$id] = $true
                $found.Add([pscustomobject]@{
                    Section        = $section
                    Key            = $key
                    TargetKind     = $t.Kind
                    ManifestAction = $t.Action
                    ManifestTarget = $t.Value
                    ManifestResult = $t.Result
                })
            }
        }
    }
    return $found.ToArray()
}

function Get-ObjectCompareValue {
    # SRUM's offline copy path is intentionally timestamped and therefore
    # cannot be used as an activity signal. Compare only the database identity
    # fields promised by the snapshot schema.
    param([string]$SectionName, $Value)
    if ($SectionName -eq 'Srum') {
        if ($null -eq $Value) { return $null }
        return [pscustomobject]@{
            DatabasePresent = $Value.DatabasePresent
            DatabaseSha256  = $Value.DatabaseSha256
        }
    }
    return $Value
}

# Normalize an item to its Key string. Missing Key -> synthesized marker so it
# still shows up in the report instead of being silently dropped.
function Get-ItemKey {
    param($Item)
    if ($null -eq $Item) { return '<null>' }
    $k = $Item.Key
    if ($null -eq $k -or "$k" -eq '') { return '<missing-key>' }
    return [string]$k
}

# Compare two items with the same Key; returns list of differing field names.
function Get-ComparableJson {
    param($Value)
    try {
        # InputObject is deliberate: piping a singleton array enumerates it and
        # changes the JSON shape under Windows PowerShell 5.1.
        return ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    } catch {
        return '<unserializable>'
    }
}

# True when the two values are provably equal without serializing: both null,
# or both simple scalars of a comparable kind. Returns $null when the pair is
# not a scalar pair (caller falls back to the structural JSON comparison).
function Test-ScalarEqual {
    param($A, $B)
    if ($null -eq $A -and $null -eq $B) { return $true }
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A -is [string] -and $B -is [string]) { return [string]::Equals($A, $B, [System.StringComparison]::OrdinalIgnoreCase) }
    if ($A -is [bool] -and $B -is [bool]) { return ($A -eq $B) }
    $aNum = ($A -is [int] -or $A -is [long] -or $A -is [double] -or $A -is [decimal] -or $A -is [single])
    $bNum = ($B -is [int] -or $B -is [long] -or $B -is [double] -or $B -is [decimal] -or $B -is [single])
    if ($aNum -and $bNum) {
        $aFloat = ($A -is [double] -or $A -is [single])
        $bFloat = ($B -is [double] -or $B -is [single])
        if ($aFloat -and $bFloat) { return ([double]$A -eq [double]$B) }
        if ($aFloat -or $bFloat) { return $null } # preserve each value's serialized precision
        return ([decimal]$A -eq [decimal]$B)
    }
    if ($A -is [string] -or $B -is [string] -or $A -is [bool] -or $B -is [bool] -or $aNum -or $bNum) { return $false }
    return $null
}

function Test-ValueEqual {
    param($A, $B)
    $s = Test-ScalarEqual $A $B
    if ($null -ne $s) { return [bool]$s }
    return ((Get-ComparableJson $A) -eq (Get-ComparableJson $B))
}

function Get-ChangedFields {
    param($BeforeItem, $AfterItem)
    $diffs = New-Object System.Collections.Generic.List[string]
    $bp = $BeforeItem.PSObject.Properties
    $ap = $AfterItem.PSObject.Properties
    foreach ($p in $ap) {
        if (-not $bp[$p.Name]) {
            $diffs.Add("+$($p.Name)")
            continue
        }
        if (-not (Test-ValueEqual $bp[$p.Name].Value $p.Value)) { $diffs.Add($p.Name) }
    }
    foreach ($p in $bp) {
        if (-not $ap[$p.Name]) { $diffs.Add("-$($p.Name)") }
    }
    return , $diffs.ToArray()
}

# Index items by Key. Duplicate keys get a #N suffix so none are dropped.
function New-KeyMap {
    param($Items)
    $map = @{}
    $dups = New-Object System.Collections.Generic.List[string]
    foreach ($it in @($Items)) {
        $baseKey = Get-ItemKey $it
        $mapKey = $baseKey
        $suffix = 2
        while ($map.ContainsKey($mapKey)) {
            $mapKey = "$baseKey#$suffix"
            $suffix++
        }
        if ($mapKey -ne $baseKey) { $dups.Add($baseKey) }
        $map[$mapKey] = $it
    }
    return [pscustomobject]@{ Map = $map; Duplicates = $dups }
}

function Get-SectionDiff {
    param([string]$SectionName, $BeforeItems, $AfterItems, [string]$Kind = 'stable')

    $bIdx = New-KeyMap $BeforeItems
    $aIdx = New-KeyMap $AfterItems
    $beforeMap = $bIdx.Map
    $afterMap = $aIdx.Map

    $removed = New-Object System.Collections.Generic.List[string]
    $added = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[object]

    foreach ($k in $beforeMap.Keys) {
        if (-not $afterMap.ContainsKey($k)) { $removed.Add([string]$k) }
    }
    foreach ($k in $afterMap.Keys) {
        if (-not $beforeMap.ContainsKey($k)) { $added.Add([string]$k) }
    }
    foreach ($k in $beforeMap.Keys) {
        if ($afterMap.ContainsKey($k)) {
            $fields = Get-ChangedFields -BeforeItem $beforeMap[$k] -AfterItem $afterMap[$k]
            if (@($fields).Count -gt 0) {
                $changed.Add([pscustomobject]@{ Key = $k; Fields = $fields })
            }
        }
    }

    $allDups = New-Object System.Collections.Generic.List[string]
    $allDups.AddRange($bIdx.Duplicates)
    $allDups.AddRange($aIdx.Duplicates)

    # Sorted output so the report itself has zero ordering noise.
    return [pscustomobject]@{
        Section     = $SectionName
        Kind        = $Kind
        BeforeCount = @($BeforeItems).Count
        AfterCount  = @($AfterItems).Count
        Removed     = @($removed | Sort-Object)
        Added       = @($added   | Sort-Object)
        Changed     = $changed.ToArray()
        DuplicateKeys = @($allDups | Sort-Object -Unique)
    }
}

function Compare-ObjectSection {
    param([string]$SectionName, $BeforeValue, $AfterValue)
    $beforeComparable = Get-ObjectCompareValue -SectionName $SectionName -Value $BeforeValue
    $afterComparable = Get-ObjectCompareValue -SectionName $SectionName -Value $AfterValue
    $changed = New-Object System.Collections.Generic.List[string]
    if (-not (Test-ValueEqual $beforeComparable $afterComparable)) {
        # Field-level comparison where both sides are PSCustomObjects.
        if ($beforeComparable -is [pscustomobject] -and $afterComparable -is [pscustomobject]) {
            $bp = $beforeComparable.PSObject.Properties
            $ap = $afterComparable.PSObject.Properties
            foreach ($p in $ap) {
                if (-not $bp[$p.Name]) { $changed.Add("+$($p.Name)"); continue }
                if (-not (Test-ValueEqual $bp[$p.Name].Value $p.Value)) { $changed.Add($p.Name) }
            }
            foreach ($p in $bp) {
                if (-not $ap[$p.Name]) { $changed.Add("-$($p.Name)") }
            }
        }
        if ($changed.Count -eq 0) { $changed.Add('value') }
    }
    return [pscustomobject]@{
        Section     = $SectionName
        Kind        = 'object'
        BeforeCount = -1
        AfterCount  = -1
        Removed     = @()
        Added       = @()
        Changed     = $changed.ToArray()
    }
}
# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    $before = Read-Snapshot -Path $BeforeFile -Role 'Before'
    $after  = Read-Snapshot -Path $AfterFile  -Role 'After'
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

if (-not $OutFile) {
    $dir = Split-Path -Parent $AfterFile
    if (-not $dir) { $dir = '.' }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($AfterFile)
    $OutFile = Join-Path $dir ($stem + '.diff.json')
}

$beforeStatus = Get-CollectionStatus -Snapshot $before
$afterStatus = Get-CollectionStatus -Snapshot $after
$beforeCompleteRaw = Get-SnapshotCollectionComplete -Snapshot $before
$afterCompleteRaw = Get-SnapshotCollectionComplete -Snapshot $after
# Before/AfterCollectionComplete now mean "complete for the sections the
# verdict depends on"; the raw snapshot flags are kept as *CompleteRaw.
$beforeComplete = $beforeStatus.Complete
$afterComplete = $afterStatus.Complete
$beforeErrors = Get-SnapshotCollectionErrors -Snapshot $before
$afterErrors = Get-SnapshotCollectionErrors -Snapshot $after
$beforeWarnings = Get-SnapshotCollectionWarnings -Snapshot $before
$afterWarnings = Get-SnapshotCollectionWarnings -Snapshot $after

$sectionDiffsList = New-Object System.Collections.Generic.List[object]
$afterStableItems = [ordered]@{}

foreach ($name in $StableSections) {
    $b = Get-JsonItems (Get-SnapshotSection -Snapshot $before -Name $name)
    $a = Get-JsonItems (Get-SnapshotSection -Snapshot $after -Name $name)
    $afterStableItems[$name] = $a
    $sectionDiffsList.Add((Get-SectionDiff -SectionName $name -BeforeItems $b -AfterItems $a -Kind 'stable'))
}
foreach ($name in $VolatileSections) {
    $b = Get-JsonItems (Get-SnapshotSection -Snapshot $before -Name $name)
    $a = Get-JsonItems (Get-SnapshotSection -Snapshot $after -Name $name)
    $sectionDiffsList.Add((Get-SectionDiff -SectionName $name -BeforeItems $b -AfterItems $a -Kind 'volatile'))
}
foreach ($name in $InformationalSections) {
    $b = Get-JsonItems (Get-SnapshotSection -Snapshot $before -Name $name)
    $a = Get-JsonItems (Get-SnapshotSection -Snapshot $after -Name $name)
    $sectionDiffsList.Add((Get-SectionDiff -SectionName $name -BeforeItems $b -AfterItems $a -Kind 'informational'))
}
foreach ($name in $ObjectSections) {
    $sectionDiffsList.Add((Compare-ObjectSection -SectionName $name `
        -BeforeValue (Get-SnapshotSection -Snapshot $before -Name $name) -AfterValue (Get-SnapshotSection -Snapshot $after -Name $name)))
}
$sectionDiffs = $sectionDiffsList.ToArray()

# Stable items that appear in AFTER only.
$stableAdded = New-Object System.Collections.Generic.List[object]
foreach ($d in $sectionDiffs) {
    if ($d.Kind -eq 'stable') {
        foreach ($k in $d.Added) { $stableAdded.Add([pscustomobject]@{ Section = $d.Section; Key = $k }) }
    }
}

# Manifest-based judgement: is a removal target still present in AFTER?
$manifestUsed = $false
$manifestError = $null
$manifestTargetCount = 0
$targetsStillPresent = @()
$manifestIdentityIncomplete = $false
if ($ManifestPath) {
    $mt = Read-ManifestTargets -Path $ManifestPath
    $manifestError = $mt.Error
    $manifestIdentityIncomplete = $mt.IdentityIncomplete
    if ($manifestIdentityIncomplete) { $manifestError = 'Legacy HKCU target lacks a user SID; removal identity cannot be verified.' }
    $manifestTargetCount = @($mt.Targets).Count
    if (-not $manifestError -and $manifestTargetCount -eq 0) {
        $manifestError = 'Manifest has no usable removal targets; falling back to snapshot-only comparison.'
    }
    if ($manifestTargetCount -gt 0) {
        $manifestUsed = $true
        $targetsStillPresent = @(Find-TargetsStillPresent -Targets $mt.Targets -AfterItemsBySection $afterStableItems)
    }
}

if ($manifestUsed) {
    $resurrectionCount = $targetsStillPresent.Count
    $verdictBasis = 'manifest'
} else {
    $resurrectionCount = $stableAdded.Count
    $verdictBasis = 'snapshot-added'
}
$newSinceBefore = if ($manifestUsed) { $stableAdded.ToArray() } else { @() }

# Precedence: RESURRECTION > INCOMPLETE > CLEAN. Completeness is judged on the
# stable sections only (informational errors are reported, never decisive).
$collectionComplete = ($beforeComplete -and $afterComplete -and -not $manifestIdentityIncomplete)
$verdict = if ($resurrectionCount -gt 0) { 'RESURRECTION' } elseif (-not $collectionComplete) { 'INCOMPLETE' } else { 'CLEAN' }
$informationalErrors = @($beforeStatus.Informational) + @($afterStatus.Informational)
$report = [ordered]@{
    SchemaVersion          = 1
    DiffUtc                = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    BeforeFile             = (Split-Path -Leaf $BeforeFile)
    BeforeLabel            = $before.Label
    BeforeCollectedUtc     = $before.CollectedUtc
    BeforeCollectionComplete = $beforeComplete
    BeforeCollectionCompleteRaw = $beforeCompleteRaw
    BeforeCollectionErrors = $beforeErrors
    BeforeCollectionWarnings = $beforeWarnings
    AfterFile              = (Split-Path -Leaf $AfterFile)
    AfterLabel             = $after.Label
    AfterCollectedUtc      = $after.CollectedUtc
    AfterCollectionComplete = $afterComplete
    AfterCollectionCompleteRaw = $afterCompleteRaw
    AfterCollectionErrors  = $afterErrors
    AfterCollectionWarnings = $afterWarnings
    SameComputerName       = ("$($before.ComputerName)" -eq "$($after.ComputerName)")
    ResurrectionsAdded     = $resurrectionCount
    Verdict                = $verdict
    VerdictBasis           = $verdictBasis
    StableCollectionComplete = $collectionComplete
    InformationalCollectionErrors = $informationalErrors
    ManifestUsed           = $manifestUsed
    ManifestFile           = $(if ($ManifestPath) { Split-Path -Leaf $ManifestPath } else { $null })
    ManifestError          = $manifestError
    ManifestTargetCount    = $manifestTargetCount
    TargetsStillPresent    = $targetsStillPresent
    NewSinceBefore         = $newSinceBefore
    Sections               = $sectionDiffs
}

$json = $report | ConvertTo-Json -Depth 8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutFile, $json, $utf8NoBom)

# Console summary
Write-Host "Snapshot diff: $($report.BeforeFile) -> $($report.AfterFile)"
if (-not $report.SameComputerName) {
    Write-Warning "ComputerName differs between snapshots ('$($before.ComputerName)' vs '$($after.ComputerName)') - diff may be meaningless."
}
foreach ($d in $sectionDiffs) {
    $line = "{0,-18} {1,-8} before={2,-5} after={3,-5} removed={4,-3} added={5,-3} changed={6}" -f `
        $d.Section, $d.Kind, `
        $(if ($d.BeforeCount -ge 0) { $d.BeforeCount } else { '-' }), `
        $(if ($d.AfterCount -ge 0) { $d.AfterCount } else { '-' }), `
        $d.Removed.Count, $d.Added.Count, @($d.Changed).Count
    Write-Host $line
    foreach ($r in $d.Removed) { Write-Host "    REMOVED  $r" }
    foreach ($a in $d.Added)   { Write-Host "    ADDED    $a" }
    foreach ($c in @($d.Changed)) {
        if ($c -is [string]) { Write-Host "    CHANGED  $c" }
        else { Write-Host ("    CHANGED  {0} ({1})" -f $c.Key, ($c.Fields -join ', ')) }
    }
}
Write-Host ""
if ($manifestUsed) {
    foreach ($tp in $targetsStillPresent) {
        Write-Host ("    TARGET STILL PRESENT  [{0}] {1}  (manifest {2}: {3} -> {4})" -f $tp.Section, $tp.Key, $tp.ManifestAction, $tp.ManifestTarget, $tp.ManifestResult)
    }
    foreach ($n in $newSinceBefore) { Write-Host "    NEW SINCE BEFORE (not a removal target)  [$($n.Section)] $($n.Key)" }
}
if ($manifestError) { Write-Warning "Manifest: $manifestError" }
foreach ($ie in $informationalErrors) {
    Write-Host ("    [info] collection error in {0} (does not change the verdict): {1}" -f $ie.Section, $ie.Error)
}
if ($manifestUsed) {
    Write-Host "Verdict: $($report.Verdict)  (removal targets still present: $resurrectionCount of $manifestTargetCount; new unrelated stable items: $(@($newSinceBefore).Count); stable collections complete: $collectionComplete)"
} else {
    Write-Host "Verdict: $($report.Verdict)  (added-in-after stable items: $resurrectionCount; collections complete: $collectionComplete)"
}
Write-Host "Report written to: $OutFile"

exit $(if ($report.Verdict -eq 'CLEAN') { 0 } else { 1 })
