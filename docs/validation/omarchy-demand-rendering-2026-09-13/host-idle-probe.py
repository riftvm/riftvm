#!/usr/bin/env python3
"""Sample the app and its VM service during guest-idle-probe.sh phases."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('app_pid', type=int)
parser.add_argument('vm_service_pid', type=int)
parser.add_argument('phase_file', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--timeout', type=float, default=240)
args = parser.parse_args()
roles = {str(args.app_pid): 'app', str(args.vm_service_pid): 'vm_service'}
rows = []
start = time.monotonic()
completed = False
while time.monotonic() - start < args.timeout:
    phase = args.phase_file.read_text().strip() if args.phase_file.exists() else 'waiting'
    if phase == 'done':
        completed = True
        break
    raw = subprocess.check_output(
        ['ps', '-p', ','.join(roles), '-o', 'pid=,pcpu=,rss='], text=True)
    processes = {}
    for line in raw.splitlines():
        pid, cpu, rss = line.split()
        processes[roles[pid]] = {'cpu_percent': float(cpu), 'rss_mib': int(rss) / 1024}
    if len(processes) != 2:
        raise SystemExit('A sampled process exited; discard this run.')
    rows.append({'elapsed_seconds': round(time.monotonic() - start, 3),
                 'phase': phase, 'processes': processes})
    time.sleep(1)
summary = {}
for phase in sorted({r['phase'] for r in rows} - {'waiting', 'settling'}):
    group = [r for r in rows if r['phase'] == phase]
    summary[phase] = {'samples': len(group), 'processes': {}}
    for role in roles.values():
        summary[phase]['processes'][role] = {
            'mean_cpu_percent': round(statistics.mean(
                r['processes'][role]['cpu_percent'] for r in group), 3),
            'mean_rss_mib': round(statistics.mean(
                r['processes'][role]['rss_mib'] for r in group), 3)}
result = {'completed': completed, 'pids': roles, 'summary': summary, 'samples': rows}
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'completed': completed, 'summary': summary}, indent=2))
if not completed:
    raise SystemExit('Guest probe did not complete; discard this run.')
