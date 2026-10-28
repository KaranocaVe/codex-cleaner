import SwiftUI
import AppKit

@main
struct CodexCleanerApp: App {
    @StateObject private var store = SessionStore()
    @FocusedValue(\.browserActions) private var actions
    @FocusedValue(\.previewSearch) private var previewSearch

    var body: some Scene {
        WindowGroup("Codex Cleaner") {
            CleanerRootView(store: store)
                .frame(minWidth: 1080, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 850)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新会话") { store.reload() }.keyboardShortcut("r")
                Button(previewSearch == nil ? "搜索会话" : "搜索预览正文") {
                    if let previewSearch { previewSearch() } else { actions?.search() }
                }.keyboardShortcut("f")
                Button("预览会话内容…") { actions?.preview() }.keyboardShortcut("p")
                    .disabled(actions?.canPreview != true)
                Divider()
                Button("清理所选会话…") { actions?.review() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(actions?.canReview != true)
            }
        }
    }
}

private struct BrowserActions {
    var search: () -> Void
    var review: () -> Void
    var canReview: Bool
    var preview: () -> Void
    var canPreview: Bool
}
private struct BrowserActionsKey: FocusedValueKey { typealias Value = BrowserActions }
private extension FocusedValues {
    var browserActions: BrowserActions? {
        get { self[BrowserActionsKey.self] }
        set { self[BrowserActionsKey.self] = newValue }
    }
}

struct CleanerRootView: View {
    @ObservedObject var store: SessionStore
    @State private var selectedIDs = Set<String>()
    @State private var focusedID: String?
    @State private var filter = SessionFilter()
    @State private var scope: BrowserScope = .all
    @State private var sort: BrowserSort = .recent
    @State private var treeMode = true
    @State private var expandedIDs = Set<String>()
    @State private var projectQuery = ""
    @State private var showDirectories = false
    @State private var showInspector = true
    @State private var reviewRequest: CleanupRequest?
    @State private var previewSession: CodexSession?
    @State private var alertMessage: String?
    @State private var selectionNote: String?
    @FocusState private var searchFocused: Bool

    private var snapshot: BrowserSnapshot {
        BrowserSnapshot.build(sessions: store.sessions, filter: filter, scope: scope, sort: sort,
                              treeMode: treeMode, expandedIDs: expandedIDs)
    }
    private var selected: [CodexSession] { store.sessions.filter { selectedIDs.contains($0.id) } }
    private var focused: CodexSession? { store.sessions.first { $0.id == focusedID } }

    var body: some View {
        let browser = snapshot
        HSplitView {
            sidebar.frame(minWidth: 205, idealWidth: 235, maxWidth: 290)
            VStack(spacing: 0) {
                browserHeader(browser)
                Divider()
                if let error = store.lastError, !store.sessions.isEmpty {
                    notice(error, icon: "exclamationmark.triangle", color: .orange)
                }
                if let warning = store.lastWarning {
                    notice(warning, icon: "info.circle", color: .orange)
                }
                if store.sessions.isEmpty && store.isLoading {
                    Spacer(); ProgressView("正在读取会话…"); Spacer()
                } else if store.sessions.isEmpty, let error = store.lastError {
                    ContentUnavailableView {
                        Label("无法读取 Codex 数据", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text(error).textSelection(.enabled) }
                    actions: { Button("重新读取") { store.reload() }.buttonStyle(.borderedProminent) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if browser.matching.isEmpty {
                    ContentUnavailableView {
                        Label(store.sessions.isEmpty ? "没有会话" : "没有匹配的会话", systemImage: "line.3.horizontal.decrease.circle")
                    } description: { Text(store.sessions.isEmpty ? "数据源中没有会话记录。" : "调整搜索或筛选条件后重试。") }
                    actions: { if !store.sessions.isEmpty { Button("重置筛选") { resetFilters() } } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    SessionTable(rows: browser.rows, selectedIDs: $selectedIDs, focusedID: $focusedID,
                                 sort: $sort, treeMode: treeMode, toggleExpansion: toggleExpansion,
                                 review: beginReview, preview: beginPreview)
                }
                Divider()
                browserFooter(browser)
            }
            .frame(minWidth: 570, maxWidth: .infinity, maxHeight: .infinity)
            if showInspector {
                SessionInspector(session: focused, selection: selected, browser: browser,
                                 canPreview: !store.isDeleting, preview: beginPreview)
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 370)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isLoading { ProgressView().controlSize(.small) }
                Button { store.reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(store.isLoading || store.isDeleting).help("刷新（⌘R）")
                Button { showInspector.toggle() } label: { Label("详情", systemImage: "sidebar.right") }
                    .help("显示或隐藏详情")
                Button(action: beginPreview) { Label("预览内容", systemImage: "text.bubble") }
                    .disabled(focused == nil || store.isDeleting).help("预览会话内容（空格 / ⌘P）")
                Button(action: beginReview) { Label("清理所选…", systemImage: "trash") }
                    .disabled(selectedIDs.isEmpty || store.isDeleting).help("审阅清理范围（⌘⌫）")
            }
            ToolbarItem(placement: .status) {
                if store.isDeleting { HStack { ProgressView().controlSize(.small); Text("正在清理…") }.font(.caption) }
            }
        }
        .focusedSceneValue(\.browserActions, BrowserActions(search: { searchFocused = true }, review: beginReview,
                                                            canReview: !selectedIDs.isEmpty && !store.isDeleting,
                                                            preview: beginPreview, canPreview: focused != nil && !store.isDeleting))
        .sheet(item: $reviewRequest) { request in
            CleanupReview(request: request, isDeleting: store.isDeleting, progress: store.cleanupProgress,
                          cancel: { reviewRequest = nil }, confirm: performDelete)
        }
        .sheet(item: $previewSession) { session in
            SessionPreviewView(session: session, close: { previewSession = nil })
        }
        .alert("清理结果", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
        .onChange(of: browser.visibleIDs) { _, ids in
            let removed = selectedIDs.subtracting(ids).count
            selectedIDs.formIntersection(ids)
            if removed > 0 { selectionNote = "已取消选择 \(removed) 条当前不可见会话" }
            if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }
        }
        .onChange(of: selectedIDs) { old, ids in
            if !ids.subtracting(old).isEmpty { selectionNote = nil }
            if focusedID == nil || !ids.contains(focusedID ?? "") {
                focusedID = browser.rows.first { ids.contains($0.id) }?.id
            }
        }
        .onChange(of: projectQuery) { _, query in
            if !query.isEmpty { showDirectories = true }
        }
        .task { store.reload() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    sectionTitle("会话库")
                    scopeButton(.all, title: "全部会话", icon: "tray.full", count: store.sessions.count)
                    scopeButton(.recent, title: "最近 15 分钟更新", icon: "clock", count: store.sessions.filter { $0.status == .active }.count)
                    scopeButton(.archived, title: "已归档", icon: "archivebox", count: store.sessions.filter(\.archived).count)
                    scopeButton(.pinned, title: "已置顶", icon: "pin", count: store.sessions.filter(\.isPinned).count)
                    scopeButton(.subagents, title: "子代理", icon: "arrow.triangle.branch", count: store.sessions.filter(\.isSubagent).count)
                    scopeButton(.missing, title: "文件缺失", icon: "doc.badge.ellipsis", count: store.sessions.filter { !$0.rolloutPathExists }.count)
                    Divider().padding(.vertical, 10)
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("查找项目或路径", text: $projectQuery).textFieldStyle(.plain)
                        if !projectQuery.isEmpty { Button { projectQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                    }.padding(7).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    sectionTitle("已登记项目")
                    ForEach(projects.filter(\.registered)) { project in projectButton(project) }
                    if projects.allSatisfy({ !$0.registered }) { Text("没有已登记项目").font(.caption).foregroundStyle(.secondary).padding(8) }
                    DisclosureGroup(isExpanded: $showDirectories) {
                        ForEach(projects.filter { !$0.registered }) { project in projectButton(project) }
                    } label: {
                        Text("其他工作目录（\(directoryCount)）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.padding(.top, 14)
                    if !projectQuery.isEmpty && projects.isEmpty { Text("未找到项目或目录").foregroundStyle(.secondary).font(.caption).padding(8) }
                }.padding(12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Label("本机 Codex 数据", systemImage: "internaldrive").font(.caption.weight(.medium))
                Text(store.stateURL.deletingLastPathComponent().path).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.background(Color(nsColor: .underPageBackgroundColor))
    }

    private var projects: [ProjectEntry] {
        let entries = Dictionary(grouping: store.sessions, by: \.projectKey).map { key, sessions in
            let first = sessions[0]
            return ProjectEntry(id: key, name: first.project, path: first.registeredProjectRoot ?? first.cwd,
                                count: sessions.count, registered: first.registeredProjectID != nil)
        }
        let needle = projectQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { needle.isEmpty || ($0.name + " " + $0.path).localizedStandardContains(needle) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var directoryCount: Int { Set(store.sessions.filter { $0.registeredProjectID == nil }.map(\.projectKey)).count }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 9).padding(.bottom, 5).padding(.leading, 6)
    }
    private func scopeButton(_ value: BrowserScope, title: String, icon: String, count: Int) -> some View {
        Button { scope = value; selectionNote = nil } label: {
            HStack(spacing: 9) { Image(systemName: icon).frame(width: 16); Text(title).lineLimit(1); Spacer(minLength: 2); Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
                .background(scope == value ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    private func projectButton(_ project: ProjectEntry) -> some View {
        Button { scope = .project(project.id); selectionNote = nil } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: project.registered ? "folder.fill" : "folder").foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) { Text(project.name).lineLimit(1); Text(project.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0); Text("\(project.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(7).contentShape(Rectangle())
                .background(scope == .project(project.id) ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(project.path)
    }

    private func browserHeader(_ browser: BrowserSnapshot) -> some View {
        let total = browser.total(for: browser.matchingIDs, includingDescendants: treeMode)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(scopeTitle).font(.title2.weight(.semibold)).lineLimit(1)
                    Text(treeMode
                         ? "匹配 \(browser.matching.count) 条 · 含后代 \(total.sessionCount) 条 · \(size(total.byteCount))"
                         : "\(browser.matching.count) 条 · \(size(total.byteCount))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("显示方式", selection: $treeMode) {
                    Image(systemName: "list.bullet").help("平铺列表").tag(false)
                    Image(systemName: "list.bullet.indent").help("父子树").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 88)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索标题、项目、路径、模型或 ID", text: $filter.query).textFieldStyle(.plain).focused($searchFocused)
                if !filter.query.isEmpty { Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                Text("⌘F").font(.caption).foregroundStyle(.tertiary)
            }.padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack(spacing: 9) {
                Picker("更新时间", selection: $filter.age) {
                    ForEach(SessionFilter.Age.allCases, id: \.self) { Text($0.chineseLabel).tag($0) }
                }.labelsHidden().frame(width: 112)
                Picker("排序", selection: $sort) {
                    ForEach(BrowserSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 135)
                Menu("更多筛选") {
                    Toggle("包含子代理", isOn: $filter.includeSubagents)
                    Toggle("包含置顶会话", isOn: $filter.includePinned)
                }.frame(width: 90)
                if treeMode {
                    Menu {
                        Button("展开全部") { expandedIDs = Set(browser.matching.map(\.id)) }
                        Button("折叠全部") { expandedIDs.removeAll() }
                    } label: { Image(systemName: "arrow.up.and.down.text.horizontal") }
                        .menuStyle(.borderlessButton).frame(width: 25).help("展开或折叠树")
                }
                Spacer(minLength: 0)
                Button("重置") { resetFilters() }.disabled(isDefaultFilter)
            }.font(.callout).controlSize(.small)
            if !filter.includeSubagents || !filter.includePinned {
                Text([!filter.includeSubagents ? (treeMode ? "已隐藏子代理行" : "已排除子代理") : nil,
                      !filter.includePinned ? (treeMode ? "已隐藏置顶行" : "已排除置顶会话") : nil,
                      treeMode ? "体积仍含全部后代" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16)
    }

    private var scopeTitle: String {
        switch scope {
        case .all: "全部会话"
        case .recent: "最近 15 分钟更新"
        case .idle: "较早更新"
        case .archived: "已归档"
        case .pinned: "已置顶"
        case .subagents: "子代理"
        case .missing: "文件缺失"
        case .project(let key): store.sessions.first { $0.projectKey == key }?.project ?? "项目"
        }
    }
    private var isDefaultFilter: Bool { scope == .all && filter.query.isEmpty && filter.age == .any && filter.includeSubagents && filter.includePinned && sort == .recent }
    private func resetFilters() { scope = .all; filter = SessionFilter(); sort = .recent; projectQuery = ""; showDirectories = false; selectionNote = nil }
    private func toggleExpansion(_ id: String) { if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) } }

    private func browserFooter(_ browser: BrowserSnapshot) -> some View {
        let own = browser.total(for: selectedIDs, includingDescendants: false)
        let total = browser.total(for: selectedIDs, includingDescendants: treeMode)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                if selectedIDs.isEmpty { Text("⌘ 多选 · ⇧ 连选 · ⌘A 全选 · 空格预览内容") }
                else {
                    Text(treeMode
                         ? "已选 \(selectedIDs.count) 行 · 含后代 \(total.sessionCount) 条 · \(size(total.byteCount))"
                         : "已选 \(selectedIDs.count) 条 · \(size(total.byteCount))").fontWeight(.medium)
                    Button("取消选择") { selectedIDs.removeAll(); focusedID = nil }.buttonStyle(.link)
                }
                Spacer()
                if treeMode { Text("显示 \(browser.rows.count) / \(browser.matching.count) 条") }
                else { Text("共 \(store.sessions.count) 条") }
            }
            if treeMode && !selectedIDs.isEmpty {
                Text("所选行自身 \(size(own.byteCount))；清理范围可在下一步审阅中调整。")
            }
            if let selectionNote { Text(selectionNote).foregroundStyle(.orange) }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
    }
    private func notice(_ message: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top) { Image(systemName: icon).foregroundStyle(color); Text(message).textSelection(.enabled); Spacer(); Button("重试") { store.reload() } }
            .font(.caption).padding(10).background(color.opacity(0.08))
    }
    private func beginReview() {
        guard !selectedIDs.isEmpty, !store.isDeleting, previewSession == nil else { return }
        let selected = selected
        guard !selected.isEmpty else { return }
        let ids = snapshot.descendants(of: selectedIDs)
        let cascade = store.sessions.filter { selectedIDs.contains($0.id) || ids.contains($0.id) }
        reviewRequest = CleanupRequest(selected: selected, cascade: cascade, includeDescendants: treeMode)
    }
    private func beginPreview() {
        guard let focused, !store.isDeleting, reviewRequest == nil else { return }
        previewSession = focused
    }
    private func performDelete(_ targets: [CodexSession]) {
        Task {
            do {
                let receipt = try await store.delete(targets)
                selectedIDs.removeAll(); focusedID = nil; reviewRequest = nil
                alertMessage = "已清理 \(receipt.count) 条会话索引。\(receipt.missingCount > 0 ? "其中 \(receipt.missingCount) 条原本缺少会话文件。" : "")\n\n\(size(receipt.bytes)) 会话文件已移入暂存目录，尚未释放磁盘空间。\n\n会话文件：\n\(receipt.trashURL.path)\n\n文件搬移清单：\n\(receipt.manifestURL.path)\n\n未创建数据库备份，已提交的索引删除无法撤销。"
            } catch { reviewRequest = nil; alertMessage = error.localizedDescription }
        }
    }
}

private struct ProjectEntry: Identifiable {
    let id: String; let name: String; let path: String; let count: Int; let registered: Bool
}

struct CleanupRequest: Identifiable {
    let id = UUID()
    let selected: [CodexSession]
    let cascade: [CodexSession]
    let includeDescendants: Bool
}

private struct CleanupReview: View {
    let selected: [CodexSession]
    let cascade: [CodexSession]
    let isDeleting: Bool
    let progress: CleanupProgress?
    let cancel: () -> Void
    let confirm: ([CodexSession]) -> Void
    @State private var includeDescendants: Bool
    init(request: CleanupRequest, isDeleting: Bool, progress: CleanupProgress?, cancel: @escaping () -> Void, confirm: @escaping ([CodexSession]) -> Void) {
        selected = request.selected
        cascade = request.cascade
        self.isDeleting = isDeleting
        self.progress = progress
        self.cancel = cancel
        self.confirm = confirm
        _includeDescendants = State(initialValue: request.includeDescendants)
    }
    private var targets: [CodexSession] {
        var seen = Set<String>()
        return (includeDescendants ? cascade : selected).filter { seen.insert($0.id).inserted }
    }
    private var current: Bool { targets.contains(where: \.isCurrent) }
    private var emptyPath: Bool { targets.contains { $0.rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(isDeleting ? "正在清理会话" : "审阅清理范围", systemImage: "trash").font(.title2.weight(.semibold))
            if isDeleting {
                cleanupProgressView
            } else {
            if cascade.count > selected.count {
                Toggle("同时清理后代会话（额外 \(cascade.count - selected.count) 条）", isOn: $includeDescendants)
                Text("级联会包含当前筛选之外、已折叠的子会话。下方列出最终范围。").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                reviewMetric("会话", "\(targets.count)")
                reviewMetric("会话文件", size(targets.reduce(0) { $0 + $1.byteCount }))
                reviewMetric("缺少文件", "\(targets.filter { !$0.rolloutPathExists }.count)")
            }
            List(targets) { session in
                HStack {
                    Image(systemName: session.isSubagent ? "arrow.turn.down.right" : "text.bubble").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) { Text(session.title).lineLimit(1); Text("\(session.project) · \(session.id)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(); Text(size(session.byteCount)).font(.caption.monospacedDigit())
                    if !session.rolloutPathExists { Image(systemName: "doc.badge.ellipsis").foregroundStyle(.orange).help(session.rolloutPath.isEmpty ? "路径未记录，需先取消选择此条" : "会话文件缺失，仅清理索引") }
                    if session.isCurrent { Text("当前会话").foregroundStyle(.orange).font(.caption) }
                }
            }.listStyle(.bordered).frame(height: 240)
            Text("直接清理数据库中的关联记录，不创建数据库备份；提交后的索引删除无法撤销。会话文件移入本机暂存目录，本次操作不会释放这部分磁盘空间。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("路径为空或越界的记录会停止本次清理。仍在运行的会话可能继续写入，建议先停止目标会话。").font(.caption).foregroundStyle(.secondary)
            if current { Label("范围中包含当前 Codex 会话，请取消选择或关闭级联。", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            if emptyPath { Label("部分记录未保存文件路径，请先取消选择这些会话。", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction).disabled(isDeleting)
                Button(isDeleting ? "正在处理…" : "清理 \(targets.count) 条会话", role: .destructive) { confirm(targets) }
                    .buttonStyle(.borderedProminent).tint(.red).disabled(current || emptyPath || isDeleting || targets.isEmpty)
            }
            }
        }.padding(24).frame(width: 660).interactiveDismissDisabled(isDeleting)
    }
    private var cleanupProgressView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(progress?.phase.label ?? "正在准备清理…").font(.headline)
                Spacer()
                Text((progress?.fraction ?? 0).formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: progress?.fraction ?? 0, total: 1)
                .progressViewStyle(.linear)
                .accessibilityLabel("会话清理进度")
            if let progress {
                Text("处理步骤 \(progress.completed) / \(progress.total)").font(.callout.monospacedDigit())
                if let detail = progress.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text("完成后会自动显示结果，请保持窗口打开。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 20)
    }
    private func reviewMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(value).font(.title3.monospacedDigit().weight(.semibold)); Text(label).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct SessionInspector: View {
    let session: CodexSession?
    let selection: [CodexSession]
    let browser: BrowserSnapshot
    let canPreview: Bool
    let preview: () -> Void
    var body: some View {
        let selectedTotal = browser.total(for: Set(selection.map(\.id)), includingDescendants: true)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(selection.count > 1 ? "所选会话（\(selection.count)）" : "会话详情").font(.headline)
                if selection.count > 1 {
                    Text("所选自身 \(size(selection.reduce(0) { $0 + $1.byteCount }))\n含全部后代 \(selectedTotal.sessionCount) 条 · \(size(selectedTotal.byteCount))（已去重）").font(.callout).foregroundStyle(.secondary)
                    Divider()
                }
                if let session {
                    Text(session.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Button(action: preview) { Label("预览会话内容", systemImage: "text.bubble") }
                        .buttonStyle(.borderedProminent).disabled(!canPreview).help("读取用户与助手的对话正文（空格 / ⌘P）")
                    HStack { if session.isPinned { Label("置顶", systemImage: "pin.fill") }; if session.archived { Label("已归档", systemImage: "archivebox") }; if session.isSubagent { Label("子代理", systemImage: "arrow.triangle.branch") } }.font(.caption).foregroundStyle(.secondary)
                    info("项目", session.project)
                    info("工作目录", session.cwd.isEmpty ? "未记录" : session.cwd)
                    info("模型", session.model.isEmpty ? session.modelProvider : session.model)
                    HStack { info("轮次", "\(session.turnCount)"); Spacer(); info("条目", "\(session.itemCount)"); Spacer(); info("自身文件", size(session.byteCount)) }
                    if let family = browser.familyTotalsByID[session.id] {
                        info("含全部后代的文件大小", "\(size(family.byteCount)) · \(family.sessionCount) 条会话")
                    }
                    info("创建", session.createdAt.formatted(date: .numeric, time: .shortened))
                    info("更新", session.updatedAt.formatted(date: .numeric, time: .shortened))
                    if let parent = session.parentThreadID {
                        info("父会话", browser.allSessions.first { $0.id == parent }?.title ?? parent)
                    }
                    info("会话 ID", session.id)
                    info("会话文件", session.rolloutPath.isEmpty ? "路径未记录" : session.rolloutPath)
                    if !session.rolloutPathExists { Label("文件缺失，数据库记录仍存在", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(session.rolloutPath, inFileViewerRootedAtPath: "") }.disabled(!session.rolloutPathExists)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.id, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("复制会话 ID")
                    }.controlSize(.small)
                    if !session.preview.isEmpty { Divider(); info("摘要", session.preview) }
                } else {
                    Text("选择会话后在这里查看项目、父子关系及文件位置。").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private func info(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }
}

private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
private extension SessionFilter.Age {
    var chineseLabel: String {
        switch self { case .any: "全部时间"; case .week: "最近 7 天"; case .month: "最近 30 天"; case .quarter: "最近 90 天"; case .year: "最近一年"; case .older: "一年以前" }
    }
}
