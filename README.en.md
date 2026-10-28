# Codex Cleaner

[![CI](https://github.com/KaranocaVe/codex-cleaner/actions/workflows/ci.yml/badge.svg)](https://github.com/KaranocaVe/codex-cleaner/actions/workflows/ci.yml)
[简体中文](README.md)

Codex Cleaner is a native macOS app written in SwiftUI and AppKit for browsing, filtering, previewing, and cleaning up local Codex session indexes. It requires macOS 14 or later and Swift 6.0 or later. The current UI is in Simplified Chinese.

The project takes layout inspiration from [Neodisk](https://github.com/tkslucas/Neodisk)'s sidebar, list, and inspector. It is independently implemented and does not copy Neodisk code or assets. Codex Cleaner is a community project. It is **not an official OpenAI product and is not endorsed by OpenAI**.

![Conversation preview](docs/images/preview.png)

## Features

- Reads sessions from Codex state and history databases, with search and filters for project, status, date, model, and other metadata.
- Uses a native table with keyboard navigation, multi-selection, sorting, and project and parent-child session trees.
- Family-size totals in tree view include a parent and all descendants. Cascading cleanup shows descendants in the review scope.
- Reads rollout files on demand and previews user and assistant text. Previewing `.jsonl.zst` files can use an installed `zstd` command.
- Shows the final cleanup scope before acting. Cleanup moves matching rollout files into `Trash/CodexCleaner/` under the Codex directory and removes related session entries from five Codex SQLite databases.

## Install and build

Download an arm64 or x86_64 app package from [Releases](https://github.com/KaranocaVe/codex-cleaner/releases). Public release packages are ad-hoc signed; they are **not Developer ID signed or notarized by Apple**. macOS may show a first-launch warning. You can also build from source:

```sh
git clone https://github.com/KaranocaVe/codex-cleaner.git
cd codex-cleaner
./build-app.sh
open outputs/CodexCleaner.app
```

The script accepts `--arch arm64|x86_64` and `--output <path>`. You need Xcode Command Line Tools and Swift 6.0 or newer. The app reads the directory in `$CODEX_HOME`, or `~/.codex` when the variable is unset. Apps launched from Finder usually do not inherit terminal environment variables.

`zstd` is optional and only used to preview compressed rollouts. It is not required to build the app or browse uncompressed sessions. Install it with Homebrew using `brew install zstd`.

## Before cleanup

Cleanup is destructive. The app **does not back up databases**. It moves selected `.jsonl` / `.jsonl.zst` rollout files into the Codex Trash directory on the same disk, then removes related indexes, parent-child relations, history, logs, goals, queue entries, and read cursors from five SQLite databases. Existing unrelated orphan records are left alone.

Once the database transaction commits, the index deletion cannot be undone in the app; retained rollout files are not enough to restore the complete database state. Moving files to Trash does not free disk space, and the databases are not automatically vacuumed. On failure, the app attempts to roll back the database transaction and restore moved files, but commits across multiple WAL databases are not globally atomic in a power failure. Stop relevant sessions before cleanup and review the final scope carefully.

![Cleanup progress](docs/images/cleanup-progress.png)

See [Cleanup and recovery boundaries](docs/cleanup-and-recovery.md) for details.

## Tests

```sh
swift test
```

Version 0.2.3 has 39 tests. The default suite uses isolated temporary databases and files; three read-only checks against real data are skipped by default. Set `CODEX_CLEANER_TEST_REAL_DATA=1` only when you explicitly want to read the current Codex data. These opt-in checks are read-only and do not perform cleanup.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines. Report vulnerabilities through GitHub's [private vulnerability reporting](https://github.com/KaranocaVe/codex-cleaner/security/advisories/new). Do not attach databases, rollouts, logs, or other personal session content to public issues.

## Version and license

Current version: 0.2.3 (build 5). See [CHANGELOG.md](CHANGELOG.md) for release notes. The project uses the MIT License; see the repository's `LICENSE` file.
