import XCTest
import Foundation
import SQLite3
@testable import CodexCleaner

/// Opt-in smoke coverage against the user's current Codex cache. It is
/// intentionally disabled by default and reports only aggregate counts.
@MainActor
final class SessionStoreRealDataTests: XCTestCase {
    func testMissingStateDatabaseIsAnExplicitFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexCleanerMissing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SessionStore.read(stateURL: root.appendingPathComponent("state_5.sqlite"), historyURL: root.appendingPathComponent("thread_history_1.sqlite"))) { error in
            guard case SessionStoreError.databaseMissing = error else {
                return XCTFail("Expected databaseMissing, got \(error)")
            }
        }
    }

    func testCorruptStateDatabaseIsNotReportedAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexCleanerCorrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = root.appendingPathComponent("state_5.sqlite")
        try Data("not sqlite".utf8).write(to: state)
        XCTAssertThrowsError(try SessionStore.read(stateURL: state, historyURL: root.appendingPathComponent("thread_history_1.sqlite")))
    }

    func testRealStateReadMatchesReadOnlyThreadCount() throws {
        guard ProcessInfo.processInfo.environment["CODEX_CLEANER_TEST_REAL_DATA"] == "1" else {
            throw XCTSkip("Set CODEX_CLEANER_TEST_REAL_DATA=1 to inspect the live Codex cache.")
        }
        let root = SessionStore.defaultCodexRoot()
        let stateURL = root.appendingPathComponent("state_5.sqlite")
        let historyURL = root.appendingPathComponent("thread_history_1.sqlite")
        let sessions = try SessionStore.read(stateURL: stateURL, historyURL: historyURL)
        XCTAssertEqual(sessions.count, try readThreadCount(stateURL))

        // These aggregate invariants exercise path resolution without exposing
        // titles, prompts, paths, or any other private session content.
        XCTAssertTrue(sessions.allSatisfy { !$0.projectKey.isEmpty })
        XCTAssertTrue(sessions.contains { $0.registeredProjectID != nil && $0.registeredProjectRoot != nil }, "Expected project root inference for the registered projects in this cache")
        XCTAssertTrue(sessions.filter(\.rolloutPathExists).allSatisfy {
            FileManager.default.fileExists(atPath: $0.rolloutPath)
        })
    }

    func testRealFamilyTotalsMatchIndependentDescendantTraversal() throws {
        guard ProcessInfo.processInfo.environment["CODEX_CLEANER_TEST_REAL_DATA"] == "1" else {
            throw XCTSkip("Set CODEX_CLEANER_TEST_REAL_DATA=1 to inspect the live Codex cache.")
        }
        let root = SessionStore.defaultCodexRoot()
        let sessions = try SessionStore.read(stateURL: root.appendingPathComponent("state_5.sqlite"),
                                             historyURL: root.appendingPathComponent("thread_history_1.sqlite"))
        let snapshot = BrowserSnapshot.build(sessions: sessions, treeMode: true)
        let children = Dictionary(grouping: sessions.filter { $0.parentThreadID != nil }, by: { $0.parentThreadID! })
        let parents = sessions.filter { children[$0.id] != nil }.sorted { $0.id < $1.id }.prefix(32)
        guard !parents.isEmpty else { throw XCTSkip("This cache has no parent sessions.") }
        for parent in parents {
            var ids = Set<String>()
            var pending = [parent.id]
            while let id = pending.popLast() {
                guard ids.insert(id).inserted else { continue }
                pending.append(contentsOf: (children[id] ?? []).map(\.id))
            }
            let expected = sessions.filter { ids.contains($0.id) }.reduce(Int64(0)) { $0 + $1.byteCount }
            XCTAssertEqual(snapshot.familyTotalsByID[parent.id]?.byteCount, expected)
            XCTAssertEqual(snapshot.familyTotalsByID[parent.id]?.sessionCount, ids.count)
            // Selecting every member must not count nested families twice.
            XCTAssertEqual(snapshot.total(for: ids, includingDescendants: true).byteCount, expected)
        }
    }

    private func readThreadCount(_ url: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            defer { if let db { sqlite3_close(db) } }
            throw XCTSkip("Live state database is unavailable.")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM threads", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw XCTSkip("Live state schema is unavailable.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw XCTSkip("Live state query failed.") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
