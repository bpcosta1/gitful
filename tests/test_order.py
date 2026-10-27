import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / 'gitful.py'


class RepositoryOrderTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.paths = [str(self.base / name) for name in ('first repo', 'hidden repo', 'last repo')]
        self.config = self.base / 'config.json'
        self.config.write_text(json.dumps({'repositories': self.paths, 'fetch_interval': 600}))

    def run_cli(self, *arguments, expected=0):
        result = subprocess.run(
            [sys.executable, str(HELPER), '--config', str(self.config), *arguments],
            capture_output=True, text=True,
            env={**os.environ, 'XDG_STATE_HOME': str(self.base / 'state')},
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_saved_order_survives_new_processes_and_status_refreshes(self):
        first, hidden, last = self.paths
        result = self.run_cli('move', last, 'before', first)
        expected = [last, first, hidden]
        self.assertEqual(result['order'], expected)
        saved = json.loads(self.config.read_text())
        self.assertEqual(saved, {'repositories': expected, 'fetch_interval': 600})
        for command in ('status', 'monitor'):
            snapshot = self.run_cli(command)
            self.assertEqual([row['path'] for row in snapshot['repositories']], expected)
        self.run_cli('move', last, 'after', hidden)
        self.assertEqual(json.loads(self.config.read_text())['repositories'], [first, hidden, last])

    def test_filtered_move_preserves_other_repositories(self):
        first, hidden, last = self.paths
        # The UI passes the neighboring visible row, so hidden rows are retained.
        self.run_cli('move', first, 'after', last)
        self.assertEqual(json.loads(self.config.read_text())['repositories'], [hidden, last, first])

    def test_stale_or_self_moves_leave_config_untouched(self):
        original = self.config.read_bytes()
        for source, target in ((self.paths[0], str(self.base / 'untracked')),
                               (str(self.base / 'untracked'), self.paths[0]),
                               (self.paths[0], self.paths[0])):
            result = self.run_cli('move', source, 'before', target, expected=1)
            self.assertFalse(result['ok'])
            self.assertEqual(self.config.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
