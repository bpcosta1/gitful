import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gitful', Path(__file__).resolve().parents[1] / 'gitful.py')
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / 'repo with spaces'
        self.run_git('init', '-b', 'main', str(self.repo))
        self.g('config', 'user.email', 'test@example.invalid')
        self.g('config', 'user.name', 'Test')

    def run_git(self, *args):
        return subprocess.check_output(['git', *args], stderr=subprocess.PIPE).decode().strip()

    def g(self, *args):
        return self.run_git('-C', str(self.repo), *args)

    def commit(self, name='file'):
        (self.repo / name).write_text(name)
        self.g('add', '.')
        self.g('commit', '-m', name)

    def test_unborn_and_dirty(self):
        self.assertEqual(gp.status(self.repo)['branch'], 'main')
        (self.repo / 'new\nfile').touch()
        row = gp.status(self.repo)
        self.assertTrue(row['dirty'])
        self.assertEqual(row['changed'], 1)
        self.assertIsNone(row['ahead'])
        self.assertEqual(row['untracked'], 1)

    def test_staged_unstaged_and_stashes_are_distinct(self):
        self.commit()
        (self.repo / 'file').write_text('staged')
        self.g('add', 'file')
        (self.repo / 'file').write_text('also unstaged')
        (self.repo / 'new').touch()
        row = gp.status(self.repo)
        self.assertEqual((row['staged'], row['unstaged'], row['untracked'], row['changed']), (1, 1, 1, 2))
        self.g('stash', 'push', '-u', '-m', 'saved work')
        row = gp.status(self.repo)
        self.assertFalse(row['dirty'])
        self.assertEqual(row['stashes'], 1)

    def test_real_merge_conflict_and_operation(self):
        self.commit()
        self.g('checkout', '-b', 'other')
        (self.repo / 'file').write_text('other')
        self.g('commit', '-am', 'other')
        self.g('checkout', 'main')
        (self.repo / 'file').write_text('main')
        self.g('commit', '-am', 'main')
        with self.assertRaises(subprocess.CalledProcessError):
            self.g('merge', 'other')
        row = gp.status(self.repo)
        self.assertEqual(row['conflicts'], 1)
        self.assertEqual(row['operation'], 'Merge')
        self.assertEqual((row['staged'], row['unstaged']), (0, 0))
        self.assertTrue(row['dirty'])

    def test_clean_detached_and_rename(self):
        self.commit()
        self.assertFalse(gp.status(self.repo)['dirty'])
        self.g('mv', 'file', 'renamed\nfile')
        self.assertEqual(gp.status(self.repo)['changed'], 1)
        self.g('commit', '-m', 'rename')
        self.g('checkout', '--detach')
        self.assertTrue(gp.status(self.repo)['detached'])

    def test_divergence_from_cached_remote(self):
        self.commit()
        remote = self.base / 'remote.git'
        self.run_git('init', '--bare', str(remote))
        self.g('remote', 'add', 'origin', str(remote))
        self.g('push', '-u', 'origin', 'main')
        self.assertEqual(gp.status(self.repo)['ahead'], 0)
        self.commit('local')
        self.assertEqual(gp.status(self.repo)['ahead'], 1)
        clone = self.base / 'clone'
        self.run_git('clone', '-b', 'main', str(remote), str(clone))
        self.run_git('-C', str(clone), 'config', 'user.name', 'Test')
        self.run_git('-C', str(clone), 'config', 'user.email', 'test@example.invalid')
        (clone / 'remote').touch()
        self.run_git('-C', str(clone), 'add', '.')
        self.run_git('-C', str(clone), 'commit', '-m', 'remote')
        self.run_git('-C', str(clone), 'push')
        self.assertEqual(gp.status(self.repo)['behind'], 0)  # no automatic fetch
        self.g('fetch')
        row = gp.status(self.repo)
        self.assertEqual((row['ahead'], row['behind']), (1, 1))

    def test_missing_and_non_repository(self):
        self.assertTrue(gp.status(self.base / 'missing')['error'])
        self.assertTrue(gp.status(self.base)['error'])

    def test_worktree(self):
        self.commit()
        worktree = self.base / 'worktree'
        self.g('worktree', 'add', '-b', 'feature', str(worktree))
        self.assertEqual(gp.status(worktree)['branch'], 'feature')
        gitdir = Path(self.run_git('-C', str(worktree), 'rev-parse', '--absolute-git-dir'))
        (gitdir / 'CHERRY_PICK_HEAD').write_text(self.g('rev-parse', 'HEAD'))
        self.assertEqual(gp.status(worktree)['operation'], 'Cherry-pick')
        self.assertIsNone(gp.status(self.repo)['operation'])

    def test_config_validation(self):
        path = self.base / 'config.json'
        self.assertEqual(gp.read_config(path), {'repositories': []})
        path.write_text('{"repositories": [42]}')
        with self.assertRaises(ValueError):
            gp.read_config(path)
        gp.save_config(path, {'repositories': [str(self.repo)]})
        self.assertEqual(gp.read_config(path)['repositories'], [str(self.repo)])


    def setup_remote(self):
        self.commit()
        remote = self.base / 'remote.git'
        self.run_git('init', '--bare', str(remote))
        self.g('remote', 'add', 'origin', str(remote))
        self.g('push', '-u', 'origin', 'main')
        clone = self.base / 'clone'
        self.run_git('clone', '-b', 'main', str(remote), str(clone))
        self.run_git('-C', str(clone), 'config', 'user.name', 'Test')
        self.run_git('-C', str(clone), 'config', 'user.email', 'test@example.invalid')
        return clone

    def advance_remote(self, clone, filename):
        (clone / filename).write_text(filename)
        self.run_git('-C', str(clone), 'add', '.')
        self.run_git('-C', str(clone), 'commit', '-m', filename)
        self.run_git('-C', str(clone), 'push')

    def test_pull_fast_forward(self):
        clone = self.setup_remote()
        self.advance_remote(clone, 'incoming')
        gp.pull_repo(self.repo)
        self.assertTrue((self.repo / 'incoming').exists())
        self.assertEqual(gp.status(self.repo)['behind'], 0)

    def test_pull_refuses_dirty_and_diverged(self):
        clone = self.setup_remote()
        self.advance_remote(clone, 'incoming')
        (self.repo / 'uncommitted').touch()
        head = self.g('rev-parse', 'HEAD')
        with self.assertRaisesRegex(ValueError, 'Commit or stash'):
            gp.pull_repo(self.repo)
        self.assertEqual(self.g('rev-parse', 'HEAD'), head)
        (self.repo / 'uncommitted').unlink()
        self.commit('local')
        head = self.g('rev-parse', 'HEAD')
        with self.assertRaisesRegex(ValueError, 'diverged'):
            gp.pull_repo(self.repo)
        self.assertEqual(self.g('rev-parse', 'HEAD'), head)
        self.assertFalse((self.repo / 'incoming').exists())

    def test_pull_refuses_detached_no_upstream_and_in_progress(self):
        self.commit()
        with self.assertRaisesRegex(ValueError, 'upstream'):
            gp.pull_repo(self.repo)
        self.g('checkout', '--detach')
        with self.assertRaisesRegex(ValueError, 'upstream'):
            gp.pull_repo(self.repo)
        self.g('checkout', 'main')
        self.g('branch', 'tracking')
        self.g('branch', '--set-upstream-to=tracking', 'main')
        (self.repo / '.git' / 'MERGE_HEAD').write_text(self.g('rev-parse', 'HEAD'))
        with self.assertRaisesRegex(ValueError, 'in-progress'):
            gp.pull_repo(self.repo)

    def test_monitor_fetch_and_persistent_notification_dedup(self):
        clone = self.setup_remote()
        self.advance_remote(clone, 'incoming')
        with patch.object(gp, 'notify', return_value=True) as notify:
            row, state = gp.monitor_repo(str(self.repo), {}, 300)
            self.assertEqual(row['behind'], 1)
            self.assertEqual(notify.call_count, 1)
            saved = self.base / 'state.json'
            gp.save_config(saved, state)
            with patch.object(gp, 'fetch_repo') as fetch:
                row, state = gp.monitor_repo(str(self.repo), gp.load_state(saved), 300)
                fetch.assert_not_called()
            self.assertEqual(notify.call_count, 1)
            self.advance_remote(clone, 'second')
            row, state = gp.monitor_repo(str(self.repo), state, 300, force=True)
            self.assertEqual(row['behind'], 2)
            self.assertEqual(notify.call_count, 2)
            gp.pull_repo(self.repo)
            row, state = gp.monitor_repo(str(self.repo), state, 300)
            self.assertNotIn('notified', state)

    def test_monitor_fetch_failure_preserves_local_status(self):
        self.setup_remote()
        with patch.object(gp, 'fetch_repo', side_effect=ValueError('Offline')):
            row, state = gp.monitor_repo(str(self.repo), {}, 300)
        self.assertEqual(row['fetch_error'], 'Offline')
        self.assertIsNone(row['error'])
        self.assertEqual(row['behind'], 0)
        with patch.object(gp, 'fetch_repo') as fetch:
            row, state = gp.monitor_repo(str(self.repo), state, 300)
            fetch.assert_not_called()
        self.assertEqual(row['fetch_error'], 'Offline')

    def test_muted_notifications_wait_until_resumed_and_keep_fetching(self):
        clone = self.setup_remote()
        self.advance_remote(clone, 'incoming')
        config = {'repositories': [str(self.repo)], 'notifications': False}
        with patch.object(gp, 'notify', return_value=True) as notify:
            row, state = gp.monitor_repo(str(self.repo), {}, 300, config=config)
            self.assertEqual(row['behind'], 1)
            self.assertEqual(row['notification_status'], 'Muted globally')
            self.assertIsNotNone(row['fetched'])
            notify.assert_not_called()
            self.assertNotIn('notified', state)
            config['notifications'] = True
            row, state = gp.monitor_repo(str(self.repo), state, 300, config=config)
            self.assertEqual(notify.call_count, 1)
            gp.monitor_repo(str(self.repo), state, 300, config=config)
            self.assertEqual(notify.call_count, 1)

    def test_per_repo_fetch_interval_and_mute(self):
        path = str(self.repo)
        self.setup_remote()
        config = {'repositories': [path], 'fetch_interval': 300,
                  'repository_settings': {path: {'fetch_interval': 900, 'notifications': False}}}
        saved = self.base / 'monitor.json'
        gp.save_config(saved, {path: {'attempted': 1000, 'fetched': 1000}})
        with patch.object(gp.time, 'time', return_value=1400), patch.object(gp, 'fetch_repo') as fetch:
            row = gp.monitor(config, saved)[0]
            fetch.assert_not_called()
            self.assertEqual(row['notification_status'], 'Muted')
            self.assertEqual(row['settings']['fetch_interval'], 900)
            gp.monitor(config, saved, force=True)
            fetch.assert_called_once_with(path)


if __name__ == '__main__':
    unittest.main()
