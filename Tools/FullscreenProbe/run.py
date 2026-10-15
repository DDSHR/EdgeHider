"""Run migration checks exclusively against the disposable probe helpers."""
import json
import os
import signal
import subprocess
import tempfile
import time
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTROL = ROOT / 'build/EdgeHiderFullscreenProbe.app'
HELPERS = Path('/tmp/EdgeHiderFullscreenProbe')

def control(*args):
    directory = Path(tempfile.mkdtemp(prefix='edgehider-probe-report-'))
    output, error = directory / 'output.json', directory / 'stderr.txt'
    subprocess.run(['open', '-n', '-g', '--stdout', str(output), '--stderr', str(error),
                    str(CONTROL), '--args', *map(str, args)], check=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            return json.loads(output.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(0.1)
    raise RuntimeError(f'Controller did not produce a report: {error.read_text() if error.exists() else ""}')

def launch(role):
    path = Path(f'/tmp/edgehider-probe-{role}.json')
    old = path.read_text() if path.exists() else ''
    subprocess.run(['open', '-n', str(HELPERS / f'{role}.app'), '--args', role], check=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            raw = path.read_text()
            if raw != old:
                return json.loads(raw)
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f'{role} did not launch')

helpers = []
holder = None
report = {'system': 'macOS 26.5.2', 'test': 'foreign real window into native fullscreen Space'}
tags_mode = '--tags' in sys.argv
try:
    permission = control('inspect', 0)
    report['accessibilityTrusted'] = permission['accessibilityTrusted']
    if not permission['accessibilityTrusted']:
        raise RuntimeError('Controller has no Accessibility permission')
    target = launch('target'); helpers.append(target)
    original = control('inspect', target['window'])
    host = launch('host'); helpers.append(host)
    host_space = None
    for attempt in range(15):
        topology = control('inventory')
        for display in topology['displays']:
            for space in display['Spaces']:
                if space.get('pid') == host['pid'] and space.get('type') == 4:
                    host_space = space['id64']
                    report['activeSpaceBefore'] = display['Current Space']['id64']
        if host_space and report['activeSpaceBefore'] == host_space:
            break
        time.sleep(0.4)
    if not host_space:
        raise RuntimeError('No native fullscreen test Space found')
    report['fullscreenSpace'] = host_space
    report['originalWindowSpaces'] = original['spacesBefore']
    if '--floating' in sys.argv:
        holder = subprocess.Popen([str(HELPERS / 'experimental'), 'tags', str(target['window']), '0', '0', 'hold'], stdout=subprocess.PIPE, text=True)
        time.sleep(0.7)
        report['floatingLevelObservedByController'] = control('inspect', target['window'])
    if tags_mode:
        command = [str(HELPERS / 'experimental'), 'tags', str(target['window']), '274877908992', '1']
        if '--owner' in sys.argv: command.append('owner')
        raw = subprocess.check_output(command, text=True)
        report['tagDisplay'] = json.loads(raw)
    else:
        report['migration'] = control('move', target['window'], host_space)
    topology = control('inventory')
    report['activeSpacesAfter'] = [d['Current Space']['id64'] for d in topology['displays']]
    if not tags_mode:
        report['windowMoved'] = host_space in report['migration']['spacesAfter']
    report['fullscreenStayedActive'] = host_space in report['activeSpacesAfter']
    if original['spacesBefore'] and not tags_mode:
        report['restoration'] = control('move', target['window'], original['spacesBefore'][0])
        report['originalSpaceAfterAttempt'] = original['spacesBefore'][0] in report['restoration']['spacesAfter']
        report['restorationVerifiedAfterMigration'] = report.get('windowMoved', False) and report['originalSpaceAfterAttempt']
    if holder:
        raw, _ = holder.communicate(timeout=15)
        report['floatingPreparation'] = json.loads(raw)
finally:
    if holder and holder.poll() is None: holder.terminate()
    for helper in reversed(helpers):
        try:
            os.kill(helper['pid'], signal.SIGTERM)
        except ProcessLookupError:
            pass
    report_path = ROOT / 'Tools/FullscreenProbe' / ('latest-tags-result.json' if tags_mode else 'latest-result.json')
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
