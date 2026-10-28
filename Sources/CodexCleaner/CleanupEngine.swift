import Foundation
import SQLite3

struct CleanupProgress: Sendable, Equatable {
    enum Phase: String, Sendable, CaseIterable {
        case preparing, staging, movingFiles, deletingRows, verifying, committing, rollback, failed, completed

        var label: String {
            switch self {
            case .preparing: "准备清理"
            case .staging: "准备暂存"
            case .movingFiles: "搬移会话文件"
            case .deletingRows: "清理数据库记录"
            case .verifying: "验证清理结果"
            case .committing: "提交数据库事务"
            case .rollback: "恢复失败变更"
            case .failed: "清理失败"
            case .completed: "清理完成"
            }
        }
    }

    let phase: Phase
    let completed: Int
    let total: Int
    let fraction: Double
    let detail: String?

    init(phase: Phase, completed: Int, total: Int, detail: String? = nil) {
        let boundedTotal = max(1, total)
        let boundedCompleted = min(max(0, completed), boundedTotal)
        self.phase = phase
        self.completed = boundedCompleted
        self.total = boundedTotal
        self.fraction = Double(boundedCompleted) / Double(boundedTotal)
        self.detail = detail
    }
}

/// The destructive part of cleanup is kept independent of the UI and accepts
/// an explicit root so it can be exercised against a disposable fixture.
struct CleanupEngine: Sendable {
    struct Paths: Sendable {
        let codexRoot: URL
        let stateURL: URL
        let historyURL: URL
        let logsURL: URL
        let goalsURL: URL
        let queueURL: URL

        init(codexRoot: URL) {
            let root = codexRoot.resolvingSymlinksInPath().standardizedFileURL
            self.codexRoot = root
            stateURL = root.appendingPathComponent("state_5.sqlite")
            historyURL = root.appendingPathComponent("thread_history_1.sqlite")
            logsURL = root.appendingPathComponent("logs_2.sqlite")
            goalsURL = root.appendingPathComponent("goals_1.sqlite")
            queueURL = root.appendingPathComponent("queue_1.sqlite")
        }
    }

    private struct MovedFile: Codable, Sendable {
        let source: String
        let destination: String
        let bytes: Int64
    }

    private struct Manifest: Codable, Sendable {
        let createdAt: Date
        let codexRoot: String
        let databases: [String]
        let sessionIDs: [String]
        let files: [MovedFile]
        let missingIDs: [String]
        let missingBytes: Int64
        let consistencyNote: String
    }

    private struct FilePlan: Sendable {
        let sessionID: String
        let source: URL
        let destination: URL
        let bytes: Int64
    }

    let paths: Paths

    init(codexRoot: URL) {
        paths = Paths(codexRoot: codexRoot)
    }

    /// Move rollout files into recoverable trash and remove only the selected
    /// records. SQLite transactions provide rollback without copying databases.
    func execute(_ sessions: [CodexSession], progress: @Sendable (CleanupProgress) -> Void = { _ in }) throws -> DeleteReceipt {
        guard !sessions.isEmpty else { throw SessionStoreError.deleteFailed("No sessions are selected.") }

        let root = try validateRoot(paths.codexRoot)
        let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let trash = root.appendingPathComponent("Trash/CodexCleaner").appendingPathComponent(stamp)
        var plans: [FilePlan] = []
        var missingIDs: [String] = []
        var missingBytes: Int64 = 0
        var originalRolloutPaths: [String: String] = [:]
        var progressTotal = max(1, sessions.count + 3)
        var progressCompleted = 0
        func report(_ phase: CleanupProgress.Phase, completed: Int? = nil, detail: String? = nil) {
            progressCompleted = max(progressCompleted, completed ?? progressCompleted)
            progress(CleanupProgress(phase: phase, completed: progressCompleted, total: progressTotal, detail: detail))
        }
        do {
            for session in sessions {
                let plan = try makePlan(for: session, root: root, trash: trash)
                if let plan {
                    plans.append(contentsOf: plan)
                } else {
                    missingIDs.append(session.id)
                    missingBytes += max(0, session.byteCount)
                }
            }
            var seenSources = Set<String>()
            for plan in plans {
                guard seenSources.insert(plan.source.path).inserted else {
                    throw SessionStoreError.deleteFailed("Multiple selected sessions reference the same rollout file: \(plan.source.path)")
                }
            }
            originalRolloutPaths = try validateTargets(sessions, plans: plans, root: root)
        } catch {
            report(.failed, detail: error.localizedDescription)
            if let failure = error as? SessionStoreError { throw failure }
            throw SessionStoreError.deleteFailed("\(error.localizedDescription)")
        }
        progressTotal = plans.count + sessions.count + 3
        report(.preparing, detail: "已完成路径与数据库预检，共 \(sessions.count) 个会话")
        do {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        } catch {
            report(.failed, detail: error.localizedDescription)
            throw SessionStoreError.deleteFailed("无法创建会话文件暂存目录 \(trash.path)：\(error.localizedDescription)")
        }

        let databaseURLs = [paths.stateURL, paths.historyURL, paths.logsURL, paths.goalsURL, paths.queueURL]
        let initialManifest = Manifest(
            createdAt: Date(), codexRoot: root.path,
            databases: databaseURLs.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent),
            sessionIDs: sessions.map(\.id), files: plans.map { MovedFile(source: $0.source.path, destination: $0.destination.path, bytes: $0.bytes) },
            missingIDs: missingIDs, missingBytes: missingBytes,
            consistencyNote: "No database backups are created. Files are retained here; committed database deletions have no undo. Attached WAL database commits are not globally crash-atomic."
        )
        do { try writeManifest(initialManifest, to: trash) }
        catch {
            try? FileManager.default.removeItem(at: trash)
            report(.failed, detail: error.localizedDescription)
            throw SessionStoreError.deleteFailed("无法写入文件搬移清单 \(trash.path)：\(error.localizedDescription)")
        }
        report(.staging, completed: 1, detail: "已创建文件暂存清单；缺少文件 \(missingIDs.count) 个")

        var moved: [(source: URL, destination: URL)] = []
        var movedBytes: Int64 = 0
        do {
            for plan in plans {
                try FileManager.default.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: plan.source, to: plan.destination)
                moved.append((plan.source, plan.destination))
                movedBytes += plan.bytes
                report(.movingFiles, completed: progressCompleted + 1, detail: plan.source.lastPathComponent)
            }
            try deleteRows(sessions.map(\.id), sessions: sessions, originalRolloutPaths: originalRolloutPaths, progressStart: progressCompleted) { phase, completed, detail in
                report(phase, completed: completed, detail: detail)
            }
        } catch {
            report(.rollback, detail: "正在恢复已搬移的会话文件")
            let restoreErrors = restore(moved)
            if restoreErrors.isEmpty {
                try? FileManager.default.removeItem(at: trash)
                report(.failed, detail: error.localizedDescription)
                throw error
            }
            var message: String
            if case let SessionStoreError.deleteFailed(detail) = error { message = detail }
            else { message = error.localizedDescription }
            if !restoreErrors.isEmpty { message += "\nCould not restore: \(restoreErrors.joined(separator: "; "))" }
            message += "\nFile manifest: \(trash.appendingPathComponent("manifest.json").path)"
            report(.failed, detail: message)
            throw SessionStoreError.deleteFailed(message)
        }

        return DeleteReceipt(count: sessions.count, bytes: movedBytes, missingCount: missingIDs.count, missingBytes: missingBytes,
                             manifestURL: trash.appendingPathComponent("manifest.json"), trashURL: trash)
    }

    private func validateRoot(_ root: URL) throws -> URL {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SessionStoreError.deleteFailed("Codex root does not exist: \(root.path)")
        }
        return resolved
    }

    private func makePlan(for session: CodexSession, root: URL, trash: URL) throws -> [FilePlan]? {
        let raw = session.rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw SessionStoreError.unsafeRolloutPath("(empty rollout path) [session \(session.id)]") }
        let declared = URL(fileURLWithPath: raw).standardizedFileURL
        let lexical = try validateRolloutPath(declared, root: root)
        guard let existing = resolveExisting(lexical) else { return nil }
        let source = try validateRolloutPath(existing, root: root)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isDirectory != true else {
            throw SessionStoreError.unsafeRolloutPath(source.path)
        }
        let relative = relativePath(source, from: root)
        let destination = trash.appendingPathComponent(relative)
        var result = [FilePlan(sessionID: session.id, source: source, destination: destination, bytes: Int64(values.fileSize ?? 0))]

        let companion: URL?
        if source.pathExtension == "jsonl" { companion = URL(fileURLWithPath: source.path + ".zst") }
        else if source.pathExtension == "zst", source.deletingPathExtension().pathExtension == "jsonl" { companion = source.deletingPathExtension() }
        else { companion = nil }
        if let companion, FileManager.default.fileExists(atPath: companion.path) {
            let companionPlan = try makeCompanionPlan(companion, root: root, trash: trash, sessionID: session.id)
            result.append(companionPlan)
        }
        return result
    }

    private func makeCompanionPlan(_ source: URL, root: URL, trash: URL, sessionID: String) throws -> FilePlan {
        let valid = try validateRolloutPath(source.standardizedFileURL, root: root)
        let resolved = valid.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isDirectory != true else { throw SessionStoreError.unsafeRolloutPath(resolved.path) }
        return FilePlan(sessionID: sessionID, source: resolved, destination: trash.appendingPathComponent(relativePath(resolved, from: root)), bytes: Int64(values.fileSize ?? 0))
    }

    private func validateRolloutPath(_ url: URL, root: URL) throws -> URL {
        let allowed = ["sessions", "archived_sessions"]
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let relative = relativePath(url, from: root)
        let components = relative.split(separator: "/").map(String.init)
        let validExtension = components.last?.hasSuffix(".jsonl") == true || components.last?.hasSuffix(".jsonl.zst") == true
        guard components.count >= 2, allowed.contains(components[0]), validExtension else {
            throw SessionStoreError.unsafeRolloutPath(url.path)
        }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path == root.path || resolved.path.hasPrefix(rootPrefix) else { throw SessionStoreError.unsafeRolloutPath(url.path) }
        let resolvedRelative = relativePath(resolved, from: root).split(separator: "/").map(String.init)
        let resolvedExtension = resolvedRelative.last?.hasSuffix(".jsonl") == true || resolvedRelative.last?.hasSuffix(".jsonl.zst") == true
        guard resolvedRelative.count >= 2, allowed.contains(resolvedRelative[0]), resolvedExtension else { throw SessionStoreError.unsafeRolloutPath(url.path) }
        return resolved
    }

    private func resolveExisting(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if url.pathExtension == "jsonl" {
                let compressed = URL(fileURLWithPath: url.path + ".zst")
                return FileManager.default.fileExists(atPath: compressed.path) ? compressed.resolvingSymlinksInPath().standardizedFileURL : nil
            }
            if url.pathExtension == "zst", url.deletingPathExtension().pathExtension == "jsonl" {
                let plain = url.deletingPathExtension()
                return FileManager.default.fileExists(atPath: plain.path) ? plain.resolvingSymlinksInPath().standardizedFileURL : nil
            }
            return nil
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func validateTargets(_ sessions: [CodexSession], plans: [FilePlan], root: URL) throws -> [String: String] {
        let ids = sessions.map(\.id)
        guard Set(ids).count == ids.count else { throw SessionStoreError.deleteFailed("The selection contains a duplicate session identifier.") }
        guard FileManager.default.fileExists(atPath: paths.stateURL.path) else { throw SessionStoreError.deleteFailed("Codex state database is missing.") }
        let state = try CleanupSQLite(url: paths.stateURL, readOnly: true); defer { state.close() }
        guard try state.tableExists("threads") else { throw SessionStoreError.deleteFailed("Codex state database has no threads table.") }
        let quotedIDs = ids.map { "'\(CleanupSQLite.quote($0))'" }.joined(separator: ",")
        let found = try state.rowsText("SELECT id, COALESCE(rollout_path,'') FROM threads WHERE id IN (\(quotedIDs))")
        guard found.count == ids.count else { throw SessionStoreError.deleteFailed("The selection is stale: one or more sessions no longer exist in the state database.") }
        let primaryByID = Dictionary(grouping: plans, by: \.sessionID).compactMapValues { $0.first?.source.path }
        for session in sessions {
            guard let stored = found.first(where: { $0.0 == session.id })?.1 else {
                throw SessionStoreError.deleteFailed("Rollout path changed for session \(session.id); refresh before cleanup.")
            }
            if let expected = primaryByID[session.id],
               let validated = try? validateRolloutPath(URL(fileURLWithPath: stored).standardizedFileURL, root: root),
               let current = resolveExisting(validated) {
                guard current.path == expected else { throw SessionStoreError.deleteFailed("Rollout path changed for session \(session.id); refresh before cleanup.") }
            } else {
                guard sameRolloutFamily(stored, session.rolloutPath) else { throw SessionStoreError.deleteFailed("Rollout path changed for session \(session.id); refresh before cleanup.") }
            }
        }

        // A rollout file can be shared by another thread. Never move it while
        // leaving that surviving row pointing at the trash location.
        let plannedByPath = Dictionary(grouping: plans, by: { $0.source.path })
        let allRows = try state.rowsText("SELECT id, COALESCE(rollout_path,'') FROM threads WHERE rollout_path IS NOT NULL AND rollout_path <> ''")
        for planPath in plannedByPath.keys {
            let shared = allRows.filter { row in
                guard !ids.contains(row.0), let validated = try? validateRolloutPath(URL(fileURLWithPath: row.1).standardizedFileURL, root: root) else { return false }
                return resolveExisting(validated)?.path == planPath
            }
            if !shared.isEmpty { throw SessionStoreError.deleteFailed("Rollout file is still referenced by another session: \(planPath)") }
        }
        return Dictionary(uniqueKeysWithValues: found)
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    private func writeManifest(_ manifest: Manifest, to directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func restore(_ moved: [(source: URL, destination: URL)]) -> [String] {
        var errors: [String] = []
        for item in moved.reversed() where FileManager.default.fileExists(atPath: item.destination.path) {
            do {
                try FileManager.default.createDirectory(at: item.source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.destination, to: item.source)
            } catch { errors.append("\(item.source.path): \(error.localizedDescription)") }
        }
        return errors
    }

    private func deleteRows(_ ids: [String], sessions: [CodexSession], originalRolloutPaths: [String: String], progressStart: Int, progress: (CleanupProgress.Phase, Int, String?) -> Void) throws {
        let state = try CleanupSQLite(url: paths.stateURL, readOnly: false); defer { state.close() }
        progress(.deletingRows, progressStart, "正在打开并锁定会话数据库")
        let sidecars: [(URL, String)] = [(paths.historyURL, "historydb"), (paths.logsURL, "logsdb"), (paths.goalsURL, "goalsdb"), (paths.queueURL, "queuedb")].filter { FileManager.default.fileExists(atPath: $0.0.path) }
        for (url, alias) in sidecars { try state.exec("ATTACH DATABASE '\(CleanupSQLite.quote(url.path))' AS \(alias)") }
        defer { for (_, alias) in sidecars.reversed() { try? state.exec("DETACH DATABASE \(alias)") } }
        var transactionStarted = false
        do {
            try state.exec("BEGIN IMMEDIATE")
            transactionStarted = true
            try verifySelectionUnchanged(sessions, originalRolloutPaths: originalRolloutPaths, state: state)
            var completed = progressStart
            for id in ids {
                try deleteRows(for: id, state: state, sidecars: sidecars)
                completed += 1
                progress(.deletingRows, completed, "已清理 session \(id)")
            }
            progress(.verifying, completed, "正在验证数据库记录")
            try verifyRemoved(ids, state: state, sidecars: sidecars)
            completed += 1
            progress(.verifying, completed, "已验证选中记录及关联表")
            // Keep this below 100%; completion is emitted only after COMMIT succeeds.
            progress(.committing, completed, "正在提交数据库事务")
            try state.exec("COMMIT")
            transactionStarted = false
            completed += 1
            progress(.completed, completed, "数据库事务已提交")
        } catch let transactionError {
            guard transactionStarted else { throw transactionError }
            do { try state.exec("ROLLBACK") }
            catch let rollbackError {
                throw SessionStoreError.deleteFailed("\(transactionError.localizedDescription); rollback failed: \(rollbackError.localizedDescription)")
            }
            throw transactionError
        }
    }

    private func verifySelectionUnchanged(_ sessions: [CodexSession], originalRolloutPaths: [String: String], state: CleanupSQLite) throws {
        let ids = sessions.map(\.id)
        let quotedIDs = ids.map { "'\(CleanupSQLite.quote($0))'" }.joined(separator: ",")
        let rows = try state.rowsText("SELECT id, COALESCE(rollout_path,'') FROM threads WHERE id IN (\(quotedIDs))")
        guard rows.count == ids.count else { throw SessionStoreError.deleteFailed("The selection changed while preparing cleanup; nothing was removed.") }
        for session in sessions {
            guard let stored = rows.first(where: { $0.0 == session.id })?.1 else { throw SessionStoreError.deleteFailed("The selection changed while preparing cleanup; nothing was removed.") }
            guard normalizeStoredPath(stored) == normalizeStoredPath(originalRolloutPaths[session.id] ?? "") else {
                throw SessionStoreError.deleteFailed("Rollout path changed for session \(session.id); nothing was removed.")
            }
        }
        let allRows = try state.rowsText("SELECT id, COALESCE(rollout_path,'') FROM threads WHERE rollout_path IS NOT NULL AND rollout_path <> ''")
        let selectedFamilies = Set(sessions.compactMap { originalRolloutPaths[$0.id].map { rolloutFamily($0) } })
        for source in selectedFamilies {
            let shared = allRows.contains { row in
                guard !ids.contains(row.0) else { return false }
                return rolloutFamily(row.1) == source
            }
            if shared { throw SessionStoreError.deleteFailed("Rollout file is still referenced by another session; nothing was removed.") }
        }
    }

    private func normalizeStoredPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func rolloutFamily(_ raw: String) -> String {
        let normalized = normalizeStoredPath(raw)
        let url = URL(fileURLWithPath: normalized)
        if url.pathExtension == "zst", url.deletingPathExtension().pathExtension == "jsonl" { return url.deletingPathExtension().path }
        return normalized
    }

    private func sameRolloutFamily(_ lhs: String, _ rhs: String) -> Bool {
        let left = rolloutFamilySet(lhs)
        let right = rolloutFamilySet(rhs)
        return !left.isDisjoint(with: right)
    }

    private func rolloutFamilySet(_ raw: String) -> Set<String> {
        let normalized = normalizeStoredPath(raw)
        let normalizedURL = URL(fileURLWithPath: normalized)
        var values = Set([rolloutFamily(normalized)])
        let resolved = normalizedURL.resolvingSymlinksInPath().standardizedFileURL.path
        values.insert(rolloutFamily(resolved))
        return values
    }

    private func deleteRows(for id: String, state: CleanupSQLite, sidecars: [(URL, String)]) throws {
        let q = CleanupSQLite.quote(id)
        if try state.tableExists("thread_spawn_edges") { try state.exec("DELETE FROM thread_spawn_edges WHERE parent_thread_id = '\(q)' OR child_thread_id = '\(q)'") }
        if try state.tableExists("thread_read_receipts") { try state.exec("DELETE FROM thread_read_receipts WHERE thread_id = '\(q)'") }
        for table in ["thread_dynamic_tools", "thread_attachments", "guardian_review_feedback"] where try state.tableExists(table) {
            try state.exec("DELETE FROM \(table) WHERE thread_id = '\(q)'")
        }
        if try state.tableExists("threads") { try state.exec("DELETE FROM threads WHERE id = '\(q)'") }
        if sidecars.contains(where: { $0.1 == "historydb" }) {
            for table in ["thread_items", "thread_turns", "thread_history_projection_state", "thread_realtime_items"] where try state.tableExists("historydb", table) { try state.exec("DELETE FROM historydb.\(table) WHERE thread_id = '\(q)'") }
        }
        if sidecars.contains(where: { $0.1 == "logsdb" }), try state.tableExists("logsdb", "logs") { try state.exec("DELETE FROM logsdb.logs WHERE thread_id = '\(q)'") }
        if sidecars.contains(where: { $0.1 == "goalsdb" }) {
            for table in ["thread_goal_continuation_deferrals", "thread_goals"] where try state.tableExists("goalsdb", table) { try state.exec("DELETE FROM goalsdb.\(table) WHERE thread_id = '\(q)'") }
        }
        if sidecars.contains(where: { $0.1 == "queuedb" }) {
            for table in ["queued_items", "queued_thread_revisions"] where try state.tableExists("queuedb", table) { try state.exec("DELETE FROM queuedb.\(table) WHERE thread_id = '\(q)'") }
        }
    }

    private func verifyRemoved(_ ids: [String], state: CleanupSQLite, sidecars: [(URL, String)]) throws {
        let quoted = ids.map { "'\(CleanupSQLite.quote($0))'" }.joined(separator: ",")
        guard !quoted.isEmpty else { return }
        let checks: [(String, String)] = [
            ("threads", "id IN (\(quoted))"),
            ("thread_spawn_edges", "parent_thread_id IN (\(quoted)) OR child_thread_id IN (\(quoted))"),
            ("thread_read_receipts", "thread_id IN (\(quoted))"),
            ("thread_dynamic_tools", "thread_id IN (\(quoted))"),
            ("thread_attachments", "thread_id IN (\(quoted))"),
            ("guardian_review_feedback", "thread_id IN (\(quoted))")
        ]
        for (table, predicate) in checks where try state.tableExists(table) { guard try state.scalarInt("SELECT COUNT(*) FROM \(table) WHERE \(predicate)") == 0 else { throw SessionStoreError.deleteFailed("Rows for selected sessions remain in \(table).") } }
        let attachedChecks: [(String, String, String)] = [
            ("historydb", "thread_items", "thread_id"), ("historydb", "thread_turns", "thread_id"), ("historydb", "thread_history_projection_state", "thread_id"), ("historydb", "thread_realtime_items", "thread_id"),
            ("logsdb", "logs", "thread_id"), ("goalsdb", "thread_goal_continuation_deferrals", "thread_id"), ("goalsdb", "thread_goals", "thread_id"), ("queuedb", "queued_items", "thread_id"), ("queuedb", "queued_thread_revisions", "thread_id")
        ]
        for (alias, table, column) in attachedChecks where try sidecars.contains(where: { $0.1 == alias }) && state.tableExists(alias, table) {
            guard try state.scalarInt("SELECT COUNT(*) FROM \(alias).\(table) WHERE \(column) IN (\(quoted))") == 0 else { throw SessionStoreError.deleteFailed("Rows for selected sessions remain in \(alias).\(table).") }
        }
    }
}

private final class CleanupSQLite {
    fileprivate var handle: OpaquePointer?

    init(url: URL, readOnly: Bool) throws {
        var pointer: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let pointer { sqlite3_close(pointer) }
            throw SessionStoreError.cannotOpen(url, message)
        }
        handle = pointer
        sqlite3_busy_timeout(pointer, 5_000)
        do { try exec(readOnly ? "PRAGMA query_only = ON" : "PRAGMA foreign_keys = ON") }
        catch { close(); throw error }
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
    func scalarInt(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw SessionStoreError.deleteFailed(String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SessionStoreError.deleteFailed(String(cString: sqlite3_errmsg(handle))) }
        return sqlite3_column_int64(statement, 0)
    }
    func rowsText(_ sql: String) throws -> [(String, String)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw SessionStoreError.deleteFailed(String(cString: sqlite3_errmsg(handle))) }
        defer { sqlite3_finalize(statement) }
        var rows: [(String, String)] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw SessionStoreError.deleteFailed(String(cString: sqlite3_errmsg(handle))) }
            let id = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let path = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            rows.append((id, path))
        }
        return rows
    }
    func tableExists(_ table: String) throws -> Bool { try tableExists("main", table) }
    func tableExists(_ schema: String, _ table: String) throws -> Bool {
        try scalarInt("SELECT COUNT(*) FROM \(schema).sqlite_master WHERE type='table' AND name='\(Self.quote(table))'") == 1
    }
    static func quote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
}
