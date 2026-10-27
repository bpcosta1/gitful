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
from gitful_core import core as gp


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

    def test_notification_types_and_startup_preference_persist(self):
        changes = {
            'fetch_interval': 900,
            'fetch_on_startup': False,
            'notification_types': {'incoming_commits': False, 'fetch_errors': True},
        }
        gp.update_preferences(self.config, changes)
        gp.update_preferences(self.config, {'notification_types': {'incoming_commits': True}}, self.path)
        config_file = self.base / 'config.json'
        gp.save_config(config_file, self.config)
        reloaded = gp.read_config(config_file)
        self.assertFalse(gp.preferences_view(reloaded)['fetch_on_startup'])
        self.assertEqual(gp.preferences_view(reloaded)['notification_types'],
                         {'incoming_commits': False, 'fetch_errors': True})
        self.assertEqual(gp.preferences_view(reloaded, self.path)['notification_types'],
                         {'incoming_commits': True, 'fetch_errors': True})

    def test_detect_applications_from_path_and_desktop_entry(self):
        bin_dir = self.base / 'bin'
        bin_dir.mkdir()
        executable = bin_dir / 'code'
        executable.write_text('#!/bin/sh\n')
        executable.chmod(0o755)
        applications = self.base / 'data/applications'
        applications.mkdir(parents=True)
        (applications / 'code.desktop').write_text(
            '[Desktop Entry]\nType=Application\nName=Visual Studio Code\nExec=code --new-window %F\nCategories=Development;IDE;\n')
        with patch.dict(os.environ, {'PATH': str(bin_dir), 'XDG_DATA_HOME': str(self.base / 'data'), 'XDG_DATA_DIRS': ''}):
            found = gp.detect_applications()
        self.assertEqual(found['editor'], [{'name': 'Visual Studio Code', 'command': 'code --new-window'}])

    @patch.object(gp.shutil, 'which', side_effect=lambda name: '/bin/' + name)
    @patch.object(gp.subprocess, 'Popen')
    def test_test_command_uses_argument_array_and_repository_cwd(self, popen, which):
        message = gp.test_application(self.config, 'editor', 'code --new-window "{path}"', self.path)
        self.assertEqual(popen.call_args.args[0], ['code', '--new-window', self.path])
        self.assertEqual(popen.call_args.kwargs['cwd'], self.path)
        self.assertNotIn('shell', popen.call_args.kwargs)
        self.assertIn('started', message)

    def test_custom_notification_types_gate_delivery(self):
        row = {
            'name': 'sample', 'path': self.path, 'branch': 'main', 'dirty': False, 'changed': 0,
            'staged': 0, 'unstaged': 0, 'untracked': 0, 'conflicts': 0, 'stashes': 0,
            'operation': None, 'ahead': 0, 'behind': 0, 'upstream': 'origin/main',
            'detached': False, 'error': None, 'incoming_revision': None,
        }
        previous = {'attempted': 1000, 'fetch_error': 'network failed'}
        config = {'repositories': [self.path], 'notification_types': {'incoming_commits': False, 'fetch_errors': True}}
        with patch.object(gp.time, 'time', return_value=1000), patch.object(gp, 'status', return_value=dict(row)), \
                patch.object(gp, 'notify', return_value=True) as notify:
            result, saved = gp.monitor_repo(self.path, previous, 300, config=config)
        notify.assert_called_once_with(result, 'fetch_error')
        self.assertEqual(saved['notified_fetch_error'], 'network failed')

    def test_startup_fetch_setting_controls_initial_fetch(self):
        for enabled, expected in ((True, True), (False, False)):
            config = {'repositories': [self.path], 'fetch_on_startup': enabled}
            state = self.base / ('state-' + str(enabled) + '.json')
            with patch.object(gp, 'monitor_repo', return_value=({}, {})) as monitored:
                gp.monitor(config, state, startup=True)
            self.assertEqual(monitored.call_args.args[3], expected)

    def test_invalid_changes_do_not_write_config(self):
        config = self.base / 'config.json'
        gp.save_config(config, self.config)
        original = config.read_bytes()
        for changes in ({'fetch_interval': 0}, {'notifications': 'no'}, {'work_hours': {'start': '25:00'}},
                        {'work_hours': {'weekdays': []}}, {'launchers': {'editor': '"unterminated'}},
                        {'launchers': {'editor': 42}}, {'snooze_minutes': -1},
                        {'fetch_on_startup': 'yes'}, {'notification_types': {'incoming_commits': 1}}, {'unknown': True}):
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
            gp.launch_repository(self.config, self.path, 'agent', platform='omarchy')
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
                gp.launch_repository(self.config, self.path, 'editor', platform='omarchy')
        with patch.object(gp.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', '')):
            with self.assertRaisesRegex(ValueError, 'Choose a coding agent'):
                gp.launch_repository(self.config, self.path, 'agent', platform='omarchy')


if __name__ == '__main__':
    unittest.main()
