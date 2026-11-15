# Safety model and coding conventions

The tool must never operate as a blind "delete anything suspicious" script. These are the
rules that prevent that.

---

## Safety rules

### 1. Stage 1 runs first and cannot be skipped
Snapshot before you touch. It is also what makes the Stage 8 diff possible, so it pays
for itself twice.

> **Amcache exception in v1.7.32 candidate:** the current best-effort Amcache
> collector temporarily mounts `Amcache.hve` with `reg.exe load`; it reuses a pre-existing
> `HKLM\Amcache` mount without unloading it, and checks `reg.exe unload` status for mounts
> it owns. This is not a strictly read-only operation. A Windows owner must verify cleanup
> on both success and failure before release.

A snapshot with `CollectionComplete=false` is evidence-incomplete. Stage 8 reports
`INCOMPLETE` and exits nonzero; it must never interpret a timed-out or failed section
as an empty, clean section. Intentional limitations such as raw-only ShimCache are
`CollectionWarnings` and remain visible without falsely forcing failure.

### 2. Stage 3 is a hard approval gate
Nothing is removed without a technician seeing the finding and its evidence. **There is
no unattended removal mode, and no flag that detects and removes in one step.** This is
the single rule that separates this tool from a destructive script.

> **Guided-runner rule:** `START-HERE.bat` Step 4 runs detection automatically, but
> Step 5 still requires typed per-instance review and final confirmation. The run uses
> a fresh artifact directory; a failed detection never authorizes removal from an older
> findings file. Quarantine-never-delete, ScreenConnect-only targeting and the
> prominent red pre-removal banner all still apply.
>
> **Lab-only exception:** `sc-cleanup.ps1 -ExecuteRemoval` is a second unattended
> detect-and-remove mode: it pre-authorizes Stage 4 (every detected ScreenConnect
> instance auto-marked REMOVE, typed confirmation waived) and prints a prominent red
> banner. It is intended **only** for a disposable, snapshotted VM, still honors `-sr`,
> and must never be used on a client machine (see README "Design notes").

When Stage 4 is built, it must consume an **approved plan file** produced by Stage 3 —
the destructive code should not be reachable without that artifact existing.

### 3. Quarantine, never delete
Move to an ACL-locked quarantine folder, preserve the original path, record the SHA-256.
The path and every existing parent must pass canonical containment with no reparse
points; a source tree containing a junction/symlink is refused. After a successful
move, the quarantine ACL is applied and verified recursively on the moved payload.
Deletion is a separate, later, explicitly-invoked operation. Costs nothing, covers the
one time we are wrong.

> The AV-uninstall leftover sweep (v1.7.5) follows the same rule: after a vendor
> uninstaller finishes (or fails - observed live with ESET), remaining product
> shortcuts/folders are MOVED to `<LogDir>\av-uninstall-quarantine`, never deleted,
> and every move is logged in `av-uninstall-results.json`. `-NoLeftoverSweep`
> disables it.

### 4. Restore point + registry export before the first change
Default on. `-np` waives only a failed System Restore-point creation; a failed
registry export always blocks destructive removal. **Check System Restore is actually
enabled** — it frequently is not, and a silently-failed restore point is worse than
none.

Both entry points (`preflight.ps1` Stage 0 and `sc-cleanup.ps1` Stage 0) do this
through one shared helper, `SystemRestore.psm1`, which:

1. resolves the OS **system drive dynamically** (`SystemDrive` / `SystemRoot` /
   `windir`, then the OS-reported `Win32_OperatingSystem.SystemDrive`); `C:` is never
   assumed, no data path is used as a guess, and an unresolvable drive fails closed;
2. runs `Enable-ComputerRestore -Drive <system> -ErrorAction Stop` **before**
   `Checkpoint-Computer`. Enablement is ensured idempotently — the cmdlet is a no-op
   on an already-enabled volume — because an empty restore-point list is **not**
   proof that System Restore is off (no points may simply mean none were kept). When
   no reliable enabled/disabled probe exists, the helper still enables;
3. runs `Checkpoint-Computer -RestorePointType MODIFY_SETTINGS -ErrorAction Stop`;
4. **reads the restore-point list back** and only reports `Created` when a new
   sequence number appeared **that carries this run's description**, so a restore
   point written concurrently by something else is never adopted as the rollback
   point. An unreadable baseline list is not treated as empty: the step fails closed
   before any restore API call. A non-throwing `Checkpoint-Computer` proves nothing:
   Windows silently declines a checkpoint inside the restore-point frequency window
   (default 24 h) and emits only a warning. That case is reported as
   `SKIPPED (throttled)` with the newest existing point, and is recorded in
   `master.log` as such — never as `Restore point: Created`;
5. refuses before any restore call when the host cannot support the step: Windows
   Server SKU (`UnsupportedServer`), an unelevated session (`NotElevated`), or a
   System Restore policy that disables it (`PolicyBlocked`, read-only - policy is
   never written or overridden);
6. reports enable failures, creation errors and missing cmdlets
   (`Enable-ComputerRestore` / `Checkpoint-Computer`) truthfully, with the `Status`
   that failed.

`RestorePointFailed` stays the fail-closed gate. A verified `Created` point permits
continuation. `Throttled` also permits continuation only when the readable list
confirms an existing point with a positive sequence number and a known creation
time less than 24 hours old (never future-dated). This is logged as
`SKIPPED (throttled)`, not `Created`; no frequency setting is changed. Missing,
stale, unknown-time or unreadable points, enable failures, unavailable cmdlets,
and unsupported hosts still block destructive Stage 4 unless the operator passed
`-np`. The shared result's `CanContinue` carries this gate decision separately
from `Success`, which remains false for a skipped creation. The helper deliberately makes
**no** Group Policy change, **no** quota or retention change (`DiskPercent`,
`MaxSize`), and **no** service or checkpoint-frequency change; those are machine
policy the operator did not ask for.

### 5. Uninstall before surgery
Always run the vendor's own uninstaller (from the registry `UninstallString` /
`QuietUninstallString`, or `msiexec /x {ProductCode} /qn`) before touching services or
directories manually. Manual removal is the fallback, not the default.

### 6. Do not clean temp before you look at it
The scammer's installer in `%TEMP%` is often the best provenance evidence on the machine.
There is no temp-cleanup stage, deliberately. Do not add one.

### 7. Do not clear event logs
Event ID 7045 survives uninstall and is one of the best sources available.

### 8. Server OS refuses by default
Detect the OS role in preflight and refuse unless `-force`.

### 9. Scanner failure is non-fatal AND reported as failure
Never silently swallowed into a "clean" verdict. A skipped or failed scanner must appear
as such in the report.

### 10. The report must say what it did NOT check
If `-sa` skipped the scanners, the report says "scanners skipped" — never "no malware
found."

### 11. Verification re-collects
Post-remediation verification must read the system fresh (ideally after reboot), not
consult the actor's own record of what it thinks it did.

### 12. Removal is not remediation
If a scammer had an interactive session, the exposure is credentials, browser session
cookies, saved passwords, mail-forwarding rules, and new accounts. The report must end
with a **credential-reset checklist**. Stage 1 already collects most of what it needs.
This is a report section, not a module — keep it proportionate, but do not omit it.

### 13. Automatic report share is minimized, and it is a paste, not a vault

What the code does (`Submit-ConnectWiseReport.ps1`): the only share path is a post to the
MicroBin paste server named by `-MicroBinUrl` or `microbin-url.txt` beside the script. With no
URL configured nothing is sent and the uploader prints `MICROBIN UPLOAD: skipped; ...`. With
`-NoUpload` (the offline half, or the share tick box unticked) nothing is sent either.

- **What is sent:** only the sanitized report JSON, as the paste text. The ZIP, the HTML
  report and raw evidence stay on the PC. The shared copy is built separately: the computer
  name and run id are replaced by an anonymous PC id, and local network addresses and ports are
  left out (the local package also omits the local address and keeps only the local port). Raw config contents,
  parameter blobs, account names, credentials, tokens, passwords, private keys and connection
  strings are excluded; user-profile paths are normalized wherever they appear in a string
  (`X:\Users\name`, `Documents and Settings`, `Windows.old\Users`, UNC and forward-slash forms).
- **Transport:** HTTPS is required (`-AllowInsecureRelay` exists for local tests only).
- **Authentication is optional:** an uploader password is sent only when one is configured
  (`-MicroBinUploaderPasswordFile` or `SCREENCONNECT_MICROBIN_UPLOADER_PASSWORD`). Without one
  the upload is still attempted; it does not fail closed. Whether the server demands a
  password is a server setting this repository does not control.
- **Not encrypted by the client:** the paste is plain text on the server. It is created with
  `privacy=readonly` and `expiration=1week`; readonly is unlisted and not editable, and on a
  server that does not enable readonly it degrades to an unlisted paste. **Anyone who has the
  paste URL can read it**, so treat the link as the secret.
- **Failure:** an upload failure is loud (`MICROBIN UPLOAD FAILED`, nonzero exit) and leaves
  the local report and package in place. There is no silent retry and no fallback target.

ConnectWise submission remains an operator-reviewed action through its official reporting
workflow unless a documented official API is verified.

The `relay/` folder holds an older authenticated ZIP relay that encrypts at rest. The current
client does not post to it; see `relay/README.md`. The live server was not checked when this
rule was rewritten (2026-11-15).

---

## Optional power-options repair (scripts only)

`START-HERE.bat` offers a default-No repair before the after snapshot. The CLI
requires `-RepairPowerOptions`; `-ResetLocalGpo` is a separate opt-in and
`-AllowManagedDevice` is a separate authorization override. Both require the
repair switch. These options do not enable the WPF cleanup workflow.

The repair requires 64-bit administrator PowerShell on a Windows client edition.
Server editions are refused, even if the main runner uses `-force`. Domain/MDM
managed devices and unknown management state are refused unless explicitly
allowed. Ask the policy administrator first: local edits cannot remove enforcing
GPO, MDM, scheduled-task or other persistence.

Affected registry keys are exported before editing. Power schemes and shutdown
rights are backed up before changing them. Local GPO folders are not cleared
unless separately requested and their backup verifies. This is not a replacement
for a recoverable system backup. Custom power plans can be replaced, hibernation
can allocate disk space, and power/sleep-button and lid actions are set to Sleep
for AC and DC. Explorer is refreshed; save work first.

A local `power-options-repair.json` records action outcomes and backup locations.
`Completed` reports command outcomes, not proof that malware/persistence is gone
or that the power menu is usable. Failures stay visible; optional repair evidence
is included in the local HTML report, not added to the automatic sanitized share.

The repair helper never reboots. A runner may offer a separate default-No reboot
only after current-run repair evidence exists and the report successfully opens.
Explicit consent invokes CMD `shutdown /r /t 0 /f`: **forced app closure can lose
unsaved work**. Declining or closing the prompt never authorizes restart. Physical
power-off is not a safe substitute for a Windows shutdown.

## Coding conventions

### PowerShell 5.1 compatible — mandatory

The tool runs on client machines as-found. Windows PowerShell 5.1 is the baseline.

**Forbidden (PowerShell 7 only):**
- ternary `? :`
- null-coalescing `??`, null-conditional `?.`
- `&&` / `||` pipeline chain operators
- `ConvertFrom-Json -AsHashtable`

**Known PS 5.1 traps that have already caused real bugs here:**

- **Single-element arrays are unwrapped.** `.Count` on a one-item result returns `$null`,
  not `1`. Always force array context: `@($x).Count`. This produced a silent
  wrong-answer bug in the detector — see `04`.
- **`powershell.exe -File` does not parse arrays.** `-Target a,b` arrives as one string.
  Split defensively inside the script.
- **`ConvertFrom-Json` returns PSCustomObject**, not a hashtable.
- **`-replace` inside a hashtable literal** needs parentheses, or the comma before the
  replacement is parsed as a hashtable separator. This caused a parse error here.
- **`$matches` is an automatic variable.** Never use it as your own variable name.

### Pure ASCII, no BOM — mandatory

PowerShell 5.1 reads a BOM-less non-ASCII file as Windows-1252. No emoji, no smart
quotes, no box-drawing characters, no accented characters in any `.ps1`. Same rule as
`provisioning/` in this repo.

(Output *files* the scripts write may be UTF-8. The rule is about the source.)

### Verification — run it, do not reason about it

Every `.ps1` must pass both checks before being called done:

```powershell
$p='.\detect-remote-access.ps1'; $e=$null; $t=$null
[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e) | Out-Null
if ($e.Count -eq 0) { 'PARSE OK' } else { $e | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } }
```

```
py -c "import io;b=io.open('detect-remote-access.ps1','rb').read();print(sum(1 for c in b if c>127))"
```

The second must print `0`.

**Both bugs found in the detector parse cleanly and look correct on inspection.** Passing
the parse check is necessary, not sufficient — the script must actually be executed.

### Other conventions

- `.bat` launcher alongside each `.ps1`, with CRLF line endings, matching
  `remote-diagnostics/`. Pattern:
  `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0<script>.ps1" %*`
- Output folder per run, zipped to the Desktop.
- Read-only scripts must be genuinely read-only: no `Set-`, `Stop-`, `Remove-`, `Start-`
  against system state.
- Every collector section wrapped so a failure is recorded and collection continues. One
  inaccessible section must never abort a run.
- Standalone-capable: a single copied `.ps1` must work with no other files present
  (decision D6). Embed defaults; treat config files as optional overrides.

### A note on writing these files with tooling

Bash heredocs in this environment **collapse double backslashes**, which corrupts Windows
paths and JSON escaping. Write `.ps1` and `.json` files with a dedicated file-writing
tool, or generate them via Python. This bit twice during the build.
