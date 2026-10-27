# GitPulse

A Python + Quickshell widget for the Omarchy topbar. It keeps track of selected Git repositories while its menu is closed, alerts you to incoming commits, and lets you pull from the menu. Colors, fonts, borders, and popup placement use Omarchy's live system theme.

## Use

Click the Git icon in the right side of the bar. Its badge shows the total incoming commit count, or `!` when a repository or fetch needs attention.

- **Track**: enter a local repository path, such as `~/dev/project`.
- **Untrack**: remove a repository from the list; its files are kept.
- **↑ / ↓ beside each repository name**: move it up or down. The order is saved immediately and persists across restarts. When filtering, it moves relative to the next visible repository.
- **Fetch now**: check upstreams immediately and refresh all statuses.
- **Pull**: fetch the selected branch's remote, then fast-forward to its upstream.
- Filter by repository name, path, or branch. Close with Escape, the × button, or an outside click.

The menu shows branch, upstream, dirty entry count, and commits ahead/behind. GitPulse refuses to pull dirty trees, detached HEADs, branches without upstreams, diverged branches, and repositories with an ongoing merge/rebase/cherry-pick/bisect. It never automatically stashes, rebases, or creates merge commits. Git failures are shown in the menu.

## Background checks and notifications

Local status is checked every 15 seconds while the widget is enabled, including with the menu closed. Each tracked branch's configured remote is fetched at startup and then every five minutes. This updates local refs; only an explicit **Pull** changes working files.

Incoming commits generate a desktop notification. The upstream revision is remembered on disk so polling, multiple bar instances, or restarting the shell does not repeatedly notify for the same incoming revision. Existing unpulled commits are reported on the first scan too. After catching up, the notification state resets.

Network or authentication failures retain locally known counts and display a fetch error. Fetches use existing Git credentials with interactive prompts disabled and SSH batch mode enabled. Fix authentication in your terminal if needed. Repositories without upstreams are not fetched. Disabled widgets do not monitor repositories.

## Install or update

Requires an Omarchy version with the Quickshell plugin API, Python 3.10+, Git, and `notify-send`. No Python dependencies are needed.

```sh
cd ~/dev/gitpulse
./gitpulse install
./gitpulse add ~/dev/my-project
./gitpulse open
```

The installer copies the plugin into `~/.config/omarchy/plugins/bpc0sta.gitpulse`, backs up `shell.json`, and enables the widget in the right bar section. Re-run it after source changes. If Quickshell retains an old component after an update, `omarchy restart shell` reloads it. Move the widget with the standard Omarchy bar settings.

```sh
./gitpulse toggle
./gitpulse list
./gitpulse remove ~/dev/my-project
./gitpulse move ~/dev/my-project before ~/dev/another-project
./gitpulse status            # Local JSON snapshot; no fetch or notifications
./gitpulse monitor           # Fetch if due, notify, emit JSON
./gitpulse monitor --fetch   # Fetch immediately, notify, emit JSON
./gitpulse pull ~/dev/my-project
omarchy plugin disable bpc0sta.gitpulse
```

`open` and `toggle` control the installed bar widget. There is no separate popup process or daemon to start. Shell startup loads the enabled widget automatically.

## Configuration

`~/.config/gitpulse/config.json` (or `$XDG_CONFIG_HOME/gitpulse/config.json`):

```json
{
  "repositories": ["/home/you/dev/project"],
  "fetch_interval": 300
}
```

`fetch_interval` is seconds (minimum 60, default 300). Configuration is reread on every scan. The CLI supports `--config /path/to/config.json` before commands for separate repository lists; the installed bar always uses the default config. Notification and fetch state lives under `$XDG_STATE_HOME/gitpulse`, normally `~/.local/state/gitpulse`.

Dirty means staged, unstaged, untracked, or conflicted entries; ignored files are excluded. Untracked directories can count as one entry. No upstream is shown as unavailable, not zero. Unborn branches and linked worktrees are supported; bare repositories are not working trees.

Scans use up to eight concurrent workers. Actions and monitor runs for the same configuration are serialized across bar instances. Git read commands time out after ten seconds, fetches after 45 seconds, and fast-forward operations after 60 seconds. A slow remote delays the complete snapshot; the UI remains responsive.

## Development

```sh
python3 -m unittest discover -s tests -v
./gitpulse install
```

- `gitpulse.py`: status collection, periodic fetches, notification deduplication, pull guards, CLI, installer.
- `Widget.qml`: native Omarchy bar icon and themed repository menu.
- `manifest.json`: Omarchy plugin registration.
- `gitpulse`: launcher resolving its own directory.

Tests use temporary local remotes to verify divergence, fast-forward pulls, refusal of unsafe pulls, fetch scheduling/failure, persistent notification deduplication, worktrees, and Git status edge cases.
