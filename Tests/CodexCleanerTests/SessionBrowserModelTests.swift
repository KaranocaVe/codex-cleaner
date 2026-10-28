import XCTest
@testable import CodexCleaner

final class SessionBrowserModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func session(
        _ id: String,
        title: String = "Untitled",
        project: String = "Shared",
        projectKey: String? = nil,
        updated: TimeInterval = 2_000_000_000,
        archived: Bool = false,
        pinned: Bool = false,
        subagent: Bool = false,
        missing: Bool = false,
        parent: String? = nil,
        bytes: Int64 = 10,
        turns: Int = 1
    ) -> CodexSession {
        let date = Date(timeIntervalSince1970: updated)
        return CodexSession(
            id: id, title: title, preview: title, cwd: "/tmp/\(id)", project: project,
            source: "", model: "model",
            modelProvider: "provider", createdAt: date, updatedAt: date, archived: archived,
            isPinned: pinned, tokensUsed: 0, itemCount: 1, turnCount: turns, byteCount: bytes,
            rolloutPath: missing ? "" : "/tmp/\(id).jsonl", projectKey: projectKey ?? project,
            rolloutPathExists: !missing, originator: "", isSubagent: subagent,
            parentThreadID: parent, registeredProjectID: nil, registeredProjectRoot: nil
        )
    }

    func testProjectScopeUsesStableKeyWhenDisplayNamesMatch() {
        let sessions = [
            session("one", projectKey: "registered:p1"),
            session("two", projectKey: "registered:p2"),
            session("three", project: "Other", projectKey: "other")
        ]
        let snapshot = BrowserSnapshot.build(sessions: sessions, scope: .project("registered:p2"), now: now)
        XCTAssertEqual(snapshot.matching.map(\.id), ["two"])
    }

    func testScopesPartitionSessions() {
        let sessions = [
            session("active", updated: now.timeIntervalSince1970 - 60),
            session("idle", updated: now.timeIntervalSince1970 - 3600),
            session("archived", archived: true),
            session("pinned", pinned: true),
            session("agent", subagent: true),
            session("missing", missing: true)
        ]
        XCTAssertEqual(Set(BrowserSnapshot.build(sessions: sessions, scope: .recent, now: now).matching.map(\.id)), ["active", "pinned", "agent", "missing"])
        XCTAssertEqual(BrowserSnapshot.build(sessions: sessions, scope: .idle, now: now).matching.map(\.id), ["idle"])
        XCTAssertEqual(BrowserSnapshot.build(sessions: sessions, scope: .archived, now: now).matching.map(\.id), ["archived"])
        XCTAssertEqual(BrowserSnapshot.build(sessions: sessions, scope: .pinned, now: now).matching.map(\.id), ["pinned"])
        XCTAssertEqual(BrowserSnapshot.build(sessions: sessions, scope: .subagents, now: now).matching.map(\.id), ["agent"])
        XCTAssertEqual(BrowserSnapshot.build(sessions: sessions, scope: .missing, now: now).matching.map(\.id), ["missing"])
    }

    func testSortingAndStableTieBreaker() {
        let sessions = [session("b", bytes: 5, turns: 2), session("a", bytes: 5, turns: 2), session("c", bytes: 20, turns: 1)]
        XCTAssertEqual(BrowserSnapshot.build(sessions: sessions, sort: .largest, now: now).matching.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(BrowserSnapshot.build(sessions: sessions, sort: .turns, now: now).matching.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(BrowserSnapshot.build(sessions: sessions, sort: .smallest, now: now).matching.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(BrowserSnapshot.build(sessions: sessions, sort: .fewestTurns, now: now).matching.map(\.id), ["c", "a", "b"])
        let named = [session("z", title: "Alpha", project: "Zeta"), session("a", title: "Beta", project: "Alpha")]
        for (sort, expected) in [(BrowserSort.titleAscending, ["z", "a"]), (.titleDescending, ["a", "z"]),
                                 (.projectAscending, ["a", "z"]), (.projectDescending, ["z", "a"])] {
            XCTAssertEqual(BrowserSnapshot.build(sessions: named, sort: sort, now: now).matching.map(\.id), expected)
        }
    }

    func testTreeExpansionAndCycleRecoveryNeverDropsRows() {
        let sessions = [
            session("parent"),
            session("child", parent: "parent"),
            session("cycle-a", parent: "cycle-b"),
            session("cycle-b", parent: "cycle-a"),
            session("orphan", parent: "deleted-parent")
        ]
        let collapsed = BrowserSnapshot.build(sessions: sessions, treeMode: true, now: now)
        XCTAssertEqual(Set(collapsed.rows.map(\.id)), ["cycle-a", "orphan", "parent"])
        let expanded = BrowserSnapshot.build(sessions: sessions, treeMode: true, expandedIDs: Set(sessions.map(\.id)), now: now)
        XCTAssertEqual(Set(expanded.rows.map(\.id)), Set(sessions.map(\.id)))
        XCTAssertEqual(expanded.rows.first(where: { $0.id == "child" })?.depth, 1)
    }

    func testSelectionVisibilityAndDescendantsIgnoreCurrentFilter() {
        let sessions = [session("parent", title: "keep"), session("child", title: "hidden", parent: "parent"), session("other", title: "other")]
        var filter = SessionFilter(); filter.query = "keep"
        let snapshot = BrowserSnapshot.build(sessions: sessions, filter: filter, treeMode: true, now: now)
        XCTAssertEqual(snapshot.visibleSelection(from: ["parent", "child"]), ["parent"])
        XCTAssertEqual(snapshot.descendants(of: ["parent"]), ["child"])
    }

    func testTreeRowsAggregateThreeLevelsAndKeepDescendantsAfterFiltering() {
        let sessions = [
            session("root", title: "root", bytes: 5),
            session("child", title: "child", parent: "root", bytes: 7),
            session("grand", title: "grand", project: "Other", parent: "child", bytes: 11),
            session("unrelated", bytes: 3)
        ]
        let expanded = Set(sessions.map(\.id))
        let snapshot = BrowserSnapshot.build(sessions: sessions, treeMode: true, expandedIDs: expanded, now: now)
        XCTAssertEqual(snapshot.familyTotalsByID["root"], SessionFamilyTotal(byteCount: 23, sessionCount: 3))
        XCTAssertEqual(snapshot.rows.first(where: { $0.id == "root" })?.displayedByteCount, 23)
        XCTAssertEqual(snapshot.rows.first(where: { $0.id == "root" })?.familySessionCount, 3)
        XCTAssertTrue(snapshot.rows.first(where: { $0.id == "root" })?.includesDescendants == true)

        var filter = SessionFilter(); filter.query = "root"
        let filtered = BrowserSnapshot.build(sessions: sessions, filter: filter, treeMode: true, now: now)
        XCTAssertEqual(filtered.rows.map(\.id), ["root"])
        XCTAssertEqual(filtered.rows[0].displayedByteCount, 23)
        XCTAssertEqual(filtered.rows[0].familySessionCount, 3)
    }

    func testTreeSizeSortUsesFamilyTotalsWhileFlatSizeSortUsesOwnBytes() {
        let sessions = [
            session("root", bytes: 5),
            session("child", parent: "root", bytes: 100),
            session("other", bytes: 50)
        ]
        let expanded = Set(sessions.map(\.id))
        let tree = BrowserSnapshot.build(sessions: sessions, sort: .largest, treeMode: true, expandedIDs: expanded, now: now)
        XCTAssertEqual(tree.rows.map(\.id), ["root", "child", "other"])
        let ascending = BrowserSnapshot.build(sessions: sessions, sort: .smallest, treeMode: true, now: now)
        XCTAssertEqual(ascending.rows.map(\.id), ["other", "root"])
        let flat = BrowserSnapshot.build(sessions: sessions, sort: .largest, now: now)
        XCTAssertEqual(flat.rows.map(\.id), ["child", "other", "root"])
        XCTAssertEqual(flat.rows[0].displayedByteCount, 100)
        XCTAssertFalse(flat.rows[0].includesDescendants)
    }

    func testSelectedParentAndChildAreDeduplicatedInFamilyTotal() {
        let sessions = [
            session("root", bytes: 5),
            session("child", parent: "root", bytes: 7),
            session("grand", parent: "child", bytes: 11)
        ]
        let snapshot = BrowserSnapshot.build(sessions: sessions, now: now)
        XCTAssertEqual(snapshot.total(for: ["root", "child"], includingDescendants: true), SessionFamilyTotal(byteCount: 23, sessionCount: 3))
        XCTAssertEqual(snapshot.total(for: ["root", "child"], includingDescendants: false), SessionFamilyTotal(byteCount: 12, sessionCount: 2))
        XCTAssertEqual(snapshot.bytes, 23)
    }

    func testFamilyTotalsHandleCyclesSelfEdgesAndIsolatedParents() {
        let sessions = [
            session("a", parent: "b", bytes: 5),
            session("b", parent: "a", bytes: 7),
            session("self", parent: "self", bytes: 11),
            session("orphan", parent: "missing", bytes: 13)
        ]
        let snapshot = BrowserSnapshot.build(sessions: sessions, treeMode: true, expandedIDs: Set(sessions.map(\.id)), now: now)
        XCTAssertEqual(snapshot.familyTotalsByID["a"], SessionFamilyTotal(byteCount: 12, sessionCount: 2))
        XCTAssertEqual(snapshot.familyTotalsByID["b"], SessionFamilyTotal(byteCount: 12, sessionCount: 2))
        XCTAssertEqual(snapshot.familyTotalsByID["self"], SessionFamilyTotal(byteCount: 11, sessionCount: 1))
        XCTAssertEqual(snapshot.familyTotalsByID["orphan"], SessionFamilyTotal(byteCount: 13, sessionCount: 1))
        XCTAssertEqual(Set(snapshot.rows.map(\.id)), Set(sessions.map(\.id)))
    }
}
