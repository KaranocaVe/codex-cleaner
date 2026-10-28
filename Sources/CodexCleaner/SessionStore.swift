import Foundation
import Combine
import SQLite3

struct CodexSession: Identifiable, Hashable, Sendable {
    enum Status: String, CaseIterable, Sendable {
        case active, idle, archived

        var label: String {
            switch self { case .active: "Active"; case .idle: "Idle"; case .archived: "Archived" }
        }
    }

    let id: String
    let title: String
    let preview: String
    let cwd: String
    let project: String
    let source: String
    let model: String
    let modelProvider: String
    let createdAt: Date
    let updatedAt: Date
    let archived: Bool
    let isPinned: Bool
    let tokensUsed: Int
    let itemCount: Int
    let turnCount: Int
    let byteCount: Int64
    let rolloutPath: String
    let projectKey: String
    let rolloutPathExists: Bool
    let originator: String
    let isSubagent: Bool
    let parentThreadID: String?
    /// The project registration backing this session, when the state database
    /// links it to a registered project, including inferred root matches.
    let registeredProjectID: String?
    let registeredProjectRoot: String?

    init(id: String, title: String, preview: String, cwd: String, project: String, source: String, model: String, modelProvider: String, createdAt: Date, updatedAt: Date, archived: Bool, isPinned: Bool, tokensUsed: Int, itemCount: Int, turnCount: Int, byteCount: Int64, rolloutPath: String, projectKey: String, rolloutPathExists: Bool, originator: String, isSubagent: Bool, parentThreadID: String?, registeredProjectID: String? = nil, registeredProjectRoot: String? = nil) {
        self.id = id; self.title = title; self.preview = preview; self.cwd = cwd; self.project = project
        self.source = source; self.model = model; self.modelProvider = modelProvider
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.archived = archived; self.isPinned = isPinned
        self.tokensUsed = tokensUsed; self.itemCount = itemCount; self.turnCount = turnCount; self.byteCount = byteCount
        self.rolloutPath = rolloutPath; self.projectKey = projectKey; self.rolloutPathExists = rolloutPathExists
        self.originator = originator; self.isSubagent = isSubagent; self.parentThreadID = parentThreadID
        self.registeredProjectID = registeredProjectID; self.registeredProjectRoot = registeredProjectRoot
    }

    var status: Status { archived ? .archived : (Date().timeIntervalSince(updatedAt) < 15 * 60 ? .active : .idle) }
    var projectPath: String { cwd.isEmpty ? "No working directory" : cwd }
    var searchableText: String { [id, title, preview, cwd, project, registeredProjectID ?? "", registeredProjectRoot ?? "", source, model, originator].joined(separator: " ").lowercased() }
    var isCurrent: Bool { id == ProcessInfo.processInfo.environment["CODEX_THREAD_ID"] }
}

struct SessionFilter: Sendable {
    enum Age: String, CaseIterable, Sendable {
        case any = "Any age", week = "Last 7 days", month = "Last 30 days", quarter = "Last 90 days", year = "Last year", older = "Older than a year"
        var cutoff: Date? {
            let now = Date()
            switch self {
            case .any: return nil
            case .week: return now.addingTimeInterval(-7 * 86400)
            case .month: return now.addingTimeInterval(-30 * 86400)
            case .quarter: return now.addingTimeInterval(-90 * 86400)
            case .year, .older: return now.addingTimeInterval(-365 * 86400)
            }
        }
    }

    var query = ""
    var project: String?
    var status: CodexSession.Status?
    var age: Age = .any
    var includeSubagents = true
    var includePinned = true

    func matches(_ session: CodexSession) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty && !session.searchableText.localizedStandardContains(needle) { return false }
        if let project, session.project != project && session.projectKey != project { return false }
        if let status, session.status != status { return false }
        if age == .older {
            guard let cutoff = age.cutoff, session.updatedAt < cutoff else { return false }
        } else if let cutoff = age.cutoff, session.updatedAt < cutoff { return false }
        if !includeSubagents && session.isSubagent { return false }
        if !includePinned && session.isPinned { return false }
        return true
    }
}

enum SessionStoreError: LocalizedError {
    case databaseMissing(URL)
    case cannotOpen(URL, String)
    case queryFailed(String)
    case deleteFailed(String)
    case unsafeRolloutPath(String)

    var errorDescription: String? {
        switch self {
        case let .databaseMissing(url): "找不到 Codex 状态数据库：\(url.path)。请检查 CODEX_HOME，或先启动 Codex。"
        case let .cannotOpen(url, message): "无法打开 \(url.lastPathComponent)：\(message)"
        case let .queryFailed(message): "无法读取 Codex 会话：\(message)"
        case let .deleteFailed(message): "无法清理会话：\(message)"
        case let .unsafeRolloutPath(path): "会话路径不安全，已停止清理：\(path)"
        }
    }
}

struct DeleteReceipt: Sendable {
    let count: Int
    let bytes: Int64
    let missingCount: Int
    let missingBytes: Int64
    let manifestURL: URL
    let trashURL: URL
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published private(set) var cleanupProgress: CleanupProgress?
    @Published var lastError: String?
    @Published private(set) var lastWarning: String?

    let home = FileManager.default.homeDirectoryForCurrentUser
    /// Root of the Codex data directory. The explicit argument is intended
    /// for isolated tests; production defaults to CODEX_HOME when set.
    let codexRoot: URL
    var stateURL: URL { codexRoot.appendingPathComponent("state_5.sqlite") }
    var historyURL: URL { codexRoot.appendingPathComponent("thread_history_1.sqlite") }
    private var reloadGeneration = 0
    private var loadTask: Task<Void, Never>?

    init(codexRoot: URL? = nil) {
        let configured = codexRoot ?? Self.defaultCodexRoot(home: home)
        self.codexRoot = configured.standardizedFileURL
    }

    static func defaultCodexRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let value = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    func reload() {
        guard !isDeleting else { return }
        loadTask?.cancel()
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        lastError = nil
        lastWarning = nil
        let stateURL = stateURL
        let historyURL = historyURL
        loadTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await Self.readWithRetry(stateURL: stateURL, historyURL: historyURL)
                }
                let loaded = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, self.reloadGeneration == generation else { return }
                self.sessions = loaded.sessions
                self.lastWarning = loaded.warning
            } catch {
                guard let self, self.reloadGeneration == generation else { return }
                self.lastWarning = nil
                self.lastError = error.localizedDescription
            }
            guard let self, self.reloadGeneration == generation else { return }
            self.isLoading = false
            if self.reloadGeneration == generation { self.loadTask = nil }
        }
    }

    func delete(_ targets: [CodexSession]) async throws -> DeleteReceipt {
        guard !targets.isEmpty else { throw SessionStoreError.deleteFailed("No sessions are selected.") }
        guard targets.allSatisfy({ !$0.isCurrent }) else { throw SessionStoreError.deleteFailed("The current Codex session cannot be removed while it is running.") }
        guard !isDeleting else { throw SessionStoreError.deleteFailed("Another cleanup is already in progress.") }
        // Do not let a refresh that started before or during the cleanup put
        // deleted rows back into the in-memory list when it finishes later.
        loadTask?.cancel()
        loadTask = nil
        reloadGeneration &+= 1
        isLoading = false
        isDeleting = true
        cleanupProgress = nil
        defer { isDeleting = false }
        let root = codexRoot
        let (progressStream, progressContinuation) = AsyncStream<CleanupProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let worker = Task.detached(priority: .userInitiated) {
            defer { progressContinuation.finish() }
            return try CleanupEngine(codexRoot: root).execute(targets) { event in
                progressContinuation.yield(event)
            }
        }
        // Consume the single ordered stream on the main actor. This avoids
        // spawning one UI task per event and prevents stale progress writes.
        for await event in progressStream {
            cleanupProgress = event
        }
        let receipt = try await worker.value
        reloadGeneration &+= 1
        isLoading = false
        let targetIDs = Set(targets.map(\.id))
        sessions.removeAll { targetIDs.contains($0.id) }
        return receipt
    }

    struct ReadResult: Sendable {
        let sessions: [CodexSession]
        let warning: String?
    }

    /// Read an isolated Codex state/history pair. This is internal rather
    /// than private so tests can exercise the real SQLite reader without
    /// touching the user's live data.
    nonisolated static func read(stateURL: URL, historyURL: URL) throws -> [CodexSession] {
        try readResult(stateURL: stateURL, historyURL: historyURL).sessions
    }

    nonisolated private static func readResult(stateURL: URL, historyURL: URL) throws -> ReadResult {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            throw SessionStoreError.databaseMissing(stateURL)
        }
        let stats: [String: (items: Int, turns: Int)]
        var warning: String?
        do {
            stats = try readStats(historyURL: historyURL)
        } catch {
            // History is an enrichment database. A damaged, locked, or
            // unavailable history file must not hide otherwise valid threads.
            stats = [:]
            warning = "历史统计暂不可用，当前轮次与条目数不可靠：\(error.localizedDescription)"
        }
        let db = try SQLiteDatabase(url: stateURL, readOnly: true)
        defer { db.close() }
        let projectRoots: [ProjectRoot]
        do {
            projectRoots = try Self.readProjectRoots(db: db)
        } catch {
            projectRoots = []
            warning = Self.appendWarning(warning, "登记项目的根目录读取失败：\(error.localizedDescription)")
        }
        let sql = """
        SELECT t.id, COALESCE(NULLIF(t.title,''), NULLIF(t.preview,''), NULLIF(t.first_user_message,''), 'Untitled session'),
               COALESCE(t.preview,''), COALESCE(t.cwd,''), COALESCE(NULLIF(p.name,''), ''),
               COALESCE(t.project_id, ''), COALESCE(t.source,''), COALESCE(t.thread_source,''), COALESCE(t.model,''), COALESCE(t.model_provider,''),
               COALESCE(NULLIF(t.created_at_ms,0), t.created_at * 1000), COALESCE(NULLIF(t.updated_at_ms,0), t.updated_at * 1000),
               t.archived, t.is_pinned, t.tokens_used, COALESCE(t.rollout_path,''), COALESCE(t.originator,''),
               CASE WHEN edge.parent_thread_id IS NOT NULL OR (t.agent_path IS NOT NULL AND t.agent_path <> '') OR (json_valid(t.source) AND json_extract(t.source, '$.subagent.thread_spawn.parent_thread_id') IS NOT NULL) THEN 1 ELSE 0 END,
               COALESCE(edge.parent_thread_id, CASE WHEN json_valid(t.source) THEN json_extract(t.source, '$.subagent.thread_spawn.parent_thread_id') END)
        FROM threads t LEFT JOIN projects p ON p.id = t.project_id
        LEFT JOIN thread_spawn_edges edge ON edge.child_thread_id = t.id
        ORDER BY COALESCE(t.updated_at_ms, t.updated_at * 1000) DESC
        """
        let sessions = try db.rows(sql: sql) { statement in
            let id = statement.text(0)
            let storedPath = statement.text(15)
            let resolvedPath = storedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : Self.resolveRolloutURL(URL(fileURLWithPath: storedPath))
            let path = resolvedPath?.path ?? storedPath
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            let stat = stats[id] ?? (0, 0)
            let cwd = statement.text(3)
            let registeredID = statement.text(5).isEmpty ? nil : statement.text(5)
            let project = Self.projectInfo(explicit: statement.text(4), cwd: cwd, registeredProjectID: registeredID, roots: projectRoots)
            return CodexSession(id: id, title: statement.text(1), preview: statement.text(2), cwd: cwd, project: project.name, source: statement.text(6), model: statement.text(8), modelProvider: statement.text(9), createdAt: Date(timeIntervalSince1970: TimeInterval(statement.int64(10)) / 1000), updatedAt: Date(timeIntervalSince1970: TimeInterval(statement.int64(11)) / 1000), archived: statement.int(12) != 0, isPinned: statement.int(13) != 0, tokensUsed: statement.int(14), itemCount: stat.items, turnCount: stat.turns, byteCount: fileSize, rolloutPath: path, projectKey: project.key, rolloutPathExists: resolvedPath != nil, originator: statement.text(16), isSubagent: statement.int(17) != 0, parentThreadID: statement.text(18).isEmpty ? nil : statement.text(18), registeredProjectID: project.registeredID, registeredProjectRoot: project.registeredRoot)
        }
        return ReadResult(sessions: sessions, warning: warning)
    }

    /// Codex may briefly hold a write lock while rotating its WAL files. A
    /// single failed read used to leave the UI looking empty forever. Retry a
    /// few times before surfacing the error to the user.
    nonisolated static func readWithRetry(stateURL: URL, historyURL: URL) async throws -> ReadResult {
        var lastError: Error?
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do { return try readResult(stateURL: stateURL, historyURL: historyURL) }
            catch {
                lastError = error
                guard attempt < 3, Self.isTransientReadError(error) else { throw error }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        throw lastError ?? SessionStoreError.queryFailed("Unknown read error")
    }

    nonisolated private static func isTransientReadError(_ error: Error) -> Bool {
        guard case let SessionStoreError.queryFailed(message) = error else { return false }
        let lowercased = message.lowercased()
        return lowercased.contains("busy") || lowercased.contains("locked") || lowercased.contains("busy timeout")
    }

    private struct ProjectRoot {
        let projectID: String
        let name: String
        let path: String
    }

    nonisolated private static func readProjectRoots(db: SQLiteDatabase) throws -> [ProjectRoot] {
        let sql = """
        SELECT p.id, p.name, r.path
        FROM project_roots r JOIN projects p ON p.id = r.project_id
        WHERE r.path <> ''
        ORDER BY LENGTH(r.path) DESC, r.position ASC
        """
        return try db.rows(sql: sql) { row in
            ProjectRoot(projectID: row.text(0), name: row.text(1), path: URL(fileURLWithPath: row.text(2)).standardizedFileURL.path)
        }
    }

    nonisolated private static func projectInfo(explicit: String, cwd: String, registeredProjectID: String?, roots: [ProjectRoot]) -> (name: String, key: String, registeredID: String?, registeredRoot: String?) {
        let cwdPath = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).standardizedFileURL.path
        let matchingRoot = roots.first(where: { root in
            guard registeredProjectID == nil || root.projectID == registeredProjectID else { return false }
            return cwdPath == root.path || cwdPath.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
        })
        if let root = matchingRoot {
            let name = root.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectName = name.isEmpty ? URL(fileURLWithPath: root.path).lastPathComponent : name
            let projectID = registeredProjectID ?? root.projectID
            return (projectName, "project:\(projectID)", projectID, root.path)
        }
        let explicitName = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicitName.isEmpty {
            if let registeredProjectID { return (explicitName, "project:\(registeredProjectID)", registeredProjectID, nil) }
            return (explicitName, cwdPath.isEmpty ? "name:\(explicitName)" : cwdPath, nil, nil)
        }
        if let registeredProjectID { return ("Unassigned", "project:\(registeredProjectID)", registeredProjectID, nil) }
        guard !cwdPath.isEmpty else { return ("Unassigned", "unassigned", nil, nil) }
        if cwdPath == FileManager.default.homeDirectoryForCurrentUser.path { return ("Home", cwdPath, nil, nil) }
        let name = URL(fileURLWithPath: cwdPath).lastPathComponent
        return (name.isEmpty ? cwdPath : name, cwdPath, nil, nil)
    }

    nonisolated private static func appendWarning(_ existing: String?, _ next: String) -> String {
        existing.map { "\($0)\n\(next)" } ?? next
    }

    nonisolated private static func resolveRolloutURL(_ stored: URL) -> URL? {
        let path = stored.standardizedFileURL
        if FileManager.default.fileExists(atPath: path.path) { return path }
        if path.pathExtension == "jsonl" {
            let compressed = URL(fileURLWithPath: path.path + ".zst")
            if FileManager.default.fileExists(atPath: compressed.path) { return compressed }
        } else if path.pathExtension == "zst" && path.deletingPathExtension().pathExtension == "jsonl" {
            let plain = path.deletingPathExtension()
            if FileManager.default.fileExists(atPath: plain.path) { return plain }
        }
        return nil
    }

    nonisolated private static func readStats(historyURL: URL) throws -> [String: (items: Int, turns: Int)] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            throw SessionStoreError.cannotOpen(historyURL, "file not found")
        }
        let db = try SQLiteDatabase(url: historyURL, readOnly: true); defer { db.close() }
        var result: [String: (Int, Int)] = [:]
        _ = try db.rows(sql: "SELECT thread_id, COUNT(*) FROM thread_items GROUP BY thread_id") { s in result[s.text(0), default: (0, 0)].0 = s.int(1) }
        _ = try db.rows(sql: "SELECT thread_id, COUNT(*) FROM thread_turns GROUP BY thread_id") { s in result[s.text(0), default: (0, 0)].1 = s.int(1) }
        return result
    }


}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?
    init(url: URL, readOnly: Bool, allowCreate: Bool = true) throws {
        var pointer: OpaquePointer?
        let flags = readOnly ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX) : (SQLITE_OPEN_READWRITE | (allowCreate ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX)
        guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if pointer != nil { sqlite3_close(pointer) }
            throw SessionStoreError.cannotOpen(url, message)
        }
        handle = pointer
        sqlite3_busy_timeout(pointer, 3000)
        if !readOnly { try exec("PRAGMA foreign_keys = ON") }
    }
    deinit { close() }
    func close() { if let handle { sqlite3_close(handle); self.handle = nil } }
    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error); throw SessionStoreError.deleteFailed(message)
        }
    }
    func rows<T>(sql: String, _ body: (SQLiteRow) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw SessionStoreError.queryFailed(String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { values.append(try body(SQLiteRow(statement: statement!))) }
            else if result == SQLITE_DONE { break }
            else { throw SessionStoreError.queryFailed(String(cString: sqlite3_errmsg(handle))) }
        }
        return values
    }
    func tableExists(_ name: String) -> Bool {
        (try? rows(sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(Self.quote(name))' LIMIT 1") { _ in true }.isEmpty == false) ?? false
    }
    static func quote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
}

private struct SQLiteRow {
    let statement: OpaquePointer
    func text(_ column: Int32) -> String { guard let c = sqlite3_column_text(statement, column) else { return "" }; return String(cString: c) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
}
