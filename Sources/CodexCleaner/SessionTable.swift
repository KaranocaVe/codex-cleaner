import AppKit
import SwiftUI

/// One native selection model is used for both flat and hierarchical browsing.
struct SessionTable: NSViewRepresentable {
    let rows: [BrowserRow]
    @Binding var selectedIDs: Set<String>
    @Binding var focusedID: String?
    @Binding var sort: BrowserSort
    let treeMode: Bool
    let toggleExpansion: (String) -> Void
    let review: () -> Void
    var preview: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SessionTableScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let table = BrowserTableView()
        table.autoresizingMask = [.width]
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("会话列表")
        for (key, label, width, minimum) in [("title", "会话", 330.0, 200.0), ("project", "项目", 130.0, 90.0), ("updated", "更新时间", 125.0, 115.0), ("size", "文件大小", 85.0, 75.0), ("turns", "轮次", 55.0, 48.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = label
            column.width = width
            column.minWidth = minimum
            column.resizingMask = key == "title" ? [.userResizingMask, .autoresizingMask] : .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: key == "title" || key == "project")
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.review = { context.coordinator.parent.review() }
        table.preview = { context.coordinator.parent.preview() }
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.previewClickedRow)
        table.navigateTree = { direction in context.coordinator.navigateTree(direction) }
        context.coordinator.table = table
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = scroll.documentView as? BrowserTableView else { return }
        table.tableColumns.first { $0.identifier.rawValue == "size" }?.title = treeMode ? "含后代大小" : "文件大小"
        coordinator.updating = true
        if coordinator.rows != rows {
            coordinator.rows = rows
            table.reloadData()
        }
        let indices = IndexSet(rows.enumerated().compactMap { selectedIDs.contains($0.element.id) ? $0.offset : nil })
        if table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
        let descriptor: NSSortDescriptor
        switch sort {
        case .recent: descriptor = NSSortDescriptor(key: "updated", ascending: false)
        case .oldest: descriptor = NSSortDescriptor(key: "updated", ascending: true)
        case .largest: descriptor = NSSortDescriptor(key: "size", ascending: false)
        case .turns: descriptor = NSSortDescriptor(key: "turns", ascending: false)
        case .smallest: descriptor = NSSortDescriptor(key: "size", ascending: true)
        case .fewestTurns: descriptor = NSSortDescriptor(key: "turns", ascending: true)
        case .titleAscending: descriptor = NSSortDescriptor(key: "title", ascending: true)
        case .titleDescending: descriptor = NSSortDescriptor(key: "title", ascending: false)
        case .projectAscending: descriptor = NSSortDescriptor(key: "project", ascending: true)
        case .projectDescending: descriptor = NSSortDescriptor(key: "project", ascending: false)
        }
        if table.sortDescriptors != [descriptor] { table.sortDescriptors = [descriptor] }
        coordinator.updating = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SessionTable
        var rows: [BrowserRow] = []
        var updating = false
        weak var table: BrowserTableView?
        init(_ parent: SessionTable) { self.parent = parent }
        @objc func previewClickedRow(_ sender: NSTableView) {
            guard rows.indices.contains(sender.clickedRow) else { return }
            let id = rows[sender.clickedRow].id
            parent.focusedID = id
            parent.preview()
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn else { return nil }
            let item = rows[row]
            let session = item.session
            let key = tableColumn.identifier.rawValue
            if key == "title" {
                let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? SessionTitleCell) ?? SessionTitleCell()
                cell.identifier = tableColumn.identifier
                cell.configure(item) { [weak self] in self?.parent.toggleExpansion(session.id) }
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView) ?? makeTextCell(tableColumn.identifier)
            let label = cell.textField!
            switch key {
            case "project": label.stringValue = session.project; cell.toolTip = session.cwd
            case "updated": label.stringValue = Self.dateFormatter.string(from: session.updatedAt); cell.toolTip = session.updatedAt.formatted(date: .complete, time: .standard)
            case "size":
                label.stringValue = ByteCountFormatter.string(fromByteCount: item.displayedByteCount, countStyle: .file)
                cell.toolTip = item.includesDescendants
                    ? "自身 \(ByteCountFormatter.string(fromByteCount: session.byteCount, countStyle: .file))；含全部后代 \(item.familySessionCount) 条，共 \(label.stringValue)（不受折叠与筛选影响）"
                    : session.rolloutPath
            case "turns": label.stringValue = "\(session.turnCount)"; cell.toolTip = "历史数据库统计的对话轮次"
            default: label.stringValue = ""
            }
            return cell
        }
        private func makeTextCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            if id.rawValue == "size" || id.rawValue == "turns" { label.alignment = .right; label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            let added = ids.subtracting(parent.selectedIDs)
            parent.selectedIDs = ids
            let clicked = table.clickedRow
            let event = NSApp.currentEvent
            if event?.type != .keyDown, rows.indices.contains(clicked), ids.contains(rows[clicked].id) {
                parent.focusedID = rows[clicked].id
            } else if let addedRow = rows.first(where: { added.contains($0.id) }) {
                parent.focusedID = addedRow.id
            } else if !ids.contains(parent.focusedID ?? "") {
                parent.focusedID = rows.first { ids.contains($0.id) }?.id
            }
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first else { return }
            switch descriptor.key {
            case "size": parent.sort = descriptor.ascending ? .smallest : .largest
            case "turns": parent.sort = descriptor.ascending ? .fewestTurns : .turns
            case "title": parent.sort = descriptor.ascending ? .titleAscending : .titleDescending
            case "project": parent.sort = descriptor.ascending ? .projectAscending : .projectDescending
            case "updated": parent.sort = descriptor.ascending ? .oldest : .recent
            default: break
            }
        }
        func navigateTree(_ direction: Int) -> Bool {
            guard let table, rows.indices.contains(table.selectedRow), table.selectedRowIndexes.count == 1 else { return false }
            let row = rows[table.selectedRow]
            if direction > 0, row.hasChildren, !row.isExpanded { parent.toggleExpansion(row.id); return true }
            if direction < 0, row.hasChildren, row.isExpanded { parent.toggleExpansion(row.id); return true }
            if direction < 0, let parentID = row.parentID, let index = rows.firstIndex(where: { $0.id == parentID }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                table.scrollRowToVisible(index); return true
            }
            return false
        }
        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"; return formatter
        }()
    }
}

@MainActor
final class BrowserTableView: NSTableView {
    var review: (() -> Void)?
    var preview: (() -> Void)?
    var navigateTree: ((Int) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { deselectAll(nil); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" { selectAll(nil); return }
        if event.modifierFlags.contains(.command), event.keyCode == 51 { if numberOfSelectedRows > 0 { review?() }; return }
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if numberOfSelectedRows > 0 { preview?() }; return
        }
        if event.keyCode == 123, navigateTree?(-1) == true { return }
        if event.keyCode == 124, navigateTree?(1) == true { return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class SessionTitleCell: NSTableCellView {
    private let disclosure = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var indentation: NSLayoutConstraint!
    private var toggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.bezelStyle = .inline; disclosure.isBordered = false
        disclosure.target = self; disclosure.action = #selector(expand)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.imagePosition = .imageOnly
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, subtitleLabel] { label.lineBreakMode = .byTruncatingTail; label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label) }
        addSubview(disclosure)
        indentation = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([indentation, disclosure.widthAnchor.constraint(equalToConstant: 18), disclosure.heightAnchor.constraint(equalToConstant: 24), disclosure.centerYAnchor.constraint(equalTo: centerYAnchor), titleLabel.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4), titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6), subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor), subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)])
        textField = titleLabel
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ row: BrowserRow, toggle: @escaping () -> Void) {
        let session = row.session
        self.toggle = toggle
        indentation.constant = CGFloat(min(row.depth, 16)) * 16 + 4
        disclosure.isHidden = !row.hasChildren
        disclosure.image = NSImage(systemSymbolName: row.isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: row.isExpanded ? "折叠子会话" : "展开子会话")
        disclosure.setAccessibilityLabel(row.isExpanded ? "折叠 \(session.title) 的子会话" : "展开 \(session.title) 的子会话")
        titleLabel.stringValue = session.title
        var parts = [session.model.isEmpty ? session.modelProvider : session.model]
        if session.isSubagent { parts.append("子代理") }
        if session.isPinned { parts.append("置顶") }
        if session.archived { parts.append("已归档") }
        if !session.rolloutPathExists { parts.append("文件缺失") }
        if row.hasChildren { parts.append("\(row.childCount) 个子会话") }
        if row.includesDescendants && row.familySessionCount > 1 { parts.append("体积含 \(row.familySessionCount - 1) 个后代") }
        subtitleLabel.stringValue = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        toolTip = session.title + "\n" + session.cwd
    }
    @objc private func expand() { toggle?() }
}

@MainActor
final class SessionTableScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let table = documentView as? NSTableView else { return }
        guard let title = table.tableColumns.first else { return }
        let spacing = CGFloat(table.numberOfColumns) * table.intercellSpacing.width
        let fixedWidth = table.tableColumns.dropFirst().reduce(0) { $0 + $1.width } + spacing
        // Resizing the document view alone leaves columns wider than its frame.
        // AppKit then scrolls sideways when selecting the last column with ⌘A.
        title.width = max(title.minWidth, contentSize.width - fixedWidth)
        let width = max(contentSize.width, title.width + fixedWidth)
        if abs(table.frame.width - width) > 0.5 { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
        if width <= contentSize.width + 0.5, contentView.bounds.origin.x != 0 {
            contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
        }
    }
}
