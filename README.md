# ScreenConnect Cleanup

> Designed by [pupontech](https://github.com/pupontech) in collaboration with Rubin IT. A read-only mirror of this repository is kept at [RubinITCompTelecom/screenconnect-cleanup](https://github.com/RubinITCompTelecom/screenconnect-cleanup). Make changes in [pupontech/screenconnect-cleanup](https://github.com/pupontech/screenconnect-cleanup).

**BETA: 1.8.13-beta.2.** Download the [Latest beta release](https://github.com/pupontech/screenconnect-cleanup/releases/tag/v1.8.13-beta.2).
Includes the end-to-end review fixes, the reviewed cleanup repairs, persistence selection checkboxes, staged KVRT in Offline mode,
clear Online continuation choices and preserved Online attempts. Live elevated Windows acceptance
is still required. Existing releases remain available; the installer command below downloads GitHub's Latest release.

> **Microsoft Defender may flag this tool. It is a false positive.** The tool does what malware
> removers do: it finds and removes a remote-access program, moves files to quarantine, runs
> PowerShell scripts, and downloads antivirus scanners. Defender's behaviour checks can mistake that
> for an attack. The 1.8.13-beta.2 release zip scans clean on
> [VirusTotal: 0 of 65 engines, Microsoft included](https://www.virustotal.com/gui/file/55143747409e65d201d2a09e90b2a19a6b66ba729a0f79532ae86b6a73395355)
> (scanned November 25, 2026). SHA-256 of `screenconnect-cleanup-v1.8.13-beta.2.zip`:
> `55143747409e65d201d2a09e90b2a19a6b66ba729a0f79532ae86b6a73395355`.
>
> **If Defender blocks it:** first check the zip's hash matches the one above
> (`Get-FileHash .\screenconnect-cleanup-v1.8.13-beta.2.zip`). If it matches, open
> **Windows Security > Virus & threat protection > Protection history**, pick the item and choose
> **Allow on device** (or **Restore**). Do not turn Defender off. Please also report the false positive to
> Microsoft at <https://www.microsoft.com/wdsi/filesubmission> so it stops being flagged.

A Windows technician tool for PCs where a scammer got remote access through ScreenConnect. It usually
gets there from an **invite email the user clicked** (a fake invoice, meeting or "document shared with
you"), which installs ScreenConnect connected to the scammer's server.

**Antivirus will not catch it.** ScreenConnect is a legitimate, signed program that IT companies use
every day, so no AV treats it as a virus. This tool finds every ScreenConnect instance, shows **which
relay server each one calls home to** (the only reliable way to tell the scammer's copy from the
customer's own IT), removes the ones you choose, checks what else was left behind to start up with
Windows, runs the AV scanners for any other malware, and writes a report.

---

```powershell
irm https://raw.githubusercontent.com/pupontech/screenconnect-cleanup/main/install-latest.ps1 | iex
```

Read [`install-latest.ps1`](install-latest.ps1) first if you prefer; it only downloads, verifies,
extracts and launches. Running it again with the same version just opens the existing copy.

**Needs:** Windows 10 or 11, an administrator account (the launcher asks once through UAC), PowerShell
5.1 (built in). Internet only for the Online half and Stage tools.

---

## Using the window

Double-click `START-HERE-GUI.bat`, approve the administrator prompt, pick what to run and press Start.

![Start screen: choose Offline, Online, Detect only or Stage tools](docs/images/gui-start.png)

| Choice | Internet | What it does |
|---|---|---|
| **Offline** | not needed | Preflight, before snapshot, detection, removal of the ScreenConnect you choose, optional staged KVRT scan, persistence review, optional power-options repair, after snapshot + diff, local report. Missing KVRT is skipped. ESET and Malwarebytes run in Online mode. Downloads and uploads nothing. |
| **Online** | needed | Downloads and runs KVRT, ESET Online Scanner and Malwarebytes, checks startup items again after the scans, optional AV uninstall, shares the report if the box is ticked. Continues this PC's last Offline run if there is one; otherwise offers cleanup first or scanners only. |
| **Detect only** | not needed | Preflight, snapshot, detection and the report. Changes nothing. Use it to look before you decide. |
| **Stage tools** | needed | Downloads the scanners into the tool folder for later. Changes nothing on the PC. |

The left column shows every step and its state (done, skipped and why, failed). The console at the
bottom shows the scripts' own output live. **Open log** opens the full log; **Open RIT-SCC folder**
(top right) opens `C:\RIT-SCC`, where every run is kept.

During this tool's snapshots, remote-access detection and persistence inventory, **Stop scan** cancels
the tool scan and ends the run before later steps. Evidence is kept and the interrupted scan is marked
cancelled. **Pause after scan** lets the current scan finish, then waits for **Resume** before the next
step. These controls are unavailable once cleanup is approved. The external antivirus programs keep
their own controls.

When it finishes you see each ScreenConnect instance as a card. The relay host is the line that
matters: a host you do not recognise is the scammer's.

![Finished run: one card per ScreenConnect instance, relay host first](docs/images/gui-results.png)

### First: is ScreenConnect in the tray?

Before you plug anything into the PC, look at the notification area next to the clock (click **^** to
see the hidden icons). The ScreenConnect client shows a teal icon of two overlapping windows; hover it
and the tooltip reads *ScreenConnect Client*. While someone is connected you may also see a
"Connected" notification and a banner at the top of the screen saying *Your computer is being
controlled by ...*.

![ScreenConnect client icon in the Windows tray (teal, two overlapping windows)](docs/images/screenconnect-tray-icon.png)

![ScreenConnect Client "Connected" notification above the tray icon](docs/images/screenconnect-connected-notification.png)

![Banner shown on the PC during a session: "Your computer is being controlled by ..."](docs/images/screenconnect-banner.png)

<sub>Screenshots: ScreenConnect's own blog, [ScreenConnect Customizations: What's Different and Why](https://www.screenconnect.com/blog/customization-update) (August 2025). Older versions and custom-branded copies can look different; scammers have also been seen renaming the icon to look like Defender or another app, so no icon does not prove it is clean.</sub>

**If you see it, assume the scammer can still get in, and:**

1. **Stage on a separate, clean computer**, not on this PC: run **Stage tools** (or
   `START-HERE.bat --stage`) on your own PC, then copy the whole folder to a USB stick. Do not go online
   on the infected PC to download anything.
2. **Take the infected PC off the network** (unplug the cable, turn Wi-Fi off) before you plug the stick in.
3. **Run Offline first.** Only reconnect and run **Online** once the Offline run has removed
   ScreenConnect.

### The usual job

1. **Take the PC off the network** (unplug the cable, turn Wi-Fi off) if a session might still be live.
   If ScreenConnect is in the tray, stage the tools on a separate computer first (see above).
2. Run **Offline**. For each ScreenConnect instance choose **Remove** (the default) or **Keep** (for
   example the customer's own support agent). Type `REMOVE` to confirm; the button stays disabled
   until you do.

   ![Removal confirmation: lists REMOVE and KEEP per instance, needs REMOVE typed](docs/images/gui-confirm-remove.png)

3. When asked to open the review windows, say **Yes** and go through them (see below).
4. Read the report. It opens by itself and a copy is left on the Desktop.
5. **Reconnect** and run **Online**. Say yes to continuing the offline run; run the scanners you want.
   If *Share the sanitized report* is ticked (it is by default), the report is shared at the end and the
   link appears in the window and in the report. Untick it and nothing is uploaded.

A PC that must stay offline: run only **Offline**. Everything stays in `C:\RIT-SCC\<PC>-<id>\` and
nothing is shared.

### The review windows: go through them

Removing ScreenConnect is not always the end of it. Once a scammer is on a PC they often leave a way
back in: a scheduled task, a service, a Run key or a file in a startup folder that reinstalls the
remote tool or runs something else at every boot. The tool scans for these, but its matches are
guesses, and the most dangerous kinds (**services, WMI subscriptions, hidden tasks, Winlogon
settings**) are only reported, never removed automatically, because removing the wrong one can break
Windows. That part needs a person.

So near the end of the Offline run the tool offers to open, side by side:

- **Services** and **Task Scheduler**
- the scheduled-task folder on disk and every **startup folder** it looked at
- the run's evidence folder (with the exported task definitions) and the quarantine folder

It also prints a list of everything it flagged: what it is, the command it runs, why it was flagged,
where to find it, and whether it is review-only. Opening the windows changes nothing.

**What to look for:** anything installed or created around the time of the incident, anything that
runs from a user's `AppData` or `Temp` folder, another remote-access tool (AnyDesk, TeamViewer,
RustDesk...), or a name you do not recognise. Compare with the flagged list. Startup items the tool can
remove are removed only when you select them and type `REMOVE`; services and the rest you deal with
by hand.

---

## What you get

Every run has its own folder, `C:\RIT-SCC\<PC>-<id>\` (locked to administrators, so nothing running as
the user can tamper with it between the two halves):

| File / folder | What it is |
|---|---|
| `report.html` | The investigation report (also copied to the Desktop). Instances, relay hosts, install dates, startup items found, before/after diff, scanner results, a credential-reset checklist. |
| `report-after-scans.html` | Online half: the report rebuilt after the scanners. This is the one that is shared. |
| `connectwise-report.zip` | Sanitized package (report JSON, technician summary, manifest) for the ConnectWise Trust Center. **Never sent automatically.** |
| `quarantine\...`, `removal-manifest.json` | Everything removed, **moved here, never deleted**, with original path and hash. |
| `detect\`, snapshots, `logs\` | Raw evidence, before/after snapshots and every step's log. |

**Sharing (your choice).** The Online choice has a tick box, *Share the sanitized report*, ticked by
default. Ticked: the report is posted to the MicroBin server in `files\microbin-url.txt` (read-only,
deleted after one week) and the link goes at the top of the report. Unticked: nothing is uploaded and
everything stays on this PC. The Offline half and Detect only never upload anything.

**What is shared:** ScreenConnect relay hosts, instance IDs and thumbprints, file names and hashes,
install dates and an anonymous PC ID (a short hash, not the computer name). **Nothing personal is
sent:** no computer name, user or account names, network address of the PC, raw config, evidence,
credentials or keys, and user folder names are replaced by `<USERPROFILE>`. The copy on this PC
(`connectwise-report.zip` and `report.html`) keeps the full details.

**Sharing is not a report to ConnectWise.** It gives your team one link with what ConnectWise needs (the
relay host and instance ID) to shut down the scammer's server; you file that report yourself.

---

## Why relay host, and what it does not do

Signature, publisher and file hash are the same whether ScreenConnect belongs to the customer's IT or
to the scammer. What differs is the
**relay server** each instance is configured to call, so the tool reads that from every instance and
puts it first.

- **The scanners are for the other malware** that came along. They do not replace the ScreenConnect step.
- **Removing the agent does not undo the access.** Passwords, browser sessions, mail rules and new
  accounts may be compromised; the report ends with a credential-reset checklist for that reason.
- **Other remote tools** (AnyDesk, TeamViewer, RustDesk and 11 more) are detected and listed, not
  removed. Turn them on in `files\targets.json`.

---

## Console launchers

Everything in the window is also available without it, in `files\`:

| Launcher | Same as |
|---|---|
| `START-HERE-OFFLINE.bat` | Offline (steps 1-7). Asks `Keep any ScreenConnect? [y/N]`, then one typed `y`. |
| `START-HERE-ONLINE.bat` | Online (steps 1-5). |
| `START-HERE.bat` | The original full run in one go (1-9); `--stage` = Stage tools. |
| `Run-DetectRemoteAccess.bat` | Detection only, results to `Desktop\RemoteAccessScan\`. |

Use them if the window will not open on a PC. How the two halves hand over and how they differ from
the full run: [OFFLINE-ONLINE-SPLIT.md](OFFLINE-ONLINE-SPLIT.md).
