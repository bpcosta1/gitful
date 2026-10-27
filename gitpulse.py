#!/usr/bin/env python3
"""GitPulse: Git status, remote monitoring, and an Omarchy bar menu."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager

ROOT = Path(__file__).resolve().parent
DEFAULT_CONFIG = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'gitpulse' / 'config.json'


def git(path, *args, timeout=10):
    result = subprocess.run(['git', '-C', str(path), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout,
                            env={**os.environ, 'GIT_OPTIONAL_LOCKS': '0', 'LC_ALL': 'C', 'GIT_TERMINAL_PROMPT': '0',
                                 'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes -o ConnectTimeout=10'})
    if result.returncode:
        raise ValueError(result.stderr.decode(errors='replace').strip() or 'Git command failed')
    return result.stdout.decode(errors='replace')


def status(path):
    path = Path(path).expanduser()
    row = dict(name=path.name, path=str(path), branch=None, dirty=False,
               changed=0, ahead=None, behind=None, upstream=None, detached=False, error=None, incoming_revision=None)
    try:
        if git(path, 'rev-parse', '--is-inside-work-tree').strip() != 'true':
            raise ValueError('Not a Git working tree')
        entries = iter(git(path, 'status', '--porcelain=v2', '--branch', '-z', '--untracked-files=normal').split('\0'))
        oid = ''
        for entry in entries:
            if entry.startswith('# branch.head '):
                row['branch'] = entry[14:]
            elif entry.startswith('# branch.oid '):
                oid = entry[13:]
            elif entry.startswith('# branch.upstream '):
                row['upstream'] = entry[18:]
            elif entry.startswith('# branch.ab '):
                ahead, behind = entry[12:].split()
                row.update(ahead=int(ahead[1:]), behind=int(behind[1:]))
            elif entry.startswith(('1 ', '2 ', 'u ', '? ')):
                row['changed'] += 1
                if entry.startswith('2 '):
                    next(entries, None)  # original rename path is a separate NUL field
        if row['upstream'] and row['behind']:
            row['incoming_revision'] = git(path, 'rev-parse', '@{upstream}').strip()
        row['dirty'] = row['changed'] > 0
        if row['branch'] == '(detached)':
            row.update(detached=True, branch='detached · ' + oid[:8])
    except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
        row['error'] = str(exc)
    return row


def read_config(path):
    if not path.exists():
        return {'repositories': []}
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or not isinstance(data.get('repositories'), list) or not all(isinstance(p, str) for p in data['repositories']):
        raise ValueError('Config must contain a repositories array of path strings')
    return data


def save_config(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as file:
        json.dump(data, file, indent=2)
        file.write('\n')
    os.replace(file.name, path)


def move_repository(config, path, placement, target):
    paths = list(config['repositories'])
    resolved = [Path(p).expanduser().resolve() for p in paths]
    source = Path(path).expanduser().resolve()
    destination = Path(target).expanduser().resolve()
    if source not in resolved or destination not in resolved:
        raise ValueError('Both repositories must still be tracked. Refresh the list and try again.')
    if source == destination:
        raise ValueError('Choose a different repository to move next to.')
    entry = paths.pop(resolved.index(source))
    resolved.remove(source)
    index = resolved.index(destination) + (placement == 'after')
    paths.insert(index, entry)
    config['repositories'] = paths


FETCH_INTERVAL = 300
PLUGIN_ID = 'bpc0sta.gitpulse'
STATE_HOME = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'gitpulse'


@contextmanager
def locked(config_path):
    STATE_HOME.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(str(config_path.resolve()).encode()).hexdigest()[:20]
    state_path = STATE_HOME / (key + '.json')
    with (STATE_HOME / (key + '.lock')).open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield state_path


def load_state(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def fetch_repo(path):
    branch = git(path, 'symbolic-ref', '--quiet', '--short', 'HEAD').strip()
    remote = git(path, 'config', '--get', 'branch.' + branch + '.remote').strip()
    if remote != '.':
        git(path, 'fetch', '--quiet', '--', remote, timeout=45)


def notify(row):
    if not shutil.which('notify-send'):
        return False
    body = html.escape(f"{row['name']} · {row['branch']}: {row['behind']} incoming commit(s). Open GitPulse in the bar to pull.")
    result = subprocess.run(['notify-send', '--app-name=GitPulse', '--icon=git',
                             'GitPulse — incoming changes', body], timeout=10,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0


def monitor_repo(path, previous, interval, force=False):
    previous = dict(previous)
    row = status(path)
    now = time.time()
    if not row['error'] and row['upstream'] and (force or now - previous.get('attempted', 0) >= interval):
        previous['attempted'] = now
        try:
            fetch_repo(path)
            previous.update(fetched=now, fetch_error=None)
        except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
            previous['fetch_error'] = str(exc)
        row = status(path)
    row['fetch_error'] = previous.get('fetch_error') if row['upstream'] else None
    row['fetched'] = previous.get('fetched') if row['upstream'] else None
    signature = [row['branch'], row['upstream'], row['incoming_revision']]
    if not row['error']:
        if row['behind'] and signature != previous.get('notified'):
            try:
                if notify(row):
                    previous['notified'] = signature
            except (OSError, subprocess.TimeoutExpired):
                pass
        elif row['behind'] == 0 or not row['upstream']:
            previous.pop('notified', None)
    return row, previous


def monitor(config, state_path, force=False):
    state = load_state(state_path)
    interval = max(60, int(config.get('fetch_interval', FETCH_INTERVAL)))
    paths = list(dict.fromkeys(config['repositories']))
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda p: monitor_repo(p, state.get(p, {}), interval, force), paths))
    save_config(state_path, {p: result[1] for p, result in zip(paths, results)})
    return [result[0] for result in results]


def pull_repo(path):
    row = status(path)
    if row['error']:
        raise ValueError(row['error'])
    if row['dirty']:
        raise ValueError('Commit or stash your changes before pulling.')
    if row['detached'] or not row['upstream']:
        raise ValueError('Check out a branch with an upstream before pulling.')
    for marker in ('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply', 'sequencer', 'BISECT_LOG'):
        marker_path = git(path, 'rev-parse', '--git-path', marker).strip()
        if not Path(marker_path).is_absolute():
            marker_path = Path(path) / marker_path
        if Path(marker_path).exists():
            raise ValueError('Finish the in-progress Git operation before pulling.')
    fetch_repo(path)
    row = status(path)
    if row['error'] or row['dirty']:
        raise ValueError(row['error'] or 'Working tree changed during fetch. Try again when clean.')
    if row['ahead'] and row['behind']:
        raise ValueError('Branches have diverged. Reconcile them in your Git client.')
    # No automatic stash, merge commit, or rebase. Git also rechecks the working tree.
    return git(path, '-c', 'merge.autoStash=false', 'merge', '--ff-only', '--no-edit', '@{upstream}', timeout=60).strip()


def install():
    destination = DEFAULT_CONFIG.parent.parent / 'omarchy/plugins' / PLUGIN_ID
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('manifest.json', 'Widget.qml', 'gitpulse.py'):
        if (ROOT / name).resolve() != (destination / name).resolve():
            shutil.copy2(ROOT / name, destination / name)
    shell_config = DEFAULT_CONFIG.parent.parent / 'omarchy/shell.json'
    if shell_config.exists():
        shutil.copy2(shell_config, shell_config.with_name('shell.json.gitpulse-backup-' + str(time.time_ns())))
    subprocess.run(['omarchy-shell', 'shell', 'rescanPlugins'], check=True)
    subprocess.run(['omarchy', 'plugin', 'enable', PLUGIN_ID], check=True)
    print('Installed GitPulse in the Omarchy bar.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('status', help='JSON status from local refs, without fetching')
    monitoring = commands.add_parser('monitor', help='Refresh upstreams when due and notify on new incoming commits')
    monitoring.add_argument('--fetch', action='store_true', help='Fetch now, ignoring the interval')
    commands.add_parser('list', help='List tracked paths')
    for action in ('add', 'remove'):
        commands.add_parser(action).add_argument('paths', nargs='+')
    moving = commands.add_parser('move', help='Move a tracked repository before or after another')
    moving.add_argument('path')
    moving.add_argument('placement', choices=('before', 'after'))
    moving.add_argument('target')
    commands.add_parser('pull', help='Fetch and fast-forward a clean tracked repository').add_argument('path')
    commands.add_parser('install', help='Install/update and enable the Omarchy widget')
    commands.add_parser('open', help='Open the bar menu')
    commands.add_parser('toggle', help='Toggle the bar menu')
    args = parser.parse_args()
    args.config = args.config.expanduser()
    try:
        if args.action == 'install':
            install()
            return 0
        if args.action in ('open', 'toggle'):
            if args.config.resolve() != DEFAULT_CONFIG.resolve():
                raise ValueError('The bar uses the default config; --config is for CLI operations only.')
            subprocess.run(['omarchy-shell', PLUGIN_ID, args.action], check=True)
            return 0
        with locked(args.config) as state_path:
            config = read_config(args.config)
            if args.action in ('status', 'monitor'):
                if args.action == 'monitor':
                    rows = monitor(config, state_path, args.fetch)
                else:
                    with ThreadPoolExecutor(max_workers=8) as pool:
                        rows = list(pool.map(status, config['repositories']))
                print(json.dumps({'repositories': rows, 'updated': datetime.now(timezone.utc).isoformat(), 'error': None}))
            elif args.action == 'list':
                print('\n'.join(config['repositories']))
            elif args.action == 'move':
                move_repository(config, args.path, args.placement, args.target)
                save_config(args.config, config)
                print(json.dumps({'ok': True, 'message': 'Repository order saved.',
                                  'order': [str(Path(p).expanduser()) for p in config['repositories']]}))
            elif args.action == 'pull':
                path = str(Path(args.path).expanduser().resolve())
                if path not in [str(Path(p).expanduser().resolve()) for p in config['repositories']]:
                    raise ValueError('Repository is not tracked by GitPulse.')
                print(json.dumps({'ok': True, 'message': pull_repo(path)}))
            else:
                paths = [str(Path(p).expanduser().resolve()) for p in args.paths]
                if args.action == 'add':
                    paths = [git(p, 'rev-parse', '--show-toplevel').strip() for p in paths]
                    config['repositories'] = list(dict.fromkeys(config['repositories'] + paths))
                else:
                    config['repositories'] = [p for p in config['repositories'] if str(Path(p).expanduser().resolve()) not in paths]
                save_config(args.config, config)
                print(json.dumps({'ok': True, 'message': 'Repository list updated.'}))
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        if args.action in ('status', 'monitor'):
            print(json.dumps({'repositories': [], 'updated': None, 'error': str(exc)}))
        elif args.action in ('pull', 'add', 'remove', 'move'):
            print(json.dumps({'ok': False, 'error': str(exc)}))
        else:
            print(f'gitpulse: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
