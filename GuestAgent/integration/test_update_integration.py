import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('update', Path(__file__).with_name('update-integration.py'))
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class IntegrationUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'root'
        self.bundle = Path(self.temp.name) / 'bundle'
        self.bundle.mkdir()
        self.old = {}
        for name, relative in update.FILES.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            self.old[name] = ('old ' + name).encode()
            path.write_bytes(self.old[name])
            path.chmod(0o751)
        self.config = self.root / 'etc/rift-agent/config.json'
        self.config.parent.mkdir(parents=True)
        self.config.write_bytes(b'pairing must survive exactly')
        agent = b'\x7fELF\x02\x01' + b'\0' * 12 + b'\xb7\x00' + b'candidate'
        data = {'rift-agent': agent, 'omarchy-riftvm-display-watch': b'#!/bin/bash\necho candidate\n'}
        for name, content in data.items():
            (self.bundle / name).write_bytes(content)
        self.manifest = {'schemaVersion': 1, 'product': 'riftvm-omarchy-integration', 'version': 'test',
                         'files': {k: hashlib.sha256(v).hexdigest() for k, v in data.items()}}
        self.save_manifest()

    def save_manifest(self):
        (self.bundle / 'manifest.json').write_text(json.dumps(self.manifest))

    def assert_old(self):
        for name, relative in update.FILES.items():
            self.assertEqual((self.root / relative).read_bytes(), self.old[name])
            self.assertEqual((self.root / relative).stat().st_mode & 0o777, 0o751)
        self.assertEqual(self.config.read_bytes(), b'pairing must survive exactly')

    def test_install_idempotence_and_rollback_preserve_configuration(self):
        update.run('install', self.bundle, self.root)
        for name, relative in update.FILES.items():
            self.assertEqual((self.root / relative).read_bytes(), (self.bundle / name).read_bytes())
        update.run('install', self.bundle, self.root)
        update.run('rollback', self.bundle, self.root)
        self.assert_old()

    def test_accept_preserves_rollback_and_allows_a_later_update(self):
        update.run('install', self.bundle, self.root)
        update.run('accept', self.bundle, self.root)
        update.run('rollback', self.bundle, self.root)
        self.assert_old()

    def test_bad_checksum_does_not_change_either_component(self):
        (self.bundle / 'rift-agent').write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            update.run('install', self.bundle, self.root)
        self.assert_old()

    def test_partial_write_failure_restores_both_files(self):
        original = update.write_atomic
        failed = False
        def fail_second(path, data, mode=0o600):
            nonlocal failed
            if path == self.root / update.FILES['omarchy-riftvm-display-watch'] and not failed:
                failed = True
                raise OSError('injected disk write failure')
            original(path, data, mode)
        with patch.object(update, 'write_atomic', side_effect=fail_second):
            with self.assertRaisesRegex(OSError, 'injected'):
                update.run('install', self.bundle, self.root)
        self.assert_old()
        self.assertEqual(update.load_journal(self.root / update.STATE)['phase'], 'rolled-back')

    def test_interrupted_install_recovers_before_retry(self):
        update.run('install', self.bundle, self.root)
        state = self.root / update.STATE
        journal = update.load_journal(state)
        journal['phase'] = 'installing'
        update.save_journal(state, journal)
        with self.assertRaisesRegex(ValueError, 'recovered an interrupted'):
            update.run('install', self.bundle, self.root)
        self.assert_old()

    def test_corrupt_backup_refuses_partial_rollback(self):
        update.run('install', self.bundle, self.root)
        (self.root / update.STATE / 'rift-agent.previous').write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'backup checksum'):
            update.run('rollback', self.bundle, self.root)
        for name, relative in update.FILES.items():
            self.assertEqual((self.root / relative).read_bytes(), (self.bundle / name).read_bytes())

    def test_symlink_destination_and_payload_rejected(self):
        path = self.root / update.FILES['rift-agent']
        path.unlink()
        path.symlink_to(self.config)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            update.run('install', self.bundle, self.root)
        self.assertEqual(self.config.read_bytes(), b'pairing must survive exactly')
        path.unlink()
        path.write_bytes(self.old['rift-agent'])
        (self.bundle / 'rift-agent').unlink()
        (self.bundle / 'rift-agent').symlink_to(self.config)
        with self.assertRaises(OSError):
            update.run('install', self.bundle, self.root)

    def test_extra_manifest_path_and_wrong_architecture_rejected(self):
        self.manifest['files']['../../etc/passwd'] = 'bad'
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'exactly'):
            update.run('install', self.bundle, self.root)
        del self.manifest['files']['../../etc/passwd']
        data = b'not an ARM executable'
        (self.bundle / 'rift-agent').write_bytes(data)
        self.manifest['files']['rift-agent'] = hashlib.sha256(data).hexdigest()
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, 'AArch64'):
            update.run('install', self.bundle, self.root)
        self.assert_old()


if __name__ == '__main__':
    unittest.main()
