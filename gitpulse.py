#!/usr/bin/env python3
"""Gitful: Git status, remote monitoring, and an Omarchy bar menu."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import shlex
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
               changed=0, staged=0, unstaged=0, untracked=0, conflicts=0, stashes=0, operation=None,
               ahead=None, behind=None, upstream=None, detached=False, error=None, incoming_revision=None)
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
                if entry.startswith('? '):
                    row['untracked'] += 1
                elif entry.startswith('u '):
                    row['conflicts'] += 1
                else:
                    row['staged'] += entry[2] != '.'
                    row['unstaged'] += entry[3] != '.'
                if entry.startswith('2 '):
                    next(entries, None)  # original rename path is a separate NUL field
        if row['upstream'] and row['behind']:
            row['incoming_revision'] = git(path, 'rev-parse', '@{upstream}').strip()
        row['dirty'] = row['changed'] > 0
        row['stashes'] = len(git(path, 'stash', 'list', '--format=%gd').splitlines())
        row['operation'] = current_operation(path)
        if row['branch'] == '(detached)':
            row.update(detached=True, branch='detached · ' + oid[:8])
    except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
        row['error'] = str(exc)
    return row


def current_operation(path):
    git_dir = Path(git(path, 'rev-parse', '--absolute-git-dir').strip())
    for marker, label in (('rebase-merge', 'Rebase'), ('rebase-apply', 'Rebase / apply'),
                          ('MERGE_HEAD', 'Merge'), ('CHERRY_PICK_HEAD', 'Cherry-pick'),
                          ('REVERT_HEAD', 'Revert'), ('sequencer', 'Sequencer'), ('BISECT_LOG', 'Bisect')):
        if (git_dir / marker).exists():
            return label
    return None


def read_config(path):
    if not path.exists():
        return {'repositories': []}
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or not isinstance(data.get('repositories'), list) or not all(isinstance(p, str) for p in data['repositories']):
        raise ValueError('Config must contain a repositories array of path strings')
    validate_preferences(data)
    overrides = data.get('repository_settings', {})
    if not isinstance(overrides, dict):
        raise ValueError('repository_settings must be an object')
    for options in overrides.values():
        validate_preferences(options, per_repo=True)
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
WORK_HOURS = {'enabled': False, 'start': '09:00', 'end': '18:00', 'weekdays': [0, 1, 2, 3, 4]}


def validate_preferences(options, per_repo=False):
    if not isinstance(options, dict):
        raise ValueError('Preferences must be an object')
    if 'notifications' in options and not isinstance(options['notifications'], bool):
        raise ValueError('notifications must be true or false')
    if 'fetch_interval' in options:
        value = options['fetch_interval']
        if type(value) is not int or not 60 <= value <= 86400:
            raise ValueError('fetch_interval must be an integer between 60 and 86400 seconds')
    if 'snoozed_until' in options:
        value = options['snoozed_until']
        if type(value) not in (int, float) or not 0 <= value <= 253402300799:
            raise ValueError('snoozed_until must be a nonnegative Unix timestamp')
    if 'launchers' in options:
        launchers = options['launchers']
        if not isinstance(launchers, dict) or set(launchers) - {'editor', 'files', 'agent'}:
            raise ValueError('launchers supports editor, files, and agent command arrays')
        for command in launchers.values():
            if not isinstance(command, list) or not command or not all(isinstance(p, str) and p and '\0' not in p for p in command):
                raise ValueError('Each launcher must be a nonempty array of command arguments')
    if 'work_hours' in options:
        if per_repo:
            raise ValueError('Work hours are a global preference')
        hours = options['work_hours']
        if not isinstance(hours, dict) or set(hours) - set(WORK_HOURS):
            raise ValueError('Invalid work_hours preferences')
        hours = {**WORK_HOURS, **hours}
        if not isinstance(hours['enabled'], bool):
            raise ValueError('Work hours enabled must be true or false')
        for key in ('start', 'end'):
            value = hours[key]
            try:
                parsed = datetime.strptime(value, '%H:%M')
                if parsed.strftime('%H:%M') != value:
                    raise ValueError()
            except (TypeError, ValueError):
                raise ValueError('Work hours must use HH:MM (24 hour time)') from None
        days = hours['weekdays']
        if not isinstance(days, list) or not days or not all(type(d) is int and 0 <= d <= 6 for d in days):
            raise ValueError('Workdays must contain weekday numbers from 0 (Monday) to 6 (Sunday)')


def repo_options(config, path):
    key = str(Path(path).expanduser().resolve())
    return config.get('repository_settings', {}).get(key, {})


def work_hours_allow(hours, now):
    hours = {**WORK_HOURS, **hours}
    if not hours['enabled']:
        return True
    local = datetime.fromtimestamp(now)
    current = local.hour * 60 + local.minute
    start, end = [int(value[:2]) * 60 + int(value[3:]) for value in (hours['start'], hours['end'])]
    weekday = local.weekday()
    if start < end:
        return weekday in hours['weekdays'] and start <= current < end
    if start == end:
        return weekday in hours['weekdays']
    # Overnight periods belong to the day on which the work period started.
    return ((current >= start and weekday in hours['weekdays']) or
            (current < end and (weekday - 1) % 7 in hours['weekdays']))


def notification_status(config, options, now):
    if not config.get('notifications', True):
        return 'Muted globally'
    if not options.get('notifications', True):
        return 'Muted'
    until = max(config.get('snoozed_until', 0), options.get('snoozed_until', 0))
    if until > now:
        return 'Snoozed until ' + datetime.fromtimestamp(until).strftime('%a %H:%M')
    if not work_hours_allow(config.get('work_hours', {}), now):
        return 'Outside work hours'
    return 'On'


def preferences_view(config, path=None):
    options = repo_options(config, path) if path else config
    return {
        'notifications': options.get('notifications', True),
        'snoozed_until': options.get('snoozed_until', 0),
        'fetch_interval': options.get('fetch_interval', config.get('fetch_interval', FETCH_INTERVAL)),
        'inherits_fetch_interval': bool(path) and 'fetch_interval' not in options,
        'work_hours': {**WORK_HOURS, **config.get('work_hours', {})},
        'launchers': {key: shlex.join(options.get('launchers', {}).get(key, [])) for key in ('editor', 'files', 'agent')},
    }


def tracked_path(config, path):
    resolved = str(Path(path).expanduser().resolve())
    if resolved not in [str(Path(p).expanduser().resolve()) for p in config['repositories']]:
        raise ValueError('Repository is not tracked by Gitful.')
    return resolved


def update_preferences(config, changes, path=None):
    if not isinstance(changes, dict):
        raise ValueError('Preference changes must be a JSON object')
    allowed = {'notifications', 'snoozed_until', 'snooze_minutes', 'fetch_interval', 'launchers'}
    if not path:
        allowed.add('work_hours')
    if set(changes) - allowed:
        raise ValueError('Unknown preferences: ' + ', '.join(sorted(set(changes) - allowed)))
    changes = dict(changes)
    if 'snooze_minutes' in changes:
        minutes = changes.pop('snooze_minutes')
        if type(minutes) is not int or not 0 <= minutes <= 10080:
            raise ValueError('Snooze must be between 0 and 10080 minutes')
        changes['snoozed_until'] = time.time() + minutes * 60 if minutes else 0
    options = dict(repo_options(config, path) if path else config)
    if 'launchers' in changes:
        launchers = dict(options.get('launchers', {}))
        commands = changes.pop('launchers')
        if not isinstance(commands, dict) or set(commands) - {'editor', 'files', 'agent'}:
            raise ValueError('Launcher names must be editor, files, or agent')
        for name, command in commands.items():
            if isinstance(command, str):
                command = shlex.split(command)
            if command == [] or command is None:
                launchers.pop(name, None)
            else:
                launchers[name] = command
        changes['launchers'] = launchers
    inherit_interval = bool(path) and changes.get('fetch_interval', False) is None
    if inherit_interval:
        changes.pop('fetch_interval')
        options.pop('fetch_interval', None)
    if 'work_hours' in changes and isinstance(changes['work_hours'], dict):
        changes['work_hours'] = {**WORK_HOURS, **options.get('work_hours', {}), **changes['work_hours']}
    options.update(changes)
    validate_preferences(options, per_repo=bool(path))
    if path:
        config.setdefault('repository_settings', {})[tracked_path(config, path)] = options
    else:
        config.update(options)


def launch_repository(config, path, kind):
    path = tracked_path(config, path)
    if not Path(path).is_dir():
        raise ValueError('Repository folder is unavailable')
    launchers = {**config.get('launchers', {}), **repo_options(config, path).get('launchers', {})}
    command = launchers.get(kind)
    if command is None:
        if kind == 'editor':
            command = ['omarchy', 'launch', 'editor', '{path}']
        elif kind == 'files':
            command = ['xdg-open', '{path}']
        else:
            result = subprocess.run(['omarchy', 'default', 'agent'], capture_output=True, text=True, timeout=5)
            agent = result.stdout.strip()
            if result.returncode or not agent:
                raise ValueError('Choose a coding agent in Omarchy defaults or Gitful settings first.')
            command = [agent]
    if not shutil.which(command[0]):
        raise ValueError('Application not found: ' + command[0])
    has_path = any('{path}' in part for part in command)
    command = [part.replace('{path}', path) for part in command]
    if kind == 'agent':
        command = ['xdg-terminal-exec', '--dir=' + path, *command]
    elif not has_path:
        command.append(path)
    if not shutil.which(command[0]):
        raise ValueError('Application not found: ' + command[0])
    subprocess.Popen(command, cwd=path, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    return 'Opened ' + {'editor': 'editor', 'files': 'file manager', 'agent': 'coding agent'}[kind]


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
    body = html.escape(f"{row['name']} · {row['branch']}: {row['behind']} incoming commit(s). Open Gitful in the bar to pull.")
    result = subprocess.run(['notify-send', '--app-name=Gitful', '--icon=git',
                             'Gitful - incoming changes', body], timeout=10,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0


def monitor_repo(path, previous, interval, force=False, config=None):
    config = config or {}
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
    row['settings'] = preferences_view(config, path)
    row['notification_status'] = notification_status(config, repo_options(config, path), now)
    row['stale'] = bool(row['upstream'] and (row['fetch_error'] or not row['fetched'] or now - row['fetched'] > interval * 2))
    signature = [row['branch'], row['upstream'], row['incoming_revision']]
    if not row['error']:
        if row['behind'] and signature != previous.get('notified') and row['notification_status'] == 'On':
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
        results = list(pool.map(lambda p: monitor_repo(
            p, state.get(p, {}), repo_options(config, p).get('fetch_interval', interval), force, config), paths))
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
    if row['operation']:
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
    for name in ('manifest.json', 'Widget.qml', 'SettingsForm.qml', 'gitpulse.py', 'gitful', 'gitpulse'):
        if (ROOT / name).resolve() != (destination / name).resolve():
            shutil.copy2(ROOT / name, destination / name)
    shell_config = DEFAULT_CONFIG.parent.parent / 'omarchy/shell.json'
    if shell_config.exists():
        shutil.copy2(shell_config, shell_config.with_name('shell.json.gitpulse-backup-' + str(time.time_ns())))
    subprocess.run(['omarchy-shell', 'shell', 'rescanPlugins'], check=True)
    subprocess.run(['omarchy', 'plugin', 'enable', PLUGIN_ID], check=True)
    print('Installed Gitful in the Omarchy bar.')


def main():
    parser = argparse.ArgumentParser(prog='gitful', description=__doc__)
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
    launching = commands.add_parser('launch', help='Open a repository in an application')
    launching.add_argument('path')
    launching.add_argument('kind', choices=('editor', 'files', 'agent'))
    preferences = commands.add_parser('settings', help='View or update global or repository preferences')
    preferences.add_argument('--repo')
    preferences.add_argument('--set', dest='changes', help='JSON object with preference changes')
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
                print(json.dumps({'repositories': rows, 'preferences': preferences_view(config),
                                  'updated': datetime.now(timezone.utc).isoformat(), 'error': None}))
            elif args.action == 'list':
                print('\n'.join(config['repositories']))
            elif args.action == 'settings':
                path = tracked_path(config, args.repo) if args.repo else None
                if args.changes is not None:
                    update_preferences(config, json.loads(args.changes), path)
                    save_config(args.config, config)
                print(json.dumps({'ok': True, 'message': 'Settings saved.' if args.changes is not None else 'Settings loaded.',
                                  'preferences': preferences_view(config, path)}))
            elif args.action == 'launch':
                print(json.dumps({'ok': True, 'message': launch_repository(config, args.path, args.kind)}))
            elif args.action == 'move':
                move_repository(config, args.path, args.placement, args.target)
                save_config(args.config, config)
                print(json.dumps({'ok': True, 'message': 'Repository order saved.',
                                  'order': [str(Path(p).expanduser()) for p in config['repositories']]}))
            elif args.action == 'pull':
                path = str(Path(args.path).expanduser().resolve())
                if path not in [str(Path(p).expanduser().resolve()) for p in config['repositories']]:
                    raise ValueError('Repository is not tracked by Gitful.')
                print(json.dumps({'ok': True, 'message': pull_repo(path)}))
            else:
                paths = [str(Path(p).expanduser().resolve()) for p in args.paths]
                if args.action == 'add':
                    paths = [git(p, 'rev-parse', '--show-toplevel').strip() for p in paths]
                    config['repositories'] = list(dict.fromkeys(config['repositories'] + paths))
                else:
                    config['repositories'] = [p for p in config['repositories'] if str(Path(p).expanduser().resolve()) not in paths]
                    for path in paths:
                        config.get('repository_settings', {}).pop(path, None)
                save_config(args.config, config)
                print(json.dumps({'ok': True, 'message': 'Repository list updated.'}))
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        if args.action in ('status', 'monitor'):
            print(json.dumps({'repositories': [], 'updated': None, 'error': str(exc)}))
        elif args.action in ('pull', 'add', 'remove', 'move', 'settings', 'launch'):
            print(json.dumps({'ok': False, 'error': str(exc)}))
        else:
            print(f'gitful: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
