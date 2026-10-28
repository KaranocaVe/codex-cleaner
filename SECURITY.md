# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities through [GitHub private vulnerability reporting](https://github.com/KaranocaVe/codex-cleaner/security/advisories/new). Do not disclose a vulnerability in a public issue before maintainers have had a chance to assess it.

Do not include real Codex databases, rollout files, session text, access tokens, or unredacted logs in a report. A concise description, affected version, impact, and reproduction using synthetic data are usually sufficient.

There is no security contact email. Use the private reporting link above.

## Supported versions

Security fixes are currently provided for the latest published release. Users should upgrade to the latest release when one is available.

## Scope and data handling

Codex Cleaner reads local Codex SQLite databases and rollout files. It does not need a network connection for its core functionality. Cleanup changes local databases and moves selected rollout files to the Codex Trash directory. The app does not create database backups; committed index deletions cannot be undone in the app. See [Cleanup and recovery boundaries](docs/cleanup-and-recovery.md).
