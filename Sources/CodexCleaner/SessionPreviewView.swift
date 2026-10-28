import AppKit
import SwiftUI

private struct PreviewSearchKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var previewSearch: (() -> Void)? {
        get { self[PreviewSearchKey.self] }
        set { self[PreviewSearchKey.self] = newValue }
    }
}

/// A separate reader keeps large rollout files out of the browsing path.
struct SessionPreviewView: View {
    let session: CodexSession
    let close: () -> Void
    @State private var preview: SessionPreview?
    @State private var error: String?
    @State private var loading = true
    @State private var query = ""
    @State private var role = "all"
    @State private var attempt = 0
    @State private var expandedIDs = Set<String>()
    @FocusState private var searchFocused: Bool

    private var messages: [SessionPreviewMessage] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (preview?.messages ?? []).filter {
            (role == "all" || $0.role == role) && (needle.isEmpty || $0.text.localizedStandardContains(needle))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("会话内容预览").font(.title2.weight(.semibold))
                        Text(session.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("关闭", action: close).keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索已加载的对话正文", text: $query).textFieldStyle(.plain).focused($searchFocused)
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).help("清空搜索")
                        }
                    }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    Picker("发言人", selection: $role) {
                        Text("全部").tag("all")
                        Text("用户").tag("user")
                        Text("助手").tag("assistant")
                    }.pickerStyle(.segmented).frame(width: 200)
                }.disabled(loading || preview == nil)
            }.padding(20)
            Divider()
            if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在读取对话正文…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("无法预览会话", systemImage: "doc.badge.exclamationmark")
                } description: {
                    Text(error).textSelection(.enabled)
                } actions: {
                    Button("重新读取") { attempt += 1 }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView {
                    Label(preview?.messages.isEmpty == true ? "没有可预览的对话正文" : "没有匹配的发言", systemImage: "text.bubble")
                } description: {
                    Text(preview?.messages.isEmpty == true ? "已读取的范围内没有用户或助手的文本发言。" : "调整关键词或发言人筛选。")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                conversation
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("显示 \(messages.count) / \(preview?.messages.count ?? 0) 条发言 · 按时间顺序")
                    Spacer()
                    Button("重新读取") { attempt += 1 }.disabled(loading)
                }.font(.caption).foregroundStyle(.secondary)
                if let warning = preview?.warning, !warning.isEmpty {
                    Label(warning, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if preview?.truncated == true {
                    Label("仅预览文件开头的部分内容。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 880, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusedSceneValue(\.previewSearch, { searchFocused = true })
        .task(id: attempt) { await load() }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Text("用户与助手的文本发言").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("回到开头") { if let id = messages.first?.id { proxy.scrollTo(id, anchor: .top) } }
                    Button("到预览末尾") { if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }.buttonStyle(.link).font(.caption).padding(.horizontal, 20).padding(.vertical, 10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { message in
                            messageCard(message).id(message.id)
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
    }

    private func messageCard(_ message: SessionPreviewMessage) -> some View {
        let isUser = message.role == "user"
        let expanded = expandedIDs.contains(message.id) || !query.isEmpty
        let longMessage = message.text.count > 2400 || message.text.split(separator: "\n", omittingEmptySubsequences: false).count > 18
        let shortened = longMessage && !expanded
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(isUser ? "用户" : "助手", systemImage: isUser ? "person.fill" : "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(isUser ? Color.accentColor : .secondary)
                Spacer()
                if let timestamp = message.timestamp { Text(displayTime(timestamp)).font(.caption).foregroundStyle(.tertiary) }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("复制这条发言")
            }
            Text(shortened ? String(message.text.prefix(2400)) + "…" : message.text)
                .font(.system(size: 13)).textSelection(.enabled)
                .lineLimit(shortened ? 14 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if longMessage {
                Button(shortened ? "展开这条发言" : "收起") {
                    if expandedIDs.contains(message.id) { expandedIDs.remove(message.id) }
                    else { expandedIDs.insert(message.id) }
                }.buttonStyle(.link).font(.caption).disabled(!query.isEmpty)
            }
        }.padding(16)
            .background(isUser ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func displayTime(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? timestamp
    }

    @MainActor
    private func load() async {
        loading = true
        preview = nil
        error = nil
        expandedIDs.removeAll()
        let path = session.rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            error = "此会话未记录文件路径。"
            loading = false
            return
        }
        let worker = Task.detached(priority: .userInitiated) {
            try SessionPreviewReader.read(url: URL(fileURLWithPath: path))
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            preview = result
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}
