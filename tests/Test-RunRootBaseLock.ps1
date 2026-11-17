<#
  Regression: New-SccProtectedRunRoot must also lock the BASE folder (C:\RIT-SCC) that
  holds the run folders. The base inherits "Authenticated Users: Modify" from C:\, and
  Test-ResumeMaterialsTrusted (remove-screenconnect.ps1) walks every ancestor of the
  resume materials, so an open base made the reboot-resume task refuse to register.

  Part 1 (no admin): a throwaway copy of the module that trusts the current account
  (same trick as Test-PhaseSplit.ps1) creates a base folder under a parent that grants
  Users Modify (like C:\), for a new base AND an existing open one (older version), and
  checks the base ACL: protected, no Users write rights, no inherited ACEs, Users read.
  Also: a junction at the base is refused and its target's ACL is untouched.

  Part 2 (needs admin + a writable C:\): the REAL module and the REAL
  Test-ResumeMaterialsTrusted must accept a fresh run folder. SKIPPED (stated) otherwise.

  Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-RunRootBaseLock.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$modPath = Join-Path $RepoRoot 'tools\RunRootSecurity.psm1'

$script:fail = 0
function Check { param([bool]$Ok, [string]$Msg) if ($Ok) { Write-Host ('ok:   ' + $Msg) } else { $script:fail++; Write-Host ('FAIL: ' + $Msg) } }

$tmp = Join-Path $env:TEMP ('scc-baselock-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
    # ---- Part 1: throwaway module trusting the current account
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $txt = [IO.File]::ReadAllText($modPath)
    $pairs = @(
        @("`$script:SccTrustedWriterSids = @('S-1-5-32-544', 'S-1-5-18')", "`$script:SccTrustedWriterSids = @('$me', 'S-1-5-32-544', 'S-1-5-18')"),
        @("`$script:SccRunRootOwnerSid = 'S-1-5-32-544'", "`$script:SccRunRootOwnerSid = '$me'"))
    foreach ($p in $pairs) {
        if (-not $txt.Contains($p[0])) { throw ('line not found in RunRootSecurity.psm1: ' + $p[0]) }
        $txt = $txt.Replace($p[0], $p[1])
    }
    $copy = Join-Path $tmp 'RunRootSecurity.test.psm1'
    [IO.File]::WriteAllText($copy, $txt, (New-Object Text.UTF8Encoding $false))
    Import-Module $copy -Force -DisableNameChecking

    # A parent that behaves like C:\ : Users get Modify, inherited by subfolders.
    $parent = Join-Path $tmp 'fakeC'
    $null = New-Item -ItemType Directory -Path $parent -Force
    $users = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $pacl = Get-Acl -LiteralPath $parent
    $pacl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, [System.Security.AccessControl.FileSystemRights]::Modify, ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'), [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)))
    Set-Acl -LiteralPath $parent -AclObject $pacl

    $writeBits = [int64](0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000)
    function Assert-BaseLocked {
        param([string]$Base, [string]$Label)
        $acl = Get-Acl -LiteralPath $Base
        Check $acl.AreAccessRulesProtected ($Label + ': base ACL is protected (no inheritance)')
        $inh = @($acl.Access | Where-Object { $_.IsInherited })
        Check ($inh.Count -eq 0) ($Label + ': base has no inherited ACEs')
        $bad = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
                $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -eq 'S-1-5-32-545' -and (([int64]$_.FileSystemRights -band $writeBits) -ne 0) })
        Check ($bad.Count -eq 0) ($Label + ': Users have no write/delete/takeover rights on the base')
        $rd = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
                $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -eq 'S-1-5-32-545' -and (([int64]$_.FileSystemRights -band 0x20001) -ne 0) })
        Check ($rd.Count -ge 1) ($Label + ': Users can still read the base')
    }

    # new base
    $base1 = Join-Path $parent 'RIT-SCC'
    $run1 = New-SccProtectedRunRoot -Root $base1
    Check (Test-Path -LiteralPath $run1 -PathType Container) 'new base: run folder created'
    Check ($run1.StartsWith($base1 + '\')) 'new base: run folder is under the base'
    Assert-BaseLocked $base1 'new base'

    # existing open base from an older version (inherits Users Modify), then re-run
    $base2 = Join-Path $parent 'RIT-SCC-old'
    $null = New-Item -ItemType Directory -Path $base2 -Force
    $before = @((Get-Acl -LiteralPath $base2).Access | Where-Object { $_.IdentityReference.Value -like '*Users' -and ([int64]$_.FileSystemRights -band $writeBits) })
    Check ($before.Count -ge 1) 'old base: starts open (Users can write, inherited from the fake C:\)'
    $run2 = New-SccProtectedRunRoot -Root $base2
    Assert-BaseLocked $base2 'old base'
    Check (Test-Path -LiteralPath $run2 -PathType Container) 'old base: run folder created after re-lock'

    # a second run under the already-locked base keeps working
    $run3 = New-SccProtectedRunRoot -Root $base2
    Check (($run3 -ne $run2) -and (Test-Path -LiteralPath $run3)) 'locked base: a second run folder can be created'

    # junction at the base is refused and its target is not touched
    $target = Join-Path $parent 'junction-target'
    $null = New-Item -ItemType Directory -Path $target -Force
    $aclBefore = (Get-Acl -LiteralPath $target).Sddl
    $junction = Join-Path $parent 'RIT-SCC-junction'
    $made = $false
    try { $null = New-Item -ItemType Junction -Path $junction -Target $target -ErrorAction Stop; $made = $true } catch { Write-Host ('SKIP: could not create a junction here: ' + $_.Exception.Message) }
    if ($made) {
        $threw = $false
        try { $null = New-SccProtectedRunRoot -Root $junction } catch { $threw = $true }
        Check $threw 'junction at the base is refused'
        Check ((Get-Acl -LiteralPath $target).Sddl -eq $aclBefore) 'junction target ACL was not modified'
        Check (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) 'nothing was created through the junction'
        (Get-Item -LiteralPath $junction -Force).Delete()
    }
    Remove-Module -Name 'RunRootSecurity.test' -Force -ErrorAction SilentlyContinue

    # ---- Part 2: real module + real trust check (needs admin and a writable C:\)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host 'SKIP: Test-ResumeMaterialsTrusted acceptance of a fresh run root needs an elevated session (real C: ancestors, Administrators owner).'
    } else {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'remove-screenconnect.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ResumeMaterialsTrusted' }, $true) | Select-Object -First 1
        if (-not $fn) { throw 'Test-ResumeMaterialsTrusted not found' }
        . ([scriptblock]::Create($fn.Extent.Text))
        Import-Module $modPath -Force -DisableNameChecking
        $realBase = 'C:\RIT-SCC-basetest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        try {
            $realRun = New-SccProtectedRunRoot -Root $realBase
            Check ((Test-ResumeMaterialsTrusted -Paths @((Join-Path $realRun 'resume.ps1'))) -eq $true) 'real: fresh run root passes Test-ResumeMaterialsTrusted'
        } finally {
            if (Test-Path -LiteralPath $realBase) { & takeown.exe /f $realBase /r /d y | Out-Null; & icacls.exe $realBase /grant 'Administrators:(OI)(CI)F' /t | Out-Null; Remove-Item -LiteralPath $realBase -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
} finally {
    Get-ChildItem -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { Write-Host ('FAILED: ' + $script:fail); exit 1 }
Write-Host 'PASS'
exit 0
