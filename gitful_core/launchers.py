"""Desktop-specific defaults for repository actions."""

import subprocess


def default_command(kind, path, platform):
    if kind == 'files':
        return ['xdg-open', '{path}']
    if kind == 'terminal':
        return ['xdg-terminal-exec', '--dir=' + path]
    if platform == 'omarchy':
        if kind == 'editor':
            return ['omarchy', 'launch', 'editor', '{path}']
        if kind == 'agent':
            result = subprocess.run(['omarchy', 'default', 'agent'], capture_output=True, text=True, timeout=5)
            agent = result.stdout.strip()
            if result.returncode or not agent:
                raise ValueError('Choose a coding agent in Omarchy defaults or Gitful settings first.')
            return [agent]
    if kind == 'editor':
        raise ValueError('Choose an editor in Gitful settings first.')
    if kind == 'agent':
        raise ValueError('Choose a coding agent in Gitful settings first.')
    raise ValueError('Unknown repository action')
