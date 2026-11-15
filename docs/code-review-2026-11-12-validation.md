# Code review fixes: validation

Date: 2026-11-15. Branch: `fix/code-review-2026-11-12`.
Implementation through commit `d8c7b67`. No push or PR was made.

## Scope

The numbered findings 1-24 in the Desktop review are implemented, along with
the progress-prompt and close-dialog timer fixes and its performance suggestions.
See CHANGELOG.md for the behavior changes. Quarantine source hashes now serve
both the identity and CSV evidence; independent destination verification remains.

## Automated results

Final results: 75 PowerShell test scripts passed, one PowerShell script skipped,
and four Python test invocations passed. The serial run's initial failures were
investigated and rerun after fixing test harness/runtime issues. The CSV records
the final result for every invocation, including those superseding initial failures:

[Per-test results](code-review-2026-11-12-test-results.csv).

Environment: Windows 11, Windows PowerShell 5.1.26100.9711, Python 3.12,
Git Bash for the packaging test, unelevated interactive desktop.

- Full GUI window: 94 assertions passed; GUI launcher: 37; GUI/batch parity: 62.
- Batch phase split: 118 assertions passed; keep selection: 52.
- Real child-process power-repair argument binding passed.
- MSI parsing, refusal outcomes, single-item reports, scanner/AV trust,
  per-user collection, persistence inventory and report sanitization passed.
- Synthetic diff scenarios and deploy-package dependency verification passed.
- Relay unittest suites: 12 and 13 tests passed.
- New quarantine regression checks one source read per file, matching evidence,
  unchanged identity format, independent verification, tampering and junction refusal.
- Parse and safety/removal/integration regressions rerun after the hash change passed.
- Repository ASCII/BOM/JSON checks and `git diff --check` passed.

The real preflight low-space success-path script requires elevation and was skipped.
The pipeline contract suite also skipped its elevated preflight-success probe.
Run-root trust acceptance against real protected C: ancestors requires elevation;
its synthetic ACL and junction cases passed. Other tests may skip platform or
destructive branches explicitly; a passing script does not establish those paths.

Harness corrections: load the extracted uninstaller's MSI parser; avoid timeout.exe
with redirected stdin; enumerate helper CIM objects correctly; exclude local agent
checkouts from fixtures; target the actual GUI stub; avoid asynchronous keep-awake
output locks; select installed Python instead of Store aliases; support PowerShell 5.1.
The preflight elevation failure was also reproduced against origin/main.

## VM acceptance still required

No live ScreenConnect/AV installation was removed, scanner downloaded/launched,
or reboot performed as part of this validation. On a disposable elevated VM check:

1. MSI-installed ScreenConnect removal exits 0; keep one instance and remove another.
2. An unverifiable/unsigned fake instance exits nonzero and is reported NOT REMOVED.
3. Accept power repair and exercise a single installed AV product.
4. Online sharing unticked/ticked, then a second run in the same window.
5. Different standard-user victim and elevating admin, plus localized Administrators.
6. Locked-file quarantine, trusted resume registration, PendingFileRenameOperations,
   and successful removal after reboot.
7. Elevated preflight low-space confirmation and real run-root trust acceptance.

Existing unrelated GUI comment edits and untracked agent/skill files were left intact
and excluded from commits.
