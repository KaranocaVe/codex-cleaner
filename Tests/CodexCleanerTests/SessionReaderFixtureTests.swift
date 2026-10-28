import Foundation
import SQLite3
import XCTest
@testable import CodexCleaner

final class SessionReaderFixtureTests: XCTestCase {
    func testHistoryFailureKeepsSessionsAndWarns() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state_5.sqlite")
        try createState(state)
        let history = root.appendingPathComponent("thread_history_1.sqlite")
        try Data("corrupt optional history".utf8).write(to: history)
        let result = try await SessionStore.readWithRetry(stateURL: state, historyURL: history)
        XCTAssertEqual(result.sessions.count, 3)
        XCTAssertNotNil(result.warning)
    }

    func testRootInferencePreservesProjectIdentityAcrossMultipleRoots() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state_5.sqlite")
        try createState(state)
        let sessions = try SessionStore.read(stateURL: state, historyURL: root.appendingPathComponent("absent.sqlite"))
        let parent = try XCTUnwrap(sessions.first { $0.id == "parent" })
        let otherRoot = try XCTUnwrap(sessions.first { $0.id == "other-root" })
        let nested = try XCTUnwrap(sessions.first { $0.id == "nested" })
        XCTAssertEqual(parent.registeredProjectID, "project-1")
        XCTAssertEqual(otherRoot.registeredProjectID, "project-1")
        XCTAssertEqual(parent.projectKey, otherRoot.projectKey)
        XCTAssertEqual(nested.registeredProjectID, "project-2")
        XCTAssertNotEqual(parent.projectKey, nested.projectKey)
        XCTAssertEqual(parent.project, nested.project, "Same display names must stay separate")
        XCTAssertEqual(nested.parentThreadID, "parent", "Parent metadata fallback must work without a spawn edge")
        XCTAssertTrue(nested.isSubagent)
    }

    @MainActor
    func testConfiguredRootIsUsedForStoreDeletion() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state_5.sqlite")
        try createState(state)
        let directory = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("parent.jsonl")
        try Data("test rollout".utf8).write(to: rollout)
        try exec(state, "UPDATE threads SET rollout_path='\(rollout.path)' WHERE id='parent'")
        let loaded = try SessionStore.read(stateURL: state, historyURL: root.appendingPathComponent("missing.sqlite"))
        let target = try XCTUnwrap(loaded.first { $0.id == "parent" })
        let store = SessionStore(codexRoot: root)
        let receipt = try await store.delete([target])
        XCTAssertEqual(receipt.count, 1)
        XCTAssertTrue(receipt.manifestURL.path.hasPrefix(root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("codex-cleaner-backups").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollout.path))
        let remaining = try SessionStore.read(stateURL: state, historyURL: root.appendingPathComponent("missing.sqlite"))
        XCTAssertEqual(Set(remaining.map(\.id)), ["other-root", "nested"])
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexCleanerReader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createState(_ url: URL) throws {
        try exec(url, """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY, title TEXT, preview TEXT, first_user_message TEXT, cwd TEXT,
            project_id TEXT, source TEXT, thread_source TEXT, model TEXT, model_provider TEXT,
            created_at_ms INTEGER, created_at INTEGER, updated_at_ms INTEGER, updated_at INTEGER,
            archived INTEGER DEFAULT 0, is_pinned INTEGER DEFAULT 0, tokens_used INTEGER DEFAULT 0,
            rollout_path TEXT DEFAULT '', originator TEXT DEFAULT '', agent_path TEXT
        );
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT);
        CREATE TABLE project_roots (project_id TEXT, path TEXT, position INTEGER);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT);
        INSERT INTO projects VALUES ('project-1','Same Name'),('project-2','Same Name');
        INSERT INTO project_roots VALUES ('project-1','/workspace/project',0), ('project-1','/another/root',1), ('project-2','/workspace/project/nested',0);
        INSERT INTO threads (id,title,cwd,source,created_at,updated_at) VALUES
        ('parent','Parent','/workspace/project/sub','cli',1700000000,1700000000),
        ('other-root','Other','/another/root/sub','cli',1700000000,1700000000),
        ('nested','Nested','/workspace/project/nested/sub','{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}',1700000000,1700000000);
        """)
    }

    private func exec(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &message) != SQLITE_OK {
            let error = message.map { String(cString: $0) } ?? "SQLite fixture failed"
            sqlite3_free(message)
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }
}
