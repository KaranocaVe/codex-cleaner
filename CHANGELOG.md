# Changelog

Notable changes for each release are recorded here. This project follows a simple versioned release history; entries describe shipped behavior, not unreleased work.

## 0.2.3 (build 5)

- Added a reviewable cleanup flow with cascade scope, progress reporting, and rollback attempts for failed operations.
- Move selected `.jsonl` and `.jsonl.zst` rollout files to `Trash/CodexCleaner/` and remove related records from five SQLite databases without creating database backups.
- Added bounded, on-demand conversation previews, including optional `zstd` support for compressed rollouts.
- Improved project and parent-child tree browsing, family-size aggregation, filtering, and native table selection.
- Added isolated fixture coverage; the test suite contains 39 tests, including three opt-in read-only checks against real local data.
