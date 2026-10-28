import XCTest
import Foundation
import SQLite3
@testable import CodexCleaner

final class CleanupEngineFixtureTests: XCTestCase {
    func testCleanupMovesSiblingZstCountsMissingAndRemovesSidecarRows() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let compressed = sessionsDirectory.appendingPathComponent("selected.jsonl.zst")
        try Data("compressed fixture".utf8).write(to: compressed)
        try createDatabase(at: root.appendingPathComponent("state_5.sqlite"), sql: """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT);
            CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT);
            INSERT INTO threads VALUES ('selected', '\(compressed.path.replacingOccurrences(of: "'", with: "''").replacingOccurrences(of: ".jsonl.zst", with: ".jsonl"))');
            INSERT INTO threads VALUES ('missing', '\(sessionsDirectory.appendingPathComponent("missing.jsonl").path)');
            """)
        let history = root.appendingPathComponent("thread_history_1.sqlite")
        try createDatabase(at: history, sql: "CREATE TABLE thread_items (thread_id TEXT); INSERT INTO thread_items VALUES ('selected'), ('missing');")

        let selected = fixtureSession(id: "selected", rolloutPath: sessionsDirectory.appendingPathComponent("selected.jsonl").path, byteCount: 17)
        let missing = fixtureSession(id: "missing", rolloutPath: sessionsDirectory.appendingPathComponent("missing.jsonl").path, byteCount: 23)
        let receipt = try CleanupEngine(codexRoot: root).execute([selected, missing])

        XCTAssertEqual(receipt.count, 2)
        XCTAssertEqual(receipt.missingCount, 1)
        XCTAssertEqual(receipt.missingBytes, 23)
        XCTAssertFalse(FileManager.default.fileExists(atPath: compressed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.trashURL.appendingPathComponent("sessions/selected.jsonl.zst").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.manifestURL.path))
        XCTAssertEqual(receipt.manifestURL.deletingLastPathComponent().path, receipt.trashURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("codex-cleaner-backups").path))
        XCTAssertEqual(try scalar(at: root.appendingPathComponent("state_5.sqlite"), sql: "SELECT COUNT(*) FROM threads"), 0)
        XCTAssertEqual(try scalar(at: history, sql: "SELECT COUNT(*) FROM thread_items"), 0)
    }

    func testUnsafeRolloutLeavesFixtureUntouched() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.jsonl")
        try Data("do not move".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let state = root.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: state, sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); INSERT INTO threads VALUES ('unsafe', '\(outside.path)');")
        let target = fixtureSession(id: "unsafe", rolloutPath: outside.path)

        XCTAssertThrowsError(try CleanupEngine(codexRoot: root).execute([target]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try scalar(at: state, sql: "SELECT COUNT(*) FROM threads"), 1)
    }

    func testCleanupDoesNotRequireWritableDatabaseBackupLocation() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A file blocks the old backup directory. The cleanup must ignore it.
        let backupBlocker = root.appendingPathComponent("codex-cleaner-backups")
        let marker = Data("existing unrelated file".utf8)
        try marker.write(to: backupBlocker)
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("selected.jsonl")
        try Data("selected".utf8).write(to: rollout)
        let state = root.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: state, sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); INSERT INTO threads VALUES ('selected', '\(rollout.path)');")

        let receipt = try CleanupEngine(codexRoot: root).execute([fixtureSession(id: "selected", rolloutPath: rollout.path)])
        XCTAssertEqual(try Data(contentsOf: backupBlocker), marker)
        XCTAssertEqual(try scalar(at: state, sql: "SELECT COUNT(*) FROM threads"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.trashURL.appendingPathComponent("sessions/selected.jsonl").path))
    }

    func testUnwritableStagingLocationDoesNotChangeDatabaseOrRollout() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocks staging directory".utf8).write(to: root.appendingPathComponent("Trash"))
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("selected.jsonl")
        try Data("selected".utf8).write(to: rollout)
        let state = root.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: state, sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); INSERT INTO threads VALUES ('selected', '\(rollout.path)');")

        XCTAssertThrowsError(try CleanupEngine(codexRoot: root).execute([fixtureSession(id: "selected", rolloutPath: rollout.path)])) { error in
            XCTAssertTrue(error.localizedDescription.contains("暂存目录"))
            XCTAssertFalse(error.localizedDescription.contains("备份"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollout.path))
        XCTAssertEqual(try scalar(at: state, sql: "SELECT COUNT(*) FROM threads"), 1)
    }

    func testSidecarSqlFailureRestoresMovedRolloutAndRows() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let rollout = sessionsDirectory.appendingPathComponent("rollback.jsonl")
        try Data("rollback fixture".utf8).write(to: rollout)
        let state = root.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: state, sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); INSERT INTO threads VALUES ('rollback', '\(rollout.path)');")
        // Deliberately malformed schema causes the sidecar DELETE to fail only
        // after rollout movement, exercising the engine's restoration path.
        let history = root.appendingPathComponent("thread_history_1.sqlite")
        try createDatabase(at: history, sql: "CREATE TABLE thread_items (wrong_column TEXT);")

        let target = fixtureSession(id: "rollback", rolloutPath: rollout.path)
        XCTAssertThrowsError(try CleanupEngine(codexRoot: root).execute([target]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollout.path))
        XCTAssertEqual(try scalar(at: state, sql: "SELECT COUNT(*) FROM threads"), 1)
        let batches = root.appendingPathComponent("Trash/CodexCleaner")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: batches.path)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("codex-cleaner-backups").path))
    }

    func testStaleSelectionAndSharedRolloutAreRejectedBeforeMovingFiles() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("old.jsonl")
        let current = directory.appendingPathComponent("current.jsonl")
        try Data("old".utf8).write(to: old)
        try Data("current".utf8).write(to: current)
        let state = root.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: state, sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); INSERT INTO threads VALUES ('target', '\(current.path)');")
        XCTAssertThrowsError(try CleanupEngine(codexRoot: root).execute([fixtureSession(id: "target", rolloutPath: old.path)]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        try createDatabase(at: state, sql: "INSERT INTO threads VALUES ('survivor', '\(current.path)');")
        XCTAssertThrowsError(try CleanupEngine(codexRoot: root).execute([fixtureSession(id: "target", rolloutPath: current.path)]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(try scalar(at: state, sql: "SELECT COUNT(*) FROM threads"), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("codex-cleaner-backups").path))
    }

    func testSymlinkToDatabaseIsRejected() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state_5.sqlite")
        let link = directory.appendingPathComponent("malformed.jsonl")
        try createDatabase(at: state, sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); INSERT INTO threads VALUES ('target', '\(link.path)');")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: state)
        XCTAssertThrowsError(try CleanupEngine(codexRoot: root).execute([fixtureSession(id: "target", rolloutPath: link.path)]))
        XCTAssertEqual(try scalar(at: state, sql: "SELECT COUNT(*) FROM threads"), 1)
    }

    private func fixtureSession(id: String, rolloutPath: String, byteCount: Int64 = 0) -> CodexSession {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        return CodexSession(
            id: id, title: id, preview: "", cwd: "", project: "Fixture",
            source: "", model: "",
            modelProvider: "", createdAt: date, updatedAt: date, archived: false,
            isPinned: false, tokensUsed: 0, itemCount: 0, turnCount: 0, byteCount: byteCount,
            rolloutPath: rolloutPath, projectKey: "fixture", rolloutPathExists: true,
            originator: "", isSubagent: false, parentThreadID: nil,
            registeredProjectID: nil, registeredProjectRoot: nil
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexCleanerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createDatabase(at url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw NSError(domain: "CleanupEngineFixtureTests", code: 1) }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "CleanupEngineFixtureTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func scalar(at url: URL, sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw NSError(domain: "CleanupEngineFixtureTests", code: 3) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NSError(domain: "CleanupEngineFixtureTests", code: 4) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "CleanupEngineFixtureTests", code: 5) }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
