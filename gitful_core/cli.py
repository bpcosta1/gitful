"""Command line interface shared by desktop clients."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys

from . import core


SCHEMA_VERSION = 1


def emit(payload):
    print(json.dumps({'schema_version': SCHEMA_VERSION, **payload}))


def main(argv=None, platform='generic'):
    parser = argparse.ArgumentParser(prog='gitful', description='Git status and development shortcuts')
    parser.add_argument('--config', type=Path, default=core.DEFAULT_CONFIG)
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('status', help='JSON status from local refs, without fetching')
    commands.add_parser('applications', help='Detect installed application launchers')
    monitoring = commands.add_parser('monitor', help='Refresh upstreams when due and notify on new incoming commits')
    monitoring.add_argument('--fetch', action='store_true', help='Fetch now, ignoring the interval')
    monitoring.add_argument('--startup', action='store_true', help='Fetch on startup when enabled')
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
    launching.add_argument('kind', choices=('editor', 'files', 'agent', 'terminal'))
    testing = commands.add_parser('test-launch', help='Test an application command')
    testing.add_argument('kind', choices=('editor', 'files', 'agent'))
    testing.add_argument('command')
    testing.add_argument('--repo')
    preferences = commands.add_parser('settings', help='View or update global or repository preferences')
    preferences.add_argument('--repo')
    preferences.add_argument('--set', dest='changes', help='JSON object with preference changes')
    if platform == 'omarchy':
        commands.add_parser('install', help='Install/update and enable the Omarchy widget')
        commands.add_parser('open', help='Open the Omarchy bar menu')
        commands.add_parser('toggle', help='Toggle the Omarchy bar menu')
    args = parser.parse_args(argv)
    args.config = args.config.expanduser()
    try:
        if args.action == 'install':
            from .omarchy import install
            install()
            return 0
        if args.action in ('open', 'toggle'):
            if args.config.resolve() != core.DEFAULT_CONFIG.resolve():
                raise ValueError('The bar uses the default config; --config is for CLI operations only.')
            subprocess.run(['omarchy-shell', 'bpc0sta.gitful', args.action], check=True)
            return 0
        with core.locked(args.config) as state_path:
            config = core.read_config(args.config)
            if args.action in ('status', 'monitor'):
                if args.action == 'monitor':
                    rows = core.monitor(config, state_path, args.fetch, args.startup)
                else:
                    with ThreadPoolExecutor(max_workers=8) as pool:
                        rows = list(pool.map(core.status, config['repositories']))
                emit({'repositories': rows, 'preferences': core.preferences_view(config),
                      'updated': datetime.now(timezone.utc).isoformat(), 'error': None})
            elif args.action == 'applications':
                emit({'applications': core.detect_applications()})
            elif args.action == 'list':
                print('\n'.join(config['repositories']))
            elif args.action == 'settings':
                path = core.tracked_path(config, args.repo) if args.repo else None
                if args.changes is not None:
                    core.update_preferences(config, json.loads(args.changes), path)
                    core.save_config(args.config, config)
                emit({'ok': True, 'message': 'Settings saved.' if args.changes is not None else 'Settings loaded.',
                      'preferences': core.preferences_view(config, path)})
            elif args.action == 'launch':
                emit({'ok': True, 'message': core.launch_repository(config, args.path, args.kind, platform)})
            elif args.action == 'test-launch':
                emit({'ok': True, 'message': core.test_application(config, args.kind, args.command, args.repo, platform)})
            elif args.action == 'move':
                core.move_repository(config, args.path, args.placement, args.target)
                core.save_config(args.config, config)
                emit({'ok': True, 'message': 'Repository order saved.',
                      'order': [str(Path(p).expanduser()) for p in config['repositories']]})
            elif args.action == 'pull':
                path = str(Path(args.path).expanduser().resolve())
                if path not in [str(Path(p).expanduser().resolve()) for p in config['repositories']]:
                    raise ValueError('Repository is not tracked by Gitful.')
                emit({'ok': True, 'message': core.pull_repo(path)})
            else:
                paths = [str(Path(p).expanduser().resolve()) for p in args.paths]
                if args.action == 'add':
                    paths = [core.git(p, 'rev-parse', '--show-toplevel').strip() for p in paths]
                    config['repositories'] = list(dict.fromkeys(config['repositories'] + paths))
                else:
                    config['repositories'] = [p for p in config['repositories'] if str(Path(p).expanduser().resolve()) not in paths]
                    for path in paths:
                        config.get('repository_settings', {}).pop(path, None)
                core.save_config(args.config, config)
                emit({'ok': True, 'message': 'Repository list updated.'})
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        if args.action in ('status', 'monitor'):
            emit({'repositories': [], 'updated': None, 'error': str(exc)})
        elif args.action == 'applications':
            emit({'applications': [], 'error': str(exc)})
        elif args.action in ('pull', 'add', 'remove', 'move', 'settings', 'launch', 'test-launch'):
            emit({'ok': False, 'error': str(exc)})
        else:
            print(f'gitful: {exc}', file=sys.stderr)
        return 1
    return 0
