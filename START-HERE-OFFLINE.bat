@echo off
rem ============================================================================
rem  START-HERE-OFFLINE.bat - HALF 1 of 2: cleanup that needs NO internet.
rem  Runs: preflight, before snapshot, detection, ScreenConnect removal (typed
rem  confirmation), optional staged KVRT/ESET, persistence review, after snapshot
rem  + diff, local report. Does NOT stage downloads, install Malwarebytes,
rem  uninstall AV, or upload the report. Scanner UIs may still need internet.
rem  Afterwards, when the PC is online again, run START-HERE-ONLINE.bat.
rem  Pure ASCII, no BOM. Self-elevates (inside START-HERE.bat).
rem ============================================================================
set "SCC_W_DP0=%~dp0"
call "%SCC_W_DP0%START-HERE.bat" --offline
exit /b %errorlevel%
