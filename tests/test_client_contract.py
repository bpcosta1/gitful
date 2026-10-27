"""Checks for the command interface consumed by desktop clients."""

import json
from contextlib import redirect_stdout
from io import StringIO
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from gitful_core import omarchy


ROOT = Path(__file__).resolve().parents[1]


class ClientContractTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.repo = self.base / 'repo with spaces'
        subprocess.run(['git', 'init', '-q', '-b', 'main', str(self.repo)], check=True)
        self.config = self.base / 'config.json'
        self.config.write_text(json.dumps({'repositories': [str(self.repo)]}))
        self.env = {**os.environ, 'XDG_STATE_HOME': str(self.base / 'state')}

    def run_client(self, client, *args):
        command = ([sys.executable, '-m', 'gitful_core'] if client == 'generic'
                   else [sys.executable, str(ROOT / 'gitful.py')])
        return subprocess.run([*command, '--config', str(self.config), *args],
                              cwd=ROOT, env=self.env, capture_output=True, text=True)

    def test_both_clients_receive_the_same_status_contract(self):
        generic = self.run_client('generic', 'status')
        omarchy_client = self.run_client('omarchy', 'status')
        self.assertEqual(generic.returncode, 0, generic.stderr)
        self.assertEqual(omarchy_client.returncode, 0, omarchy_client.stderr)
        for result in (generic, omarchy_client):
            payload = json.loads(result.stdout)
            self.assertEqual(payload['schema_version'], 1)
            self.assertEqual(payload['error'], None)
            self.assertEqual(len(payload['repositories']), 1)
            self.assertEqual(payload['repositories'][0]['path'], str(self.repo))
            self.assertEqual(payload['repositories'][0]['branch'], 'main')
            self.assertEqual(payload['repositories'][0]['dirty'], False)
            self.assertIsInstance(payload['preferences'], dict)
            self.assertIsInstance(payload['updated'], str)
        self.assertEqual(json.loads(generic.stdout)['repositories'], json.loads(omarchy_client.stdout)['repositories'])

    def test_errors_are_json_and_config_is_not_changed(self):
        before = self.config.read_bytes()
        result = self.run_client('generic', 'settings', '--set', '{"fetch_interval":0}')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['schema_version'], 1)
        self.assertEqual(json.loads(result.stdout)['ok'], False)
        self.assertEqual(self.config.read_bytes(), before)

    def test_application_errors_are_json(self):
        self.config.write_text('{broken')
        result = self.run_client('generic', 'applications')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['schema_version'], 1)
        self.assertEqual(json.loads(result.stdout)['applications'], [])
        self.assertTrue(json.loads(result.stdout)['error'])

    def test_monitor_adds_fetch_and_notification_fields(self):
        result = self.run_client('generic', 'monitor')
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload['schema_version'], 1)
        row = payload['repositories'][0]
        for key in ('fetch_error', 'fetched', 'stale', 'settings', 'notification_status'):
            self.assertIn(key, row)
        self.assertIsNone(row['fetched'])

    def test_generic_launch_requires_configured_editor(self):
        result = self.run_client('generic', 'launch', str(self.repo), 'editor')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Choose an editor', json.loads(result.stdout)['error'])

    def test_generic_cli_does_not_offer_omarchy_commands(self):
        result = self.run_client('generic', 'open')
        self.assertEqual(result.returncode, 2)
        self.assertIn('invalid choice', result.stderr)

    def test_source_installer_copies_the_shared_package(self):
        config_home = self.base / 'config_home'
        destination = config_home / 'omarchy/plugins/bpc0sta.gitful'
        with patch.object(omarchy, 'DEFAULT_CONFIG', config_home / 'gitful/config.json'), \
                patch.object(omarchy.subprocess, 'run') as run, redirect_stdout(StringIO()):
            omarchy.install()
        for name in ('manifest.json', 'Widget.qml', 'SettingsForm.qml', 'gitful.py', 'gitful'):
            self.assertTrue((destination / name).exists(), name)
        for name in ('__init__.py', '__main__.py', 'core.py', 'cli.py', 'launchers.py', 'omarchy.py'):
            self.assertTrue((destination / 'gitful_core' / name).exists(), name)
        self.assertEqual(run.call_count, 2)
        copied = subprocess.run([sys.executable, str(destination / 'gitful.py'),
                                 '--config', str(self.config), 'status'],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(copied.returncode, 0, copied.stderr)
        self.assertEqual(json.loads(copied.stdout)['repositories'][0]['path'], str(self.repo))


if __name__ == '__main__':
    unittest.main()
