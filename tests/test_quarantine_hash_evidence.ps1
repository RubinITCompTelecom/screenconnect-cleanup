# Source identity and CSV evidence must describe the same bytes, read once.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'remove-screenconnect.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-Sha256Hex', 'Get-PathIdentityHash')) {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:reads = 0
function Get-Sha256File {
    param([string]$Path)
    $script:reads++
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
$work = Join-Path $env:TEMP ('scc-hash-evidence-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $work 'nested') -Force
    [IO.File]::WriteAllText((Join-Path $work 'a.txt'), 'alpha')
    [IO.File]::WriteAllText((Join-Path $work 'nested\b.txt'), 'beta')
    $rows = @()
    $identity = Get-PathIdentityHash -Path $work -FileHashes ([ref]$rows)
    if ($script:reads -ne 2 -or $rows.Count -ne 2) { throw 'Source files must be read once for identity and sidecar evidence.' }
    $expectedLines = foreach ($row in $rows) {
        $actual = (Get-FileHash -LiteralPath $row.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($row.SHA256 -ne $actual -or $row.Length -ne (Get-Item -LiteralPath $row.Path).Length) { throw 'Sidecar evidence differs from file bytes.' }
        $relative = $row.Path.Substring($work.Length).TrimStart('\').ToLowerInvariant()
        $relative + '|' + $row.Length + '|' + $actual
    }
    $expected = Get-Sha256Hex -Text ('directory`n' + (($expectedLines | Sort-Object) -join "`n"))
    if ($identity -ne $expected) { throw 'Identity format changed.' }
    # The same verifier remains usable at the destination, without requesting rows.
    if ((Get-PathIdentityHash -Path $work) -ne $identity) { throw 'Independent verification disagrees.' }
    [IO.File]::WriteAllText((Join-Path $work 'a.txt'), 'tampered')
    if ((Get-PathIdentityHash -Path $work) -eq $identity) { throw 'Changed file bytes did not change the identity.' }
    $outside = $work + '-outside'
    $link = Join-Path $work 'junction'
    $null = New-Item -ItemType Directory -Path $outside
    try {
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        $refused = $false
        try { $null = Get-PathIdentityHash -Path $work }
        catch { if ($_.Exception.Message -match 'Reparse point encountered') { $refused = $true } else { throw } }
        if (-not $refused) { throw 'A source-tree junction was not refused.' }
    } finally {
        if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
        if (Test-Path -LiteralPath $outside) { [IO.Directory]::Delete($outside) }
    }
    Write-Host 'PASS: one source read per file, matching sidecar evidence, stable identity, tamper detection.'
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
