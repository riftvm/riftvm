#!/usr/bin/env python3
"""Offline, explicit Omarchy integration update. Reboot after install/rollback."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

FILES = {
    'rift-agent': 'usr/local/sbin/rift-agent',
    'omarchy-riftvm-display-watch': 'usr/local/libexec/omarchy-riftvm-display-watch',
}
STATE = 'var/lib/riftvm/integration-update'
MAX_SIZE = 32 * 1024 * 1024


def safe_path(root, relative, directory=False):
    path = root
    for part in Path(relative).parts:
        if part in ('..', '.', '/'):
            raise ValueError('unsafe path')
        path = path / part
        if path.is_symlink():
            raise ValueError(f'refusing symlink: {path}')
        if path.exists():
            info = path.stat()
            if root == Path('/') and (info.st_uid != 0 or info.st_mode & 0o022):
                raise ValueError(f'path must be root-owned and not group/world writable: {path}')
    if path.exists() and not (path.is_dir() if directory else path.is_file()):
        raise ValueError(f'wrong file type: {path}')
    return path


def write_atomic(path, data, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix='.integration-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_SIZE:
            raise ValueError(f'unsafe or oversized input: {path}')
        data = stream.read(MAX_SIZE + 1)
    if len(data) > MAX_SIZE:
        raise ValueError('oversized input')
    return data


def payload(bundle):
    manifest = json.loads(read_regular(bundle / 'manifest.json'))
    if manifest.get('schemaVersion') != 1 or manifest.get('product') != 'riftvm-omarchy-integration':
        raise ValueError('unsupported manifest')
    entries = manifest.get('files', {})
    if set(entries) != set(FILES):
        raise ValueError('manifest must contain exactly the Agent and watcher')
    data = {name: read_regular(bundle / name) for name in FILES}
    for name, content in data.items():
        if hashlib.sha256(content).hexdigest() != entries[name]:
            raise ValueError(f'checksum mismatch: {name}')
    agent = data['rift-agent']
    if len(agent) < 20 or agent[:6] != b'\x7fELF\x02\x01' or agent[18:20] != b'\xb7\x00':
        raise ValueError('Agent must be a little-endian ELF64 AArch64 executable')
    if not data['omarchy-riftvm-display-watch'].startswith(b'#!/bin/bash\n'):
        raise ValueError('unexpected watcher format')
    return manifest, data


def load_journal(state):
    path = state / 'journal.json'
    return json.loads(read_regular(path)) if path.exists() else None


def save_journal(state, journal):
    write_atomic(state / 'journal.json', (json.dumps(journal, indent=2) + '\n').encode())


def restore(root, state, journal):
    # Validate every backup before replacing either installed component.
    backups = {}
    for name, relative in FILES.items():
        safe_path(root, relative)
        content = read_regular(state / (name + '.previous'))
        entry = journal['previous'][name]
        if hashlib.sha256(content).hexdigest() != entry['sha256']:
            raise ValueError(f'backup checksum mismatch: {name}')
        backups[name] = content
    for name, relative in FILES.items():
        write_atomic(root / relative, backups[name], journal['previous'][name]['mode'])
    journal['phase'] = 'rolled-back'
    save_journal(state, journal)


def run(action, bundle, root):
    root = root.resolve()
    if root == Path('/'):
        if os.geteuid() != 0:
            raise ValueError('run with sudo; preserve a stopped-VM recovery point first')
        if os.uname().sysname != 'Linux' or os.uname().machine not in ('aarch64', 'arm64'):
            raise ValueError('this installer supports Linux AArch64 only')
    # Validate all destination ancestors before creating state or taking a lock.
    destinations = {name: safe_path(root, relative) for name, relative in FILES.items()}
    for path in destinations.values():
        if not path.is_file():
            raise ValueError(f'existing Omarchy component missing: {path}')
    state = safe_path(root, STATE, directory=True)
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = safe_path(root, STATE + '/lock')
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name in ('journal.json', *(n + '.previous' for n in FILES)):
            safe_path(root, STATE + '/' + name)
        journal = load_journal(state)
        if action == 'status':
            print(json.dumps(journal or {'phase': 'not-installed'}, indent=2))
            return
        if journal and journal['phase'] in ('installing', 'rolling-back'):
            restore(root, state, journal)
            raise ValueError('recovered an interrupted update; reboot before retrying')
        if action == 'accept':
            if not journal or journal['phase'] != 'installed':
                raise ValueError('no installed update to accept')
            if any(hashlib.sha256(read_regular(path)).hexdigest() != journal['files'][name]
                   for name, path in destinations.items()):
                raise ValueError('installed components changed; refusing to accept')
            journal['phase'] = 'accepted'
            save_journal(state, journal)
            print('Update accepted. Backups remain available until the next installation.')
            return
        if action == 'rollback':
            if not journal or journal['phase'] not in ('installed', 'accepted'):
                raise ValueError('no installed update to roll back')
            journal['phase'] = 'rolling-back'
            save_journal(state, journal)
            restore(root, state, journal)
            print('Previous Agent and watcher restored. Reboot to activate them.')
            return
        manifest, data = payload(bundle)
        if all(hashlib.sha256(read_regular(path)).hexdigest() == manifest['files'][name]
               for name, path in destinations.items()):
            print('Both components already match. Reboot if this update is not active yet.')
            return
        # Keep the last recovery set until explicitly rolled back. Do not silently
        # overwrite the only backup with a second update.
        if journal and journal['phase'] == 'installed':
            raise ValueError('an update backup already exists; validate after reboot, then accept before another version')
        previous = {}
        for name, path in destinations.items():
            content = read_regular(path)
            mode = stat.S_IMODE(path.stat().st_mode)
            previous[name] = {'sha256': hashlib.sha256(content).hexdigest(), 'mode': mode}
            write_atomic(state / (name + '.previous'), content)
        journal = {'phase': 'installing', 'version': manifest['version'],
                   'files': manifest['files'], 'previous': previous}
        save_journal(state, journal)
        try:
            for name, path in destinations.items():
                write_atomic(path, data[name], 0o755)
            journal['phase'] = 'installed'
            save_journal(state, journal)
        except BaseException:
            restore(root, state, journal)
            raise
        print('Agent and watcher installed; pairing and user configuration were preserved.')
        print('Save your work and reboot Omarchy to activate both components together.')
        print('If needed, run this installer with rollback, then reboot again.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'rollback', 'status', 'accept'])
    parser.add_argument('--bundle', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--fixture-root', type=Path, help='offline test filesystem; never starts services')
    args = parser.parse_args()
    if args.fixture_root and args.fixture_root.resolve() == Path('/'):
        parser.error('fixture root must not be /')
    try:
        run(args.action, args.bundle, args.fixture_root or Path('/'))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'integration update failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
