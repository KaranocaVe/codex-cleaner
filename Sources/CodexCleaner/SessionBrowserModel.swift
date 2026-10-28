import Foundation

/// The ordering used by the session browser.  The tie breaker is always the
/// persistent session id, which keeps row movement deterministic between
/// refreshes and makes selection state stable.
enum BrowserSort: String, CaseIterable, Hashable, Sendable {
    case recent
    case largest
    case turns
    case oldest
    case smallest
    case fewestTurns
    case titleAscending
    case titleDescending
    case projectAscending
    case projectDescending

    var label: String {
        switch self {
        case .recent: "最近更新"; case .oldest: "最早更新"
        case .largest: "体积从大到小"; case .smallest: "体积从小到大"
        case .turns: "轮次从多到少"; case .fewestTurns: "轮次从少到多"
        case .titleAscending: "标题升序"; case .titleDescending: "标题降序"
        case .projectAscending: "项目升序"; case .projectDescending: "项目降序"
        }
    }

    func compare(_ lhs: CodexSession, _ rhs: CodexSession) -> Bool {
        switch self {
        case .recent:
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        case .largest:
            if lhs.byteCount != rhs.byteCount { return lhs.byteCount > rhs.byteCount }
        case .turns:
            if lhs.turnCount != rhs.turnCount { return lhs.turnCount > rhs.turnCount }
        case .oldest:
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        case .smallest:
            if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
        case .fewestTurns:
            if lhs.turnCount != rhs.turnCount { return lhs.turnCount < rhs.turnCount }
        case .titleAscending, .titleDescending:
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison != .orderedSame { return self == .titleAscending ? comparison == .orderedAscending : comparison == .orderedDescending }
        case .projectAscending, .projectDescending:
            let comparison = lhs.project.localizedStandardCompare(rhs.project)
            if comparison != .orderedSame { return self == .projectAscending ? comparison == .orderedAscending : comparison == .orderedDescending }
        }
        return lhs.id < rhs.id
    }
}

/// Coarse library scopes used by the sidebar. A project value is matched
/// against `projectKey` exactly; this prevents two projects with the same
/// display name from being merged accidentally.
enum BrowserScope: Hashable, Sendable {
    case all
    case recent
    case idle
    case archived
    case pinned
    case subagents
    case missing
    case project(String)

    func matches(_ session: CodexSession, now: Date = Date()) -> Bool {
        switch self {
        case .all: return true
        case .recent: return !session.archived && session.updatedAt >= now.addingTimeInterval(-15 * 60)
        case .idle: return !session.archived && session.updatedAt < now.addingTimeInterval(-15 * 60)
        case .archived: return session.archived
        case .pinned: return session.isPinned
        case .subagents: return session.isSubagent
        case .missing: return !session.rolloutPathExists
        case let .project(key): return session.projectKey == key
        }
    }
}

/// A single row in either flat or outline mode. `id` is the Codex thread id,
/// never an array offset, so AppKit/SwiftUI selection survives refreshes.
struct BrowserRow: Identifiable, Hashable, Sendable {
    let session: CodexSession
    let depth: Int
    let parentID: String?
    let childCount: Int
    let isExpanded: Bool
    let displayedByteCount: Int64
    let familySessionCount: Int
    let includesDescendants: Bool

    var id: String { session.id }
    var hasChildren: Bool { childCount > 0 }
    var indent: Int { depth }
}

/// Immutable, UI-independent result of filtering and arranging sessions.
struct BrowserSnapshot: Sendable {
    /// The complete source used to build this snapshot. Keeping it here makes
    /// descendant expansion independent from the current filter.
    let allSessions: [CodexSession]
    let matching: [CodexSession]
    let rows: [BrowserRow]
    let visibleIDs: Set<String>
    let matchingIDs: Set<String>
    let bytes: Int64
    let familyTotalsByID: [String: SessionFamilyTotal]
    let scope: BrowserScope
    let sort: BrowserSort
    let treeMode: Bool

    /// Build a snapshot from a point-in-time session array. All graph work is
    /// linear in the number of matching sessions (apart from sorting).
    static func build(
        sessions: [CodexSession],
        filter: SessionFilter = SessionFilter(),
        scope: BrowserScope = .all,
        sort: BrowserSort = .recent,
        treeMode: Bool = false,
        expandedIDs: Set<String> = [],
        now: Date = Date()
    ) -> BrowserSnapshot {
        let familyTotalsByID = makeFamilyTotals(sessions: sessions)
        let filtered = sessions.filter { filter.matches($0) && scope.matches($0, now: now) }
        let matching = filtered.sorted { compare($0, $1, sort: sort, familyTotalsByID: familyTotalsByID, treeMode: treeMode) }
        let matchingIDs = Set(matching.map(\.id))
        let rows = treeMode
            ? makeTreeRows(matching: matching, matchingIDs: matchingIDs, sort: sort, expandedIDs: expandedIDs, familyTotalsByID: familyTotalsByID)
            : matching.map {
                BrowserRow(session: $0, depth: 0, parentID: nil, childCount: 0, isExpanded: false,
                           displayedByteCount: $0.byteCount, familySessionCount: 1, includesDescendants: false)
            }
        var seenIDs = Set<String>()
        let bytes = matching.reduce(into: Int64(0)) { total, session in
            guard seenIDs.insert(session.id).inserted else { return }
            total += session.byteCount
        }
        return BrowserSnapshot(
            allSessions: sessions,
            matching: matching,
            rows: rows,
            visibleIDs: Set(rows.map(\.id)),
            matchingIDs: matchingIDs,
            bytes: bytes,
            familyTotalsByID: familyTotalsByID,
            scope: scope,
            sort: sort,
            treeMode: treeMode
        )
    }

    /// Return the unique sessions represented by ids, optionally including all
    /// descendants in the complete source graph. Parent/child overlap is
    /// intentionally deduplicated, which keeps multi-select totals stable.
    func total(for ids: Set<String>, includingDescendants: Bool) -> SessionFamilyTotal {
        let byID = Self.uniqueSessionsByID(allSessions)
        var included = Set<String>()
        var queue: [String] = []
        for id in ids where byID[id] != nil {
            if included.insert(id).inserted { queue.append(id) }
        }
        guard includingDescendants else {
            return Self.total(for: included, in: byID)
        }
        let children = Self.childrenByParent(byID: byID)
        while let parent = queue.popLast() {
            for child in children[parent] ?? [] where included.insert(child).inserted {
                queue.append(child)
            }
        }
        return Self.total(for: included, in: byID)
    }

    /// All descendants are resolved against the complete source array, not
    /// the current filter. This makes a parent selection safe across filter
    /// changes and lets the UI preview the actual deletion cascade.
    func descendants(of id: String, in sessions: [CodexSession]) -> [CodexSession] {
        let byParent = Dictionary(grouping: sessions.compactMap { session -> (String, CodexSession)? in
            guard let parent = session.parentThreadID else { return nil }
            return (parent, session)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        var seen = Set<String>([id])
        var queue = [id]
        var result: [CodexSession] = []
        while let parent = queue.popLast() {
            for child in byParent[parent] ?? [] {
                guard seen.insert(child.id).inserted else { continue }
                result.append(child)
                queue.append(child.id)
            }
        }
        return result.sorted(by: sort.compare)
    }

    /// Return all descendants of a set of selected parents, using the source
    /// array captured when this snapshot was built. The selected ids themselves
    /// are excluded from the result.
    func descendants(of ids: Set<String>) -> Set<String> {
        let byParent = Dictionary(grouping: allSessions.compactMap { session -> (String, String)? in
            guard let parent = session.parentThreadID else { return nil }
            return (parent, session.id)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        var result = Set<String>()
        var seen = ids
        var queue = Array(ids)
        while let parent = queue.popLast() {
            for child in byParent[parent] ?? [] where seen.insert(child).inserted {
                if !ids.contains(child) { result.insert(child) }
                queue.append(child)
            }
        }
        result.subtract(ids)
        return result
    }

    func descendantIDs(of id: String, in sessions: [CodexSession]) -> Set<String> {
        Set(descendants(of: id, in: sessions).map(\.id))
    }

    /// Selection is constrained to rows currently visible under filtering and
    /// tree expansion. The caller can use `matchingIDs` when collapsed rows
    /// should remain selected while only a filter is being edited.
    func visibleSelection(from selectedIDs: Set<String>) -> Set<String> {
        selectedIDs.intersection(visibleIDs)
    }

    private static func makeTreeRows(
        matching: [CodexSession],
        matchingIDs: Set<String>,
        sort: BrowserSort,
        expandedIDs: Set<String>,
        familyTotalsByID: [String: SessionFamilyTotal]
    ) -> [BrowserRow] {
        var byID = [String: CodexSession]()
        for session in matching where byID[session.id] == nil { byID[session.id] = session }
        let children = Dictionary(grouping: matching.compactMap { session -> (String, CodexSession)? in
            guard let parent = session.parentThreadID, matchingIDs.contains(parent), parent != session.id else { return nil }
            return (parent, session)
        }, by: { $0.0 }).mapValues {
            $0.map(\.1).sorted { compare($0, $1, sort: sort, familyTotalsByID: familyTotalsByID, treeMode: true) }
        }

        let ordered = matching // Already sorted by the requested order.
        let roots = ordered.filter { session in
            guard let parent = session.parentThreadID else { return true }
            return !matchingIDs.contains(parent) || parent == session.id
        }

        var rows: [BrowserRow] = []
        var visited = Set<String>()

        // Marking descendants visited even while collapsed prevents a cycle or
        // hidden child from reappearing later as a second synthetic root.
        func walk(_ session: CodexSession, depth: Int, parentID: String?, path: Set<String>, visible: Bool) {
            guard !path.contains(session.id), visited.insert(session.id).inserted else { return }
            let childRows = children[session.id] ?? []
            let expanded = expandedIDs.contains(session.id) && !childRows.isEmpty
            if visible {
                let family = familyTotalsByID[session.id] ?? SessionFamilyTotal(byteCount: session.byteCount, sessionCount: 1)
                rows.append(BrowserRow(session: session, depth: depth, parentID: parentID,
                                       childCount: childRows.count, isExpanded: expanded,
                                       displayedByteCount: family.byteCount, familySessionCount: family.sessionCount,
                                       includesDescendants: true))
            }
            var nextPath = path
            nextPath.insert(session.id)
            for child in childRows {
                walk(child, depth: depth + 1, parentID: session.id, path: nextPath, visible: visible && expanded)
            }
        }

        for root in roots { walk(root, depth: 0, parentID: nil, path: [], visible: true) }
        // A parent cycle has no natural root. Recover each still-unvisited
        // component as a root so no session silently disappears.
        for session in ordered where !visited.contains(session.id) {
            walk(session, depth: 0, parentID: nil, path: [], visible: true)
        }
        // `byID` keeps the compiler honest about the uniqueness invariant and
        // documents why duplicate ids cannot produce duplicate rows.
        _ = byID
        return rows
    }

    private static func compare(
        _ lhs: CodexSession,
        _ rhs: CodexSession,
        sort: BrowserSort,
        familyTotalsByID: [String: SessionFamilyTotal],
        treeMode: Bool
    ) -> Bool {
        guard treeMode, (sort == .largest || sort == .smallest) else { return sort.compare(lhs, rhs) }
        let left = familyTotalsByID[lhs.id]?.byteCount ?? lhs.byteCount
        let right = familyTotalsByID[rhs.id]?.byteCount ?? rhs.byteCount
        if left != right { return sort == .largest ? left > right : left < right }
        return lhs.id < rhs.id
    }

    private static func uniqueSessionsByID(_ sessions: [CodexSession]) -> [String: CodexSession] {
        var result = [String: CodexSession](minimumCapacity: sessions.count)
        for session in sessions where result[session.id] == nil { result[session.id] = session }
        return result
    }

    private static func childrenByParent(byID: [String: CodexSession]) -> [String: [String]] {
        var result = [String: [String]]()
        for session in byID.values {
            guard let parent = session.parentThreadID, byID[parent] != nil else { continue }
            result[parent, default: []].append(session.id)
        }
        return result
    }

    private static func total(for ids: Set<String>, in byID: [String: CodexSession]) -> SessionFamilyTotal {
        ids.reduce(into: SessionFamilyTotal(byteCount: 0, sessionCount: 0)) { result, id in
            guard let session = byID[id] else { return }
            result.byteCount += session.byteCount
            result.sessionCount += 1
        }
    }

    /// Compute family totals once using strongly connected components followed
    /// by a DAG postorder. This is linear in sessions plus edges for ordinary
    /// parent forests and handles self edges/cycles without repeated walks.
    private static func makeFamilyTotals(sessions: [CodexSession]) -> [String: SessionFamilyTotal] {
        let byID = Self.uniqueSessionsByID(sessions)
        let children = Self.childrenByParent(byID: byID)
        var nextIndex = 0
        var indices = [String: Int](), lowlink = [String: Int](), stack = [String](), onStack = Set<String>()
        var components = [[String]]()

        func visit(_ id: String) {
            indices[id] = nextIndex; lowlink[id] = nextIndex; nextIndex += 1
            stack.append(id); onStack.insert(id)
            for child in children[id] ?? [] {
                if indices[child] == nil {
                    visit(child); lowlink[id] = min(lowlink[id]!, lowlink[child]!)
                } else if onStack.contains(child) {
                    lowlink[id] = min(lowlink[id]!, indices[child]!)
                }
            }
            guard lowlink[id] == indices[id] else { return }
            var component: [String] = []
            repeat {
                let member = stack.removeLast(); onStack.remove(member); component.append(member)
            } while component.last != id
            components.append(component)
        }
        for id in byID.keys.sorted() where indices[id] == nil { visit(id) }

        var componentOf = [String: Int]()
        for (index, component) in components.enumerated() {
            for id in component { componentOf[id] = index }
        }
        var componentChildren = Array(repeating: Set<Int>(), count: components.count)
        for (parent, childIDs) in children {
            guard let parentComponent = componentOf[parent] else { continue }
            for child in childIDs {
                guard let childComponent = componentOf[child], childComponent != parentComponent else { continue }
                componentChildren[parentComponent].insert(childComponent)
            }
        }
        var memo = [Int: SessionFamilyTotal]()
        func resolve(_ component: Int) -> SessionFamilyTotal {
            if let cached = memo[component] { return cached }
            var result = components[component].reduce(into: SessionFamilyTotal(byteCount: 0, sessionCount: 0)) { total, id in
                guard let session = byID[id] else { return }
                total.byteCount += session.byteCount; total.sessionCount += 1
            }
            for child in componentChildren[component] {
                let descendant = resolve(child)
                result.byteCount += descendant.byteCount; result.sessionCount += descendant.sessionCount
            }
            memo[component] = result
            return result
        }
        var totals = [String: SessionFamilyTotal](minimumCapacity: byID.count)
        for id in byID.keys {
            if let component = componentOf[id] { totals[id] = resolve(component) }
        }
        return totals
    }
}

struct SessionFamilyTotal: Hashable, Sendable {
    var byteCount: Int64
    var sessionCount: Int

    init(byteCount: Int64, sessionCount: Int) {
        self.byteCount = byteCount
        self.sessionCount = sessionCount
    }
}

/// Mutable convenience wrapper for SwiftUI views that want to own filter and
/// expansion state. The value type keeps updates predictable and testable.
struct SessionBrowserModel: Sendable {
    var sessions: [CodexSession]
    var filter = SessionFilter()
    var scope: BrowserScope = .all
    var sort: BrowserSort = .recent
    var treeMode = false
    var expandedIDs = Set<String>()

    var snapshot: BrowserSnapshot {
        BrowserSnapshot.build(sessions: sessions, filter: filter, scope: scope, sort: sort, treeMode: treeMode, expandedIDs: expandedIDs)
    }

    mutating func toggleExpansion(_ id: String) {
        if !expandedIDs.insert(id).inserted { expandedIDs.remove(id) }
    }
}
