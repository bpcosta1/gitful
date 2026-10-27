"""Omarchy plugin installation."""

from pathlib import Path
import shutil
import subprocess
import time

from .core import DEFAULT_CONFIG


PLUGIN_ID = 'bpc0sta.gitful'
ROOT = Path(__file__).resolve().parent.parent


def install():
    destination = DEFAULT_CONFIG.parent.parent / 'omarchy/plugins' / PLUGIN_ID
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('manifest.json', 'Widget.qml', 'SettingsForm.qml', 'gitful.py', 'gitful'):
        source = ROOT / name
        target = destination / name
        if source.resolve() != target.resolve():
            shutil.copy2(source, target)
    package_destination = destination / 'gitful_core'
    source_package = ROOT / 'gitful_core'
    if source_package.resolve() != package_destination.resolve():
        shutil.copytree(source_package, package_destination, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    shell_config = DEFAULT_CONFIG.parent.parent / 'omarchy/shell.json'
    if shell_config.exists():
        shutil.copy2(shell_config, shell_config.with_name('shell.json.gitful-backup-' + str(time.time_ns())))
    subprocess.run(['omarchy-shell', 'shell', 'rescanPlugins'], check=True)
    subprocess.run(['omarchy', 'plugin', 'enable', PLUGIN_ID], check=True)
    print('Installed Gitful in the Omarchy bar.')
