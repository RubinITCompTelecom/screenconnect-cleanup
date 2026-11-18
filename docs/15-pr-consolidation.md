# PR consolidation - 2026-11-18

The shipped PowerShell GUI (`gui/`) is the maintained frontend. Existing release
tags and assets remain unchanged. The published beta is not evidence of live
removal or reboot acceptance.

## Integration and dispositions

| PR | Disposition | Evidence and retained work |
| --- | --- | --- |
| #39 | Integrate released beta.1 | The five commits from main to `f323d3bc584d7079e50d39e81b21c73775ea0e62`, unchanged. Includes selection checkboxes, Offline KVRT only, continuation cancellation and fresh Online evidence/report folders. |
| #28 | Close as already incorporated | `git cherry origin/main origin/perf/legacy-review-185` marks every branch commit patch-equivalent, including `3e64459`. Its runtime changes match `d43aed1` in main. Progress, overlap, review evidence, after-snapshot failure, escaping and JSON shape regressions remain in CI. |
| #32 | Supersede with the current-base safety follow-up | Port explicit quarantine outcomes and verified deferred metadata cleanup, guided diff propagation/failure exits, immutable clean-ref packaging, conservative report metadata and relative output. Keep current HKU/Registry prefix handling and GUI package layout. Threat-shape normalization was already present; retain its regression. |
| #15 | Archive alternative module rebuild | Keep branch head `14d283fbb4629c445bda6579ab056dba4125f9ad` and its source/tests/audits. Do not merge the competing frontend into the shipped GUI. |
| #25 | Archive alternative .NET WPF prototype | Keep branch head `0576b552df2487e1147a4d1c2edcead9f4935400` and its source/specs/tests. Do not replace the working shipped frontend with the incomplete protected-execution prototype. |

PRs are in https://github.com/pupontech/screenconnect-cleanup/pulls.
Archived branches are retained; no source, branch or release is deleted.

## Useful alternative-branch material retained for later work

These are references for deliberate future changes, not claims that all code
from the alternatives has been incorporated or reviewed as suitable to ship.

- #15: the parameter-blob/relay model, modular detection/evidence/remediation
  seams, quarantine restoration and module tests. Consult
  `gui-revision-screenconnect-cleaner/audit/INDEPENDENT-AUDIT.md` at its retained
  head before reuse: it records fail-open detection queries, a missing GUI
  execution gate, relay name-only trust and other limitations.
- #25: `docs/GUI-CONTRACT.md`, `docs/GUI-ARCHITECTURE-AUDIT.md`,
  `docs/GUI-PROTECTED-INSTALL-STORE-NEXT-SLICE.md`, the fail-closed readers and
  atomic pipeline-state tests. Its protected installation/elevated approval
  design is unfinished. A separate security design and acceptance pass is
  required before porting any execution boundary.
- The existing SYSTEM resume task retry/expiry policy remains a deferred issue
  from `docs/13-legacy-code-review.md`; consolidation does not certify it.

## Automated validation

Local checks use Windows PowerShell 5.1 and harmless synthetic fixtures.
The ported quarantine-loop test stubs native delayed moves, service/registry
operations, task registration and vendor processes. Report tests use synthetic
JSON and temporary HTML. The bundle tests create isolated Git repositories.

Before porting, the quarantine-loop, invalid diff metadata and bare report-path
tests failed against the released source. They pass after porting. The legacy
guided test was adapted to the current optional power-repair block, three report
invocations and GUI package layout. Both batch and GUI reports now receive the
same original snapshot comparison, including Online continuation.

New regressions run in hosted Windows 2022/2025 CI under PowerShell 5.1 and
PowerShell 7, including extracted-package tests. Local live-window and phase
split harnesses use stubbed engines; they cannot prove real removal.

## Disposable-lab acceptance still required

Use a fresh VM snapshot with an explicitly authorized test ScreenConnect
installation. Follow `docs/09-windows-live-test-matrix.md`, replacing its
historical version reference with the exact candidate commit and package hash.
Do not exercise destructive acceptance on the workstation used for development.

1. Launch the complete extracted package from a folder with spaces and
   parentheses. Verify elevation and the exact displayed version.
2. Run Offline with keep/remove choices. Confirm unselected instances remain,
   only typed REMOVE authorizes changes, and quarantine/registry backups match
   the selected instance. Exercise refusal and cancelled elevation.
3. Exercise a locked payload and reboot. Before reboot, verify deferred status
   and retained metadata/persistence. After reboot, verify source absence,
   destination identity/ACLs, metadata cleanup and resume-task completion.
   Failed verification must prevent further cleanup.
4. Continue Online twice. Verify distinct locked attempt folders, unchanged
   Offline/earlier evidence, current scanner/persistence results and current
   combined report. With sharing unticked, verify no upload. Inject a report
   failure and confirm no stale report is uploaded.
5. Run real staged KVRT Offline, then selected ESET/Malwarebytes Online; verify
   skip/failure/success reports against vendor output. Exercise Stop/Pause only
   on the tool's own collectors, as designed.
6. Include a standard-user/elevated-user split, redirected AppData and a
   localized Windows profile. Retain logs, manifest, report, package SHA and
   VM snapshot identity with each result.

No live elevated removal, reboot, vendor scan or scanner installation is claimed
by this consolidation.
