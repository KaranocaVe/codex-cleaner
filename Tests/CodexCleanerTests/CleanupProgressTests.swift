import XCTest
import Foundation
import SQLite3
@testable import CodexCleaner

final class CleanupProgressTests: XCTestCase {
    func testProgressIsMonotonicAndCompletesOnlyAfterCommit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("one.jsonl")
        try Data("one".utf8).write(to: rollout)
        let state = root.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: state, sql: """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT);
            INSERT INTO threads VALUES ('one', '\(sqlQuote(rollout.path))');
            """)

        let collector = ProgressCollector()
        _ = try CleanupEngine(codexRoot: root).execute([session(id: "one", path: rollout.path)]) {
            collector.append($0)
        }
        let events = collector.values

        XCTAssertEqual(events.last?.phase, .completed)
        XCTAssertEqual(events.last?.fraction, 1)
        XCTAssertTrue(zip(events, events.dropFirst()).allSatisfy { $0.0.fraction <= $0.1.fraction })
        let commitIndex = try XCTUnwrap(events.lastIndex { $0.phase == .committing })
        let completedIndex = try XCTUnwrap(events.lastIndex { $0.phase == .completed })
        XCTAssertLessThan(commitIndex, completedIndex)
        XCTAssertLessThan(events[commitIndex].fraction, 1)
        XCTAssertEqual(try scalar(at: state, sql: "SELECT COUNT(*) FROM threads"), 0)
    }

    func testSqlFailureReportsRollbackWithoutCompletion() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("one.jsonl")
        try Data("one".utf8).write(to: rollout)
        let state = root.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: state, sql: """
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT);
            INSERT INTO threads VALUES ('one', '\(sqlQuote(rollout.path))');
            """)
        let history = root.appendingPathComponent("thread_history_1.sqlite")
        try createDatabase(at: history, sql: "CREATE TABLE thread_items (wrong_column TEXT);")

        let collector = ProgressCollector()
        XCTAssertThrowsError(try CleanupEngine(codexRoot: root).execute([session(id: "one", path: rollout.path)]) {
            collector.append($0)
        })
        let events = collector.values
        XCTAssertTrue(events.contains { $0.phase == .rollback })
        XCTAssertFalse(events.contains { $0.phase == .completed || $0.fraction == 1 })
        XCTAssertEqual(try scalar(at: state, sql: "SELECT COUNT(*) FROM threads"), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollout.path))
    }

    private func session(id: String, path: String) -> CodexSession {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        return CodexSession(id: id, title: id, preview: "", cwd: "", project: "Fixture",
                            source: "", model: "", modelProvider: "", createdAt: date, updatedAt: date,
                            archived: false, isPinned: false, tokensUsed: 0, itemCount: 0, turnCount: 0,
                            byteCount: 0, rolloutPath: path, projectKey: "fixture", rolloutPathExists: true,
                            originator: "", isSubagent: false, parentThreadID: nil)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexProgress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createDatabase(at url: URL, sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw NSError(domain: "CleanupProgressTests", code: 1) }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "CleanupProgressTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func scalar(at url: URL, sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw NSError(domain: "CleanupProgressTests", code: 3) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "CleanupProgressTests", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "CleanupProgressTests", code: 5) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func sqlQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CleanupProgress] = []

    func append(_ event: CleanupProgress) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [CleanupProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
