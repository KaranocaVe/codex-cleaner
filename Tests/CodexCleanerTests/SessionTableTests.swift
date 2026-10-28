import AppKit
import XCTest
@testable import CodexCleaner

final class SessionTableTests: XCTestCase {
    @MainActor
    func testColumnsFitViewportAndResetHorizontalOffsetAfterResize() {
        let scroll = SessionTableScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 400))
        let table = BrowserTableView()
        table.intercellSpacing.width = 10
        for (index, width) in [330.0, 130.0, 125.0, 85.0, 55.0].enumerated() {
            let column = NSTableColumn(identifier: .init("\(index)"))
            column.minWidth = index == 0 ? 200 : width
            column.width = width
            table.addTableColumn(column)
        }
        scroll.documentView = table
        scroll.layout()
        let totalWidth = table.tableColumns.reduce(0) { $0 + $1.width } + 50
        XCTAssertLessThanOrEqual(totalWidth, scroll.contentSize.width + 0.5)
        scroll.setFrameSize(NSSize(width: 580, height: 400))
        scroll.layout()
        XCTAssertGreaterThan(table.frame.width, scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: 30, y: 0))
        scroll.setFrameSize(NSSize(width: 800, height: 400))
        scroll.layout()
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, accuracy: 0.5)
    }

    @MainActor
    func testSelectAllAndEscapeFromEmptySelection() throws {
        let source = TableRows(count: 8)
        let table = BrowserTableView()
        table.dataSource = source
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        table.reloadData()
        XCTAssertEqual(table.numberOfRows, 8)
        XCTAssertEqual(table.numberOfSelectedRows, 0)
        table.keyDown(with: try key("a", code: 0, modifiers: .command))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integersIn: 0..<8))
        table.keyDown(with: try key("\u{1b}", code: 53))
        XCTAssertEqual(table.numberOfSelectedRows, 0)
    }

    @MainActor
    func testNativeRangeAndAdditiveSelection() {
        let source = TableRows(count: 9)
        let table = BrowserTableView()
        table.dataSource = source
        table.allowsMultipleSelection = true
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integersIn: 2...5), byExtendingSelection: false)
        table.selectRowIndexes(IndexSet(integer: 8), byExtendingSelection: true)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([2, 3, 4, 5, 8]))
        table.deselectRow(3)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([2, 4, 5, 8]))
    }

    @MainActor
    func testReviewShortcutRequiresSelection() throws {
        let source = TableRows(count: 2)
        let table = BrowserTableView()
        table.dataSource = source
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        table.reloadData()
        var invocations = 0
        table.review = { invocations += 1 }
        table.keyDown(with: try key("\u{7f}", code: 51, modifiers: .command))
        XCTAssertEqual(invocations, 0)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.keyDown(with: try key("\u{7f}", code: 51, modifiers: .command))
        XCTAssertEqual(invocations, 1)
    }

    @MainActor
    func testSpacePreviewsFocusedSelectionAndDoesNothingWithoutSelection() throws {
        let source = TableRows(count: 2)
        let table = BrowserTableView()
        table.dataSource = source
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        table.reloadData()
        var invocations = 0
        table.preview = { invocations += 1 }
        table.keyDown(with: try key(" ", code: 49))
        XCTAssertEqual(invocations, 0)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.keyDown(with: try key(" ", code: 49))
        XCTAssertEqual(invocations, 1)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
    }

    @MainActor
    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }
}

@MainActor
private final class TableRows: NSObject, NSTableViewDataSource {
    let count: Int
    init(count: Int) { self.count = count }
    func numberOfRows(in tableView: NSTableView) -> Int { count }
}
