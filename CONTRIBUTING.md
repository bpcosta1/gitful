# Contributing to Gitful

Thanks for helping improve Gitful. Fork the repository, create a branch in your fork, and open a pull request against `main`. Keep each PR focused on one change. For substantial changes to the shared CLI or its JSON interface, open an issue first so we can agree on the behavior.

## Run the tests

Gitful's Python code requires Python 3.10+ and Git. The tests use the standard library and temporary local Git repositories; they do not need network access or an Omarchy session.

```sh
python3 -m unittest discover -s tests -v
```

The CI workflow runs these tests on supported Python versions and checks that the Python package installs. If you change the shared CLI, run the tests before submitting your PR.

## Choose the right area

- Shared Git logic, configuration, and monitoring live in `gitful_core/`. Desktop clients consume the [client contract](docs/client-contract.md). Add or update a contract test in `tests/test_client_contract.py` when changing its commands or JSON responses, and document any contract change.
- The Omarchy widget lives in `Widget.qml` and `SettingsForm.qml`. The root `gitful.py` remains its compatibility entry point.
- GNOME work belongs in `gnome/`. Start with the [GNOME contributor handoff](gnome/README.md). Include the GNOME Shell version and installation method you tested in your PR. For UI changes, include a screenshot when it helps reviewers see the result.

In your PR description, explain what changed, why, and how you tested it. Mention any behavior you could not verify locally. Contributions are distributed under Gitful's [GPL-3.0-or-later license](LICENSE).
