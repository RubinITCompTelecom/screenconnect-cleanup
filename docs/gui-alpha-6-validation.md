# GUI alpha.6 integration and validation - 2026-11-16

Version: `1.8.12-gui-alpha.6`. Runtime source validated at `1890512`.

## Included changes

The integration merges the repaired cleanup branch (`a9e2e5c`) and the GUI
cleanup-first branch (`34d2a86`) into a common GUI alpha. The GUI title/header
identify this build as ALPHA. Existing version tags and release assets are kept.

When Online has no offline run to continue, the window offers cleanup first or
scanners only; closing that question starts nothing. Both creation of the full
session and the full-run report call retain the share checkbox. Unticked sharing
passes `-NoUpload`, including Stage then Online. This closes the sharing
interaction exposed by the initial merge validation.

The tool's snapshots, remote-access detection, persistence inventory and snapshot
diff offer these controls:

- **Stop scan** asks for confirmation, terminates only the owned tool-scan
  process tree, records Cancelled/nonzero status, and stops the run before later
  steps. Interrupted evidence is kept and may be incomplete.
- **Pause after scan** lets the current step finish and then waits for Resume.
  The current collector keeps running; its watchdogs are not suspended. The pause
  request can be cleared while it is running. Resume advances once.
- Approved cleanup/removal, AV installation/uninstallation, and external vendor
  scanner processes are excluded. Stopping between steps preserves completed
  scan results. Closing the stop confirmation keeps the scan running.

## Validation

All 11 integration commands passed, with no skipped commands:

- Parse all scripts under Windows PowerShell 5.1 and PowerShell 7.7; house rules.
- GUI questions/arguments, launcher, package layout, prompt contract, scanner
  summaries and unknown-prompt fallback.
- Full WPF window: **106 assertions passed**, including cleanup-first order,
  Stage then Online, refusal, sharing choices and the existing offline flows.
- Scan controls: **22 behavior assertions passed** using the actual WPF buttons,
  their source click bindings, and harmless child/worker heartbeat processes.
  Cancellation ended the owned tree, left an unrelated process untouched, blocked
  later steps and success status, respected cleanup locks, and preserved completed
  evidence when stopped at a pause boundary.

[Integration command results](gui-alpha-6-test-results.csv).

The earlier repaired source passed 164 distinct automated matrix commands with
two elevation-only skips and documented partial skips. See
[the baseline validation](regression-repairs-2026-11-16.md). The ten engine/launcher
files listed in the verification script were byte-unchanged in Git from that
tested source; integration changes are in the GUI, its catalog, tests, version and
documentation. This integration run targets those changed boundaries rather than
claiming another full engine matrix execution. Raw local logs are retained under
`%TEMP%/scc-alpha-final-tests-20261116-172222`.

The initial window run exposed the unticked-sharing failure in cleanup-first
mode. Its raw log remains under `%TEMP%/scc-alpha-integration-tests-20261116-165839`.
The final fresh run above includes the corrected session state and report args.

Hosted CI subsequently exposed a quarantine test-path mismatch. The independent
expected identity now normalizes the fixture root before deriving relative paths,
matching the identity format contract. The failure was reproduced locally with
a TEMP path containing a dot segment, then verified fixed in both shells under
normal and dot-segment TEMP paths. Production hashing code is unchanged.

The next hosted run reached the final GUI/batch parity suite. Its shared harness
also retained noncanonical TEMP roots while discovered findings paths were
canonical, producing false trace differences and a false handoff mismatch. The
harness now normalizes all three fixture roots. The parity suite deliberately
uses a dot-segment TEMP path to retain this boundary coverage. Runtime code is
unchanged by these hosted-CI fixture corrections.
The corrected local parity run passed all 62 assertions, including offline-run
handoff and the tool folder containing spaces and parentheses.

## Backup and publication

Before merging, the repository's complete refs were saved in a verified Git
bundle; the current workspace, including untracked files and uncommitted GUI
comments, was saved in a CRC-checked ZIP. A binary working-change patch and ref
inventory are retained. Both published releases' four assets were also downloaded
and checked against GitHub's SHA-256 digests. Four remote backup branches live
under `backup/pre-alpha-20261116-165247/`.

Alpha.6 is a separate GitHub prerelease with `make_latest=false`. The publication
verification compares all 88 existing release records/assets and the Latest
release ID against the saved inventory. The stable installer continues to use
GitHub Latest, which was `v1.8.12-gui-beta.2` at backup time.

The alpha ZIP is built from a Git archive of its source commit, with exact payload
bytes, CRC, version, source SHA and complete SHA-256 manifest checks. No vendor
EXE/DLL binaries or uncommitted workspace comments are packaged.

## Remaining acceptance

This is an alpha test build. GUI flows use stubbed engines, and control fixtures
use harmless owned processes. No live removal, vendor scanner, AV uninstall or
reboot was performed. Elevated disposable-VM acceptance, real multi-user and
folder-redirection coverage, physical battery/UAC behavior, localized Windows and
Windows 10 remain outstanding. Hosted Windows CI is triggered separately by the
main-branch update; these local results are not a claim that hosted CI passed.
