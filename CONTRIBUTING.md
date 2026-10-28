# Contributing

Thanks for helping improve Codex Cleaner. Issues and pull requests are welcome. Please use English or Simplified Chinese and keep reports focused on the app, not on private session contents.

## Before opening an issue

- Search existing issues for the same behavior.
- Include your macOS version, Mac architecture (`arm64` or `x86_64`), app version/build, and concise reproduction steps.
- Describe the observed and expected behavior. Remove usernames, home-directory paths, session IDs, project names, and prompt text from screenshots and logs.
- Do not attach Codex databases, rollout files, manifests from real cleanup operations, or unredacted logs.

For security vulnerabilities, use [private vulnerability reporting](https://github.com/KaranocaVe/codex-cleaner/security/advisories/new), not a public issue.

## Development setup

Requirements: macOS 14 or later, Xcode Command Line Tools, and Swift 6.0 or later. There are no Swift package dependencies. `zstd` is optional and only needed for tests or previews involving compressed `.jsonl.zst` files.

```sh
swift test
./build-app.sh
```

The default tests use isolated fixtures. Do not enable `CODEX_CLEANER_TEST_REAL_DATA=1` unless you have explicitly decided to read the local Codex cache; those opt-in tests are read-only. Never test destructive cleanup against a live Codex data directory. Use disposable fixtures and temporary roots.

The optional `scripts/extract-real-fixture.py` utility exports selected records from a real local Codex cache into a new destination. Its output contains private source data; do not run it for routine testing, and never attach an export to an issue or pull request.

## Pull requests

- Keep changes scoped and explain the user-visible behavior or bug being addressed.
- Add or update isolated tests for behavior changes where practical.
- Run `swift test` and report the result. If a check cannot run, say why.
- For UI changes, include a screenshot made from synthetic or otherwise non-private data.
- Update user documentation when behavior, supported macOS versions, cleanup semantics, or build instructions change.
- Do not add private databases, rollouts, QA logs, generated app bundles, or machine-specific paths to commits.

By submitting a contribution, you agree that it may be distributed under the repository's MIT License.
