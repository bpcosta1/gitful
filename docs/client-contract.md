# Gitful client contract (schema version 1)

Desktop clients call the installed `gitful` command. The Omarchy plugin's `gitful.py` is a compatibility entry point for the same shared CLI and adds only `install`, `open`, and `toggle`. Run subprocesses with an argument array, not through a shell. Read one JSON object from stdout after the process exits. A zero exit code means success; errors return a nonzero exit code and a JSON object for all JSON commands.

## Installation and ownership

Install the Python package from this repository with `python3 -m pip install .` (or `pipx install .` for a user-facing CLI). The wheel provides the `gitful` executable and `gitful_core` package; it does not install a desktop client. The Omarchy plugin copies the package alongside `gitful.py` so its existing installation works without a separate Python package install.

Both clients use `$XDG_CONFIG_HOME/gitful/config.json` (default `~/.config/gitful/config.json`) and `$XDG_STATE_HOME/gitful` (default `~/.local/state/gitful`). The helper serializes actions and monitor runs for a configuration with a file lock. Clients should use the CLI to change configuration and should not edit its JSON file directly. Running two clients is supported; each client controls its own refresh timer, while monitor state and notification deduplication are shared. Avoid calling `monitor --startup` repeatedly: it forces a fetch when startup fetching is enabled.

## Snapshot commands

`gitful status` returns a local snapshot. It does not fetch, notify, or change working files. `gitful monitor` returns the same shape, fetches upstreams when due, and may send desktop notifications. `gitful monitor --fetch` forces a fetch; `gitful monitor --startup` follows the configured startup-fetch preference. A normal client can call `monitor --startup` once when enabled, then `monitor` every 15 seconds. For a menu-open refresh that must avoid network activity, use `status`.

Successful snapshot shape:

```json
{
  "schema_version": 1,
  "repositories": [{
    "name": "project", "path": "/home/user/dev/project", "branch": "main",
    "dirty": false, "changed": 0, "staged": 0, "unstaged": 0,
    "untracked": 0, "conflicts": 0, "stashes": 0, "operation": null,
    "ahead": 0, "behind": 0, "upstream": "origin/main",
    "detached": false, "error": null, "incoming_revision": null,
    "fetch_error": null, "fetched": 1793142000.0, "stale": false,
    "settings": {}, "notification_status": "On"
  }],
  "preferences": {}, "updated": "2026-10-27T22:00:00+00:00", "error": null
}
```

`status` rows contain the fields through `incoming_revision`; `monitor` adds `fetch_error`, `fetched`, `stale`, `settings`, and `notification_status`. Counts are integers. `ahead` and `behind` are `null` when no upstream count is available, so `null` must not be treated as zero. `fetched` is a Unix timestamp or `null`. A repository problem appears in that row's `error`; a top-level failure returns `repositories: []`, `updated: null`, and a nonempty top-level `error` with exit code 1. Clients should preserve and show the last good snapshot if a later scan fails.

## Actions and settings

| Command | Effect | Success payload beyond `schema_version` |
| --- | --- | --- |
| `add PATH [PATH...]` | Validate and track repositories | `ok`, `message` |
| `remove PATH [PATH...]` | Untrack; leave files untouched | `ok`, `message` |
| `move PATH before\|after TARGET` | Reorder tracked repositories | `ok`, `message`, `order` |
| `pull PATH` | Fetch and fast-forward a clean tracked branch | `ok`, `message` |
| `launch PATH editor\|files\|agent\|terminal` | Start a configured application | `ok`, `message` |
| `test-launch KIND COMMAND [--repo PATH]` | Start a test application | `ok`, `message` |
| `settings [--repo PATH]` | Read effective preferences | `ok`, `message`, `preferences` |
| `settings [--repo PATH] --set JSON` | Validate and save a preference object | `ok`, `message`, `preferences` |
| `applications` | Detect installed app candidates | `applications` |

Action failures return `{"schema_version":1,"ok":false,"error":"..."}` and exit code 1. After a successful action, call `status` or `monitor` for a new snapshot. `list` is the one plain-text command; it prints one tracked path per line. The optional global `--config PATH` argument goes before the command and is for isolated CLI use; desktop clients should use the default configuration.

`pull` refuses dirty trees, detached branches, branches without upstreams, diverged branches, and ongoing Git operations. It never auto-stashes, rebases, or creates a merge commit. `launch` uses shared configured commands. The generic CLI has no implicit editor or coding-agent choice; ask the user to configure one. The Omarchy wrapper retains Omarchy defaults. The default file action uses `xdg-open`, and terminal and agent actions need `xdg-terminal-exec`.

When adding fields to a version 1 response, clients should ignore unknown keys. Do not remove or change a documented field's meaning without a new schema version. The contract tests in `tests/test_client_contract.py` verify both entry points and the source installer copy.
