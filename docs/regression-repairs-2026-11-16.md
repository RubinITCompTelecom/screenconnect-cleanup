# Regression repairs and validation - 2026-11-16

Historical repaired-source validation. See [GUI alpha.6 integration](gui-alpha-6-validation.md)
for the later merge and requested scan controls.

Branch: `fix/code-review-2026-11-12`. Runtime repairs through `d7845e3`;
final test/CI adjustments through `7c5ef73`.
This follow-up repairs the seven findings against `d2921f3`; the earlier
code-review validation describes the state before this regression audit.

## Repairs

| Finding | Resulting behavior | Permanent regression coverage |
|---|---|---|
| R1: per-user Run identity | Successful deletions record the actual SID. Diff matching preserves hive and SID. Ambiguous legacy HKCU manifests yield INCOMPLETE; another user's value cannot satisfy a target. | `test_clean_persistence.ps1`, `test_diff_registry_identity.ps1`, `test_diff_synthetic.py` |
| R2: user uninstall handoff | Detector user-hive paths are accepted only under loaded real-user SID uninstall roots; fallback search includes those hives. Existing product/path checks remain. | `test_user_uninstall_handoff.ps1`, `test_per_user_state.ps1` |
| R3: redirected AppData | Loaded profiles use raw User Shell Folders values, resolving USERPROFILE for that user. The current account retains its actual AppData environment paths. | `test_current_profile_redirection.ps1`, `test_per_user_state.ps1` |
| R4: scanner report evidence | Batch and GUI persist all three outcomes. Completed, declined, unstaged and failed launches stay distinct even when Malwarebytes is declined. Reports accept legacy raw Tool/ProcessExitCode fields. | `test_scanner_summary_contract.ps1`, `Test-GuiScannerSummary.ps1`, GUI/batch parity and window suites |
| R5: unfamiliar prompts | Quiet punctuation-free prompts retain the generic input fallback. Recognized snapshot/percentage progress stays quiet. | `Test-GuiUnknownPrompt.ps1`, real child-process `Test-GuiPromptHandling.ps1` |
| R6: numeric precision | Integral/decimal pairs compare exactly; mixed floating/exact values retain serialized precision. | `test_diff_registry_identity.ps1`, synthetic diff suite |
| R7: omitted CI tests | Both CI shells invoke the twelve omitted review regressions and seven new repair tests. Atomic protected-directory creation uses the appropriate Framework/Core ACL API. | `test_ci_review_regressions.ps1`, `Test-RunRootBaseLock.ps1` |

The scanner state test exercises the GUI's real missing-prerequisite path:
an unstaged scanner is a Warn result with no child exit code, not exit zero.
The native console fixture establishes its visible initial state before probing
continue/cancel and the intentionally hidden negative control. Only the successful
watchdog fixture receives a larger startup allowance; timeout/failure budgets stay
short. These correct the test problems found in the earlier full run.
The real-child dismissal test now waits for the first prompt before measuring
its five-second suppression window; child startup is measured separately. Its
initial full-run failure is retained in the raw results, with the corrected
fixture's isolated result recorded separately.

## Automated validation

Final result: 164 commands completed successfully and two were wholly skipped
for lack of elevation. Five successful commands skipped individual assertions.
The matrix covered every expected invocation: 166 distinct commands, plus three
focused reruns. No unresolved failures or outer-runner timeouts remain.

| Group | Pass | Pass with skipped assertions | Wholly skipped | Unresolved failures |
|---|---:|---:|---:|---:|
| PowerShell 5.1: 83 scripts + 3 CLI smokes | 82 | 3 | 1 | 0 |
| PowerShell 7.7: 73 scripts + 3 CLI smokes | 73 | 2 | 1 | 0 |
| Python 3.12: diff, packaging, two relay suites | 4 | 0 | 0 | 0 |

[Per-command final results](regression-repairs-2026-11-16-test-results.csv).

Environment: unelevated Windows 11 Pro, Windows PowerShell 5.1.26100.9818,
portable official PowerShell 7.7.0, Python 3.12 and Git Bash. The portable host's
release digest was verified during the earlier run; installed shells were unchanged.
The serial matrix ran from 15:20 to 16:28 local time, with focused fixture reruns
captured separately. GUI runtime code was finalized before its acceptance suites.

The 5.1 GUI/window target passed: 94 window assertions, 62 GUI/batch parity
assertions, 57 real-child prompt assertions after its fixture correction, 52 keep
selection assertions and 118 batch phase-split assertions. All seven repair
regression scripts and the twelve previously omitted review tests passed in both
CI shells. The Core matrix excludes the eight existing GUI suites and two manual
batch/UI harnesses whose documented target is Windows PowerShell 5.1; the two new
pure GUI state tests run in both editions. This is not a Core WPF support claim.

Two initial fixture failures were corrected and rerun, with raw outcomes retained:

- The 5.1 prompt-dismissal test began timing before the child emitted its first
  prompt. Waiting for that prompt, then observing the same five-second suppression
  interval, passed all 57 assertions. Production prompt code was unchanged.
- Core's language cast from string to decimal rounded both decimal test constants
  to 1 before comparison. Invariant Decimal.Parse constructs distinct exact values;
  the registry/precision test then passed again under both engines. Production
  comparison code was unchanged. The independent conversion probe is retained.

Both editions wholly skipped the elevated preflight test. Individual skipped
assertions cover elevated preflight success, real protected C: ancestor trust,
and the 5.1 persistence symlink fixture. The hosted Windows CI workflow was not
executed remotely; its expanded lists were checked locally and its timeout is
60 minutes to allow both shells and packaged fixture coverage.

Raw records and logs:

- [Initial matrix records](C:/Users/Admin/AppData/Local/Temp/scc-repaired-tests-20261116-152054/results.jsonl)
- [Focused reruns](C:/Users/Admin/AppData/Local/Temp/scc-repaired-tests-20261116-152054/recheck-results.jsonl)
- [Summary and skipped assertions](C:/Users/Admin/AppData/Local/Temp/scc-repaired-tests-20261116-152054/summary.json)


## Remaining live acceptance

This workstation is unelevated and has no available disposable VM runner. No
production client/AV was removed, vendor scanner launched, or reboot performed.
Before field deployment, use a disposable elevated Windows VM to exercise:

1. Real MSI removal, keep/remove selection, refusal outcomes, installed AV removal.
2. Locked files, trusted resume registration, delayed moves and completion after reboot.
3. KVRT/ESET/Malwarebytes staging, real signatures, attended sessions and report outcomes.
4. Real standard-user victim plus different elevating admin, redirected AppData and localized Windows.
5. Elevated preflight, protected C: ancestors, physical battery/UAC behavior.
6. Offline/online sharing choices and repeated runs in the same window.

The automated GUI/window tests use harmless engine stubs. They verify UI/workflow
contracts, not live removal or vendor scanner behavior. Windows 10 and the hosted
Windows Server 2022/2025 CI matrix have not been executed locally.

## Package and workspace

The replacement ZIP is a test bundle. It is built from a Git archive of the final
commit, then checked for CRC integrity, complete SHA-256 manifest coverage, exact
committed payload bytes and source-commit provenance. Vendor EXE/DLL binaries are
excluded. Unrelated user GUI comments and untracked agent/skill files are preserved
and excluded from the bundle. No push, PR or deployment is part of this task.
