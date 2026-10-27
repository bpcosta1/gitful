import importlib.util
import json
import os
from datetime import datetime
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / 'gitful.py'
spec = importlib.util.spec_from_file_location('gitful_preferences', HELPER)
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)


class PreferencesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.repo = self.base / 'repo with spaces; $(literal)'
        self.repo.mkdir()
        self.path = str(self.repo)
        self.config = {'repositories': [self.path]}

    def test_work_hours_and_overnight_periods(self):
        hours = {'enabled': True, 'start': '09:00', 'end': '18:00', 'weekdays': [0, 1, 2, 3, 4]}
        monday = lambda h, m=0: datetime(2026, 10, 26, h, m).timestamp()
        self.assertFalse(gp.work_hours_allow(hours, monday(8, 59)))
        self.assertTrue(gp.work_hours_allow(hours, monday(9)))
        self.assertFalse(gp.work_hours_allow(hours, monday(18)))
        self.assertFalse(gp.work_hours_allow(hours, datetime(2026, 10, 25, 10).timestamp()))
        hours.update(start='22:00', end='06:00', weekdays=[4])
        self.assertTrue(gp.work_hours_allow(hours, datetime(2026, 10, 30, 23).timestamp()))
        self.assertTrue(gp.work_hours_allow(hours, datetime(2026, 10, 31, 5).timestamp()))
        self.assertFalse(gp.work_hours_allow(hours, datetime(2026, 10, 31, 6).timestamp()))
        self.assertFalse(gp.work_hours_allow(hours, datetime(2026, 10, 31, 23).timestamp()))

    def test_global_and_repository_notification_gates(self):
        now = datetime(2026, 10, 26, 10).timestamp()
        self.assertEqual(gp.notification_status({}, {}, now), 'On')
        self.assertEqual(gp.notification_status({'notifications': False}, {}, now), 'Muted globally')
        self.assertEqual(gp.notification_status({}, {'notifications': False}, now), 'Muted')
        self.assertTrue(gp.notification_status({}, {'snoozed_until': now + 3600}, now).startswith('Snoozed'))
        self.assertEqual(gp.notification_status({}, {'snoozed_until': now}, now), 'On')
        hours = {'enabled': True, 'start': '11:00', 'end': '12:00'}
        self.assertEqual(gp.notification_status({'work_hours': hours}, {}, now), 'Outside work hours')

    def test_preferences_inheritance_commands_and_resets(self):
        gp.update_preferences(self.config, {'fetch_interval': 600, 'launchers': {'editor': 'code --new-window "{path}"'}})
        gp.update_preferences(self.config, {'fetch_interval': 900, 'launchers': {'agent': 'claude'}}, self.path)
        self.assertEqual(gp.preferences_view(self.config, self.path)['fetch_interval'], 900)
        gp.update_preferences(self.config, {'fetch_interval': None}, self.path)
        self.assertTrue(gp.preferences_view(self.config, self.path)['inherits_fetch_interval'])
        self.assertEqual(gp.preferences_view(self.config, self.path)['fetch_interval'], 600)
        self.assertEqual(self.config['launchers']['editor'], ['code', '--new-window', '{path}'])
        gp.update_preferences(self.config, {'launchers': {'editor': ''}})
        self.assertNotIn('editor', self.config['launchers'])
        with patch.object(gp.time, 'time', return_value=100):
            gp.update_preferences(self.config, {'snooze_minutes': 60}, self.path)
        self.assertEqual(gp.repo_options(self.config, self.path)['snoozed_until'], 3700)

    def test_invalid_changes_do_not_write_config(self):
        config = self.base / 'config.json'
        gp.save_config(config, self.config)
        original = config.read_bytes()
        for changes in ({'fetch_interval': 0}, {'notifications': 'no'}, {'work_hours': {'start': '25:00'}},
                        {'work_hours': {'weekdays': []}}, {'launchers': {'editor': '"unterminated'}},
                        {'launchers': {'editor': 42}}, {'snooze_minutes': -1}, {'unknown': True}):
            result = subprocess.run([sys.executable, str(HELPER), '--config', str(config), 'settings', '--set', json.dumps(changes)],
                                    capture_output=True, text=True,
                                    env={**os.environ, 'XDG_STATE_HOME': str(self.base / 'state')})
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertFalse(json.loads(result.stdout)['ok'])
            self.assertEqual(config.read_bytes(), original)

    @patch.object(gp.shutil, 'which', side_effect=lambda name: '/bin/' + name)
    @patch.object(gp.subprocess, 'Popen')
    def test_launch_preserves_path_as_one_argument_and_repo_cwd(self, popen, which):
        gp.update_preferences(self.config, {'launchers': {'editor': 'code --new-window "{path}"', 'files': 'thunar', 'agent': 'claude --model sonnet'}})
        gp.launch_repository(self.config, self.path, 'editor')
        self.assertEqual(popen.call_args.args[0], ['code', '--new-window', self.path])
        self.assertEqual(popen.call_args.kwargs['cwd'], self.path)
        self.assertNotIn('shell', popen.call_args.kwargs)
        gp.launch_repository(self.config, self.path, 'files')
        self.assertEqual(popen.call_args.args[0], ['thunar', self.path])
        gp.launch_repository(self.config, self.path, 'agent')
        self.assertEqual(popen.call_args.args[0], ['xdg-terminal-exec', '--dir=' + self.path, 'claude', '--model', 'sonnet'])

    @patch.object(gp.shutil, 'which', side_effect=lambda name: '/bin/' + name)
    @patch.object(gp.subprocess, 'Popen')
    def test_default_agent_and_per_repo_editor_override(self, popen, which):
        with patch.object(gp.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'codex\n', '')):
            gp.launch_repository(self.config, self.path, 'agent')
        self.assertEqual(popen.call_args.args[0], ['xdg-terminal-exec', '--dir=' + self.path, 'codex'])
        gp.update_preferences(self.config, {'launchers': {'editor': 'code'}})
        gp.update_preferences(self.config, {'launchers': {'editor': 'zed {path}'}}, self.path)
        gp.launch_repository(self.config, self.path, 'editor')
        self.assertEqual(popen.call_args.args[0], ['zed', self.path])
        with self.assertRaisesRegex(ValueError, 'not tracked'):
            gp.launch_repository(self.config, str(self.base), 'editor')

    def test_missing_application_and_unconfigured_agent(self):
        with patch.object(gp.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(ValueError, 'not found'):
                gp.launch_repository(self.config, self.path, 'editor')
        with patch.object(gp.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')):
            with self.assertRaisesRegex(ValueError, 'Choose a coding agent'):
                gp.launch_repository(self.config, self.path, 'agent')


if __name__ == '__main__':
    unittest.main()
