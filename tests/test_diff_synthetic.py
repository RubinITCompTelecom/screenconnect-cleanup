#!/usr/bin/env python3
"""Synthetic Stage 7 test: inject items into the real snapshots so the diff
Removed/Added/Changed paths get exercised end-to-end via pwsh.

Runs locally and in CI. On Windows CI the temp dir is %RUNNER_TEMP%
(passed via SCC_TEST_TMP); default /tmp keeps local Linux behavior.
"""
import json, copy, os, subprocess, sys, tempfile

tmp = os.environ.get('SCC_TEST_TMP') or tempfile.gettempdir()
pwsh = 'powershell.exe' if os.name == 'nt' else 'pwsh'

def load(p):
    return json.load(open(p))

before = load('snapshots/before.json')
after = copy.deepcopy(before)
# This test exercises diff semantics, not Linux platform collection failures.
# Normalize the historical fixture to an explicitly complete snapshot; the
# incomplete verdict is tested separately below.
before['CollectionErrors'] = []
before['CollectionWarnings'] = []
before['CollectionComplete'] = True
after['CollectionErrors'] = []
after['CollectionWarnings'] = []
after['CollectionComplete'] = True

S = before['Sections']

# Stable sections
# 1) Service REMOVED after (proof-of-removal path)
S['Services'].append({'Key': 'ScreenConnect Client (synth)', 'Name': 'ScreenConnect Client (synth)', 'State': 'Running', 'StartMode': 'Auto'})
# 2) Scheduled task RESURRECTED in after (added-in-stable -> verdict RESURRECTION)
after['Sections']['ScheduledTasks'].append({'Key': '\\Synth\\PersistTask', 'TaskPath': '\\Synth\\', 'TaskName': 'PersistTask'})
# 3) Registry autorun CHANGED value in after
S['RegistryAutoruns'].append({'Key': 'HKCU\\...\\Run|SynthVal', 'Value': 'C:\\legit.exe'})
after['Sections']['RegistryAutoruns'].append({'Key': 'HKCU\\...\\Run|SynthVal', 'Value': 'C:\\evil2.exe'})
# 4) Volatile section: process added+removed (should NOT flip verdict)
S['Processes'].append({'Key': '1234', 'Name': 'oldproc.exe'})
after['Sections']['Processes'].append({'Key': '9999', 'Name': 'newproc.exe'})
# 5) Nested/array field changes must be compared structurally, not by the
#    PowerShell string representation of System.Object[].
S['Services'].append({'Key': 'SynthArray', 'Tags': ['old']})
after['Sections']['Services'].append({'Key': 'SynthArray', 'Tags': ['new']})
# 6) An empty JSON object is the Windows PowerShell 5.1 serialization of an
#    empty collection and must count as zero.
before['Sections']['Amcache'] = {}
after['Sections']['Amcache'] = {}
# 7) Forensic-history additions are informational, not resurrection signals.
after['Sections']['Prefetch'].append({'Key': 'synth-history.pf', 'Path': 'C:\\\\synth-history.exe'})

b_path = os.path.join(tmp, 'synth-before.json')
a_path = os.path.join(tmp, 'synth-after.json')
d_path = os.path.join(tmp, 'synth-diff.json')
json.dump(before, open(b_path, 'w'))
json.dump(after, open(a_path, 'w'))

r = subprocess.run([pwsh, '-NoProfile', '-File', './diff-snapshots.ps1',
                    '-BeforeFile', b_path, '-AfterFile', a_path,
                    '-OutFile', d_path], capture_output=True, text=True)
print(r.stdout)
print(r.stderr)
print('rc =', r.returncode)
d = json.load(open(d_path))

def run_diff(b, a, name, manifest=None):
    """Run diff-snapshots.ps1 on in-memory snapshots; returns (rc, report)."""
    bp = os.path.join(tmp, name + '-before.json')
    ap = os.path.join(tmp, name + '-after.json')
    dp = os.path.join(tmp, name + '-diff.json')
    json.dump(b, open(bp, 'w'))
    json.dump(a, open(ap, 'w'))
    cmd = [pwsh, '-NoProfile', '-File', './diff-snapshots.ps1',
           '-BeforeFile', bp, '-AfterFile', ap, '-OutFile', dp]
    if manifest is not None:
        mp = os.path.join(tmp, name + '-manifest.json')
        if isinstance(manifest, str):
            mp = manifest  # explicit path (e.g. a file that does not exist)
        else:
            json.dump(manifest, open(mp, 'w'))
        cmd += ['-ManifestPath', mp]
    rr = subprocess.run(cmd, capture_output=True, text=True)
    return rr.returncode, json.load(open(dp))

def entry(action, target, result='Success', **kw):
    e = {'InstanceId': 'abc', 'Action': action, 'Target': target, 'Result': result}
    e.update(kw)
    return e

def manifest_of(*entries):
    return {'Script': 'remove-screenconnect.ps1', 'Entries': list(entries)}

SVC = 'ScreenConnect Client (abc123)'
SVC_DIR = 'C:\\Program Files (x86)\\ScreenConnect Client (abc123)'
def base_pair():
    """Complete before/after with ScreenConnect artifacts present BEFORE removal."""
    b = copy.deepcopy(before)
    b['Sections']['Services'].append({'Key': SVC, 'Name': SVC, 'PathName': '"' + SVC_DIR + '\\ScreenConnect.ClientService.exe" "?e=Access"'})
    b['Sections']['ScheduledTasks'].append({'Key': '\\SCUpdate|Check', 'TaskPath': '\\SCUpdate', 'TaskName': 'Check', 'Actions': []})
    b['Sections']['RegistryAutoruns'].append({'Key': 'HKLM|SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run|SCRun', 'Hive': 'HKLM', 'KeyPath': 'SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run', 'ValueName': 'SCRun', 'Value': 'x'})
    b['Sections']['InstalledPrograms'].append({'Key': 'HKLM|{GUID}', 'DisplayName': 'ScreenConnect Client (abc123)', 'InstallLocation': SVC_DIR})
    b['Sections']['WmiPersistence'].append({'Key': 'root\\subscription|__EventFilter|SCFilter', 'Name': 'SCFilter'})
    a = copy.deepcopy(b)
    # the removal: everything above is gone in AFTER
    for sec in ('Services', 'ScheduledTasks', 'RegistryAutoruns', 'InstalledPrograms', 'WmiPersistence'):
        a['Sections'][sec] = [i for i in a['Sections'][sec] if i['Key'] not in (
            SVC, '\\SCUpdate|Check', 'HKLM|SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run|SCRun',
            'HKLM|{GUID}', 'root\\subscription|__EventFilter|SCFilter')]
    return b, a

FULL_MANIFEST = manifest_of(
    entry('StopService', SVC), entry('DeleteService', SVC),
    entry('DeleteScheduledTask', '\\SCUpdate\\Check'),
    entry('DeleteRunKey', 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run\\SCRun'),
    entry('DeleteWmiSubscription', 'SCFilter -> SCConsumer'),
    entry('Uninstall', 'ScreenConnect Client (abc123)'),
    entry('Quarantine', SVC_DIR, SourcePath=SVC_DIR),
    entry('KillProcess', 'PID 4242'),
    entry('DeleteService', 'DryRunSvc', result='DryRun'))

# A recorded collection failure in a STABLE section must fail closed when
# nothing came back (precedence RESURRECTION > INCOMPLETE > CLEAN).
same_after = copy.deepcopy(before)
same_after['CollectionComplete'] = False
same_after['CollectionErrors'] = [{'Section': 'Services', 'Error': 'synthetic timeout'}]
rc_inc, d_incomplete = run_diff(before, same_after, 'incomplete')

# Bug 3: an error in an informational section must not override a resurrection
# and must not make an otherwise clean diff INCOMPLETE.
info_err = [{'Section': 'Prefetch', 'Error': 'synthetic prefetch denied'}]
after_info_res = copy.deepcopy(after)
after_info_res['CollectionComplete'] = False
after_info_res['CollectionErrors'] = info_err
rc_ir, d_info_res = run_diff(before, after_info_res, 'info-res')
after_info_clean = copy.deepcopy(before)
after_info_clean['CollectionComplete'] = False
after_info_clean['CollectionErrors'] = info_err
rc_ic, d_info_clean = run_diff(before, after_info_clean, 'info-clean')
# precedence: stable error + resurrection => RESURRECTION
after_stable_res = copy.deepcopy(after)
after_stable_res['CollectionComplete'] = False
after_stable_res['CollectionErrors'] = [{'Section': 'Services', 'Error': 'synthetic timeout'}]
rc_sr, d_stable_res = run_diff(before, after_stable_res, 'stable-res')
# flag false with no recorded error at all stays fail-closed
after_flag = copy.deepcopy(before)
after_flag['CollectionComplete'] = False
after_flag['CollectionErrors'] = []
rc_fl, d_flag = run_diff(before, after_flag, 'flag-only')

# Bug 1 (manifest): removed item that returns under the same name.
b1, a1 = base_pair()
rc_nm, d_nomanifest = run_diff(b1, a1, 'm-clean')                       # no manifest, removed OK
rc_m_ok, d_m_ok = run_diff(b1, a1, 'm-ok', FULL_MANIFEST)                # manifest, removed OK
b2, a2 = base_pair()
a2['Sections']['Services'].append(copy.deepcopy(b2['Sections']['Services'][-1]))  # same name returns
rc_back_nm, d_back_nomanifest = run_diff(b2, a2, 'back-nm')              # old behaviour: reads CLEAN
rc_back, d_back = run_diff(b2, a2, 'back', FULL_MANIFEST)
# Bug 2 (manifest): unrelated new items are informational.
b3, a3 = base_pair()
a3['Sections']['Services'].append({'Key': 'UnrelatedNewSvc', 'Name': 'UnrelatedNewSvc', 'PathName': 'C:\\Tools\\other.exe'})
a3['Sections']['ScheduledTasks'].append({'Key': '\\Vendor|Updater', 'TaskPath': '\\Vendor', 'TaskName': 'Updater', 'Actions': []})
rc_unrel_nm, d_unrel_nomanifest = run_diff(b3, a3, 'unrel-nm')
rc_unrel, d_unrel = run_diff(b3, a3, 'unrel', FULL_MANIFEST)
# Path-based match: different name, but runs from the quarantined directory.
b4, a4 = base_pair()
a4['Sections']['Services'].append({'Key': 'Renamed', 'Name': 'Renamed', 'PathName': '"' + SVC_DIR + '\\ScreenConnect.ClientService.exe"'})
rc_path, d_path = run_diff(b4, a4, 'path', FULL_MANIFEST)
# A sibling directory that merely shares the prefix must NOT match.
b5, a5 = base_pair()
a5['Sections']['Services'].append({'Key': 'Sibling', 'Name': 'Sibling', 'PathName': SVC_DIR + '2\\x.exe'})
rc_sib, d_sib = run_diff(b5, a5, 'sibling', FULL_MANIFEST)
# Each other target kind still present in AFTER.
for kind, sec, item in (
        ('task', 'ScheduledTasks', {'Key': '\\SCUpdate|Check', 'TaskPath': '\\SCUpdate', 'TaskName': 'Check', 'Actions': []}),
        ('runkey', 'RegistryAutoruns', {'Key': 'HKLM|SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run|SCRun', 'Hive': 'HKLM', 'KeyPath': 'SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run', 'ValueName': 'SCRun'}),
        ('program', 'InstalledPrograms', {'Key': 'HKLM|{GUID2}', 'DisplayName': 'screenconnect client (ABC123)'}),
        ('wmi', 'WmiPersistence', {'Key': 'root\\subscription|__EventFilter|scfilter', 'Name': 'scfilter'})):
    bk, ak = base_pair()
    ak['Sections'][sec].append(item)
    rck, dk = run_diff(bk, ak, 'kind-' + kind, FULL_MANIFEST)
    TK = globals().setdefault('TK', {})
    TK[kind] = (rck, dk)
# Failed removal still counts; DryRun entries never do.
b6, a6 = base_pair()
a6['Sections']['Services'].append({'Key': 'DryRunSvc', 'Name': 'DryRunSvc'})
rc_dry, d_dry = run_diff(b6, a6, 'dryrun', FULL_MANIFEST)
# Stable collection error + clean targets => INCOMPLETE even with a manifest.
b7, a7 = base_pair()
a7['CollectionComplete'] = False
a7['CollectionErrors'] = [{'Section': 'ScheduledTasks', 'Error': 'synthetic'}]
rc_minc, d_minc = run_diff(b7, a7, 'm-incomplete', FULL_MANIFEST)
# Resurrection still wins over a stable error with a manifest.
b8, a8 = base_pair()
a8['Sections']['Services'].append(copy.deepcopy(b8['Sections']['Services'][-1]))
a8['CollectionComplete'] = False
a8['CollectionErrors'] = [{'Section': 'ScheduledTasks', 'Error': 'synthetic'}]
rc_mres, d_mres = run_diff(b8, a8, 'm-res-inc', FULL_MANIFEST)
# Manifest absent / unreadable / empty => original (snapshot-only) behaviour.
rc_missing, d_missing = run_diff(b3, a3, 'm-missing', os.path.join(tmp, 'no-such-manifest.json'))
rc_empty, d_empty = run_diff(b3, a3, 'm-empty', manifest_of(entry('KillProcess', 'PID 1'), entry('Uninstall', 'Registry', result='Skipped')))

checks = {
    'verdict RESURRECTION': d['Verdict'] == 'RESURRECTION',
    'incomplete collection verdict': d_incomplete['Verdict'] == 'INCOMPLETE' and rc_inc == 1,
    'resurrection count 1': d['ResurrectionsAdded'] == 1,
    'no manifest: VerdictBasis snapshot-added': d['VerdictBasis'] == 'snapshot-added' and d['ManifestUsed'] is False,
    'bug3: informational error does not hide resurrection': d_info_res['Verdict'] == 'RESURRECTION' and rc_ir == 1,
    'bug3: informational error alone stays CLEAN and is reported': d_info_clean['Verdict'] == 'CLEAN' and rc_ic == 0
        and len(d_info_clean['InformationalCollectionErrors']) == 1
        and len(d_info_clean['AfterCollectionErrors']) == 1 and d_info_clean['AfterCollectionComplete'] is True
        and d_info_clean['AfterCollectionCompleteRaw'] is False,
    'precedence: stable error + resurrection => RESURRECTION': d_stable_res['Verdict'] == 'RESURRECTION' and rc_sr == 1,
    'collection flag false with no errors stays INCOMPLETE': d_flag['Verdict'] == 'INCOMPLETE' and rc_fl == 1,
    'manifest: removal verified => CLEAN': d_m_ok['Verdict'] == 'CLEAN' and rc_m_ok == 0 and d_m_ok['ManifestUsed'] is True
        and d_m_ok['ManifestTargetCount'] >= 7 and not d_m_ok['TargetsStillPresent'],
    'no manifest: removal verified => CLEAN': d_nomanifest['Verdict'] == 'CLEAN' and rc_nm == 0,
    'bug1: same-name return reads CLEAN without a manifest (documented limit)': d_back_nomanifest['Verdict'] == 'CLEAN',
    'bug1: same-name return is RESURRECTION with a manifest': d_back['Verdict'] == 'RESURRECTION' and rc_back == 1
        and [(x['Section'], x['Key']) for x in d_back['TargetsStillPresent'] if x['TargetKind'] == 'service'] == [('Services', SVC)],
    'bug2: unrelated new items are RESURRECTION without a manifest': d_unrel_nomanifest['Verdict'] == 'RESURRECTION',
    'bug2: unrelated new items are informational with a manifest': d_unrel['Verdict'] == 'CLEAN' and rc_unrel == 0
        and sorted(x['Key'] for x in d_unrel['NewSinceBefore']) == ['UnrelatedNewSvc', '\\Vendor|Updater'] and d_unrel['ResurrectionsAdded'] == 0,
    'manifest: path under quarantined dir matches renamed service': d_path['Verdict'] == 'RESURRECTION'
        and any(x['Key'] == 'Renamed' and x['TargetKind'] == 'path' for x in d_path['TargetsStillPresent']),
    'manifest: sibling dir sharing a prefix does not match': d_sib['Verdict'] == 'CLEAN',
    'manifest: failed/dry-run: DryRun entry is ignored': d_dry['Verdict'] == 'CLEAN',
    'manifest: stable error + clean targets => INCOMPLETE': d_minc['Verdict'] == 'INCOMPLETE' and rc_minc == 1,
    'manifest: resurrection beats stable error': d_mres['Verdict'] == 'RESURRECTION' and rc_mres == 1,
    'manifest missing file falls back to snapshot-only + reports error': d_missing['Verdict'] == 'RESURRECTION'
        and d_missing['ManifestUsed'] is False and bool(d_missing['ManifestError']) and d_missing['VerdictBasis'] == 'snapshot-added',
    'manifest without usable targets falls back to snapshot-only': d_empty['Verdict'] == 'RESURRECTION'
        and d_empty['ManifestUsed'] is False and bool(d_empty['ManifestError']),
}
for kind, (rck, dk) in TK.items():
    checks['manifest target kind still present: ' + kind] = dk['Verdict'] == 'RESURRECTION' and rck == 1 \
        and any(x['TargetKind'] == kind for x in dk['TargetsStillPresent'])
svc = next(s for s in d['Sections'] if s['Section']=='Services')
st  = next(s for s in d['Sections'] if s['Section']=='ScheduledTasks')
ra  = next(s for s in d['Sections'] if s['Section']=='RegistryAutoruns')
pr  = next(s for s in d['Sections'] if s['Section']=='Processes')
am  = next(s for s in d['Sections'] if s['Section']=='Amcache')
pf  = next(s for s in d['Sections'] if s['Section']=='Prefetch')
checks['services removed list'] = svc['Removed'] == ['ScreenConnect Client (synth)']
checks['tasks added list'] = st['Added'] == ['\\\\Synth\\\\PersistTask'.replace('\\\\','\\')]
checks['autoruns changed field'] = any(c.get('Fields')==['Value'] for c in ra['Changed'])
checks['volatile added not counted as resurrection'] = pr['Kind']=='volatile' and len(pr['Added'])==1 and d['ResurrectionsAdded']==1
checks['nested array field changed structurally'] = any(c.get('Key') == 'SynthArray' and c.get('Fields') == ['Tags'] for c in svc['Changed'])
checks['empty object counts as zero'] = am['BeforeCount'] == 0 and am['AfterCount'] == 0 and not am['Added'] and not am['Removed']
checks['forensic history is informational'] = pf['Kind'] == 'informational' and pf['Added'] == ['synth-history.pf'] and d['ResurrectionsAdded'] == 1
ok = all(checks.values())
for k,v in checks.items(): print(('PASS' if v else 'FAIL'), k)
sys.exit(0 if ok else 1)