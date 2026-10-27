#!/usr/bin/env python3
"""Compatibility entry point for the Omarchy plugin."""

from gitful_core.cli import main as cli_main


def main():
    return cli_main(platform='omarchy')


if __name__ == '__main__':
    raise SystemExit(main())
