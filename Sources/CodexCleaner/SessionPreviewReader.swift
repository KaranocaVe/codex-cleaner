import Foundation

struct SessionPreview: Sendable {
    let messages: [SessionPreviewMessage]
    let truncated: Bool
    let warning: String?
}

struct SessionPreviewMessage: Identifiable, Sendable {
    let id: String
    let role: String
    let text: String
    let timestamp: String?
}

enum SessionPreviewReaderError: LocalizedError, Sendable {
    case fileMissing(URL)
    case unreadable(URL, String)
    case decompressorUnavailable
    case decompressionFailed(String)
    case malformedFile(URL, Int)
    case noDisplayableContent(URL)

    var errorDescription: String? {
        switch self {
        case let .fileMissing(url):
            return "找不到会话文件：\(url.path)"
        case let .unreadable(url, message):
            return "无法读取会话文件 \(url.lastPathComponent)：\(message)"
        case .decompressorUnavailable:
            return "无法预览 .jsonl.zst：未找到 zstd 命令。请安装 zstd（例如 Homebrew），并确保它在 PATH 中。"
        case let .decompressionFailed(message):
            return "无法解压会话文件：\(message)"
        case let .malformedFile(url, count):
            return "会话文件格式损坏：\(url.lastPathComponent) 中有 \(count) 行无法解析，且没有可展示正文。"
        case let .noDisplayableContent(url):
            return "会话文件中没有可展示的用户或助手正文：\(url.lastPathComponent)"
        }
    }
}

struct SessionPreviewReader {
    struct Limits: Sendable, Equatable {
        var maxDecompressedBytes: Int = 32 * 1024 * 1024
        var maxMessages: Int = 200
        var readChunkBytes: Int = 64 * 1024
        var maxLineBytes: Int = 8 * 1024 * 1024

        static let `default` = Limits()

        init(maxDecompressedBytes: Int = 32 * 1024 * 1024,
             maxMessages: Int = 200,
             readChunkBytes: Int = 64 * 1024,
             maxLineBytes: Int = 8 * 1024 * 1024) {
            self.maxDecompressedBytes = max(1, maxDecompressedBytes)
            self.maxMessages = max(1, maxMessages)
            self.readChunkBytes = max(1, readChunkBytes)
            self.maxLineBytes = max(256, maxLineBytes)
        }
    }

    static func read(url: URL) throws -> SessionPreview {
        try read(url: url, limits: .default)
    }

    static func read(url: URL, limits: Limits) throws -> SessionPreview {
        try Task<Never, Never>.checkCancellation()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { throw SessionPreviewReaderError.fileMissing(url) }

        let source: ByteSource
        do {
            source = try ByteSource(url: url)
        } catch let error as SessionPreviewReaderError {
            throw error
        } catch {
            throw SessionPreviewReaderError.unreadable(url, error.localizedDescription)
        }
        defer { source.close() }

        var messages: [SessionPreviewMessage] = []
        var seenByContent: [String: [String: Int]] = [:]
        var pending = Data()
        var consumed = 0
        var lineNumber = 0
        var malformed = 0
        var validRecords = 0
        var skippedTools = false
        var truncated = false
        var stopReading = false
        var discardingLine = false

        func consumeLine(_ lineData: Data) throws {
            try Task<Never, Never>.checkCancellation()
            lineNumber += 1
            var bytes = lineData
            if bytes.last == 13 { bytes.removeLast() }
            if bytes.isEmpty { return }
            guard let line = String(data: bytes, encoding: .utf8) else {
                malformed += 1
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: bytes, options: []),
                  let record = object as? [String: Any] else {
                malformed += 1
                return
            }
            validRecords += 1
            let extracted = Self.extractMessages(from: record)
            if extracted.hadToolOrMetadata { skippedTools = true }
            for candidate in extracted.messages {
                guard !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let contentKey = "\(candidate.role)\u{1f}\(candidate.text)"
                // Codex can persist the same turn once as a response_item and
                // once as an event_msg. Pair records by ordinal across sources;
                // repeated text from one source remains a separate message.
                var counts = seenByContent[contentKey, default: [:]]
                let currentOrdinal = counts[candidate.origin, default: 0] + 1
                counts[candidate.origin] = currentOrdinal
                let priorOtherCount = counts.filter { $0.key != candidate.origin }.values.max() ?? 0
                seenByContent[contentKey] = counts
                if priorOtherCount >= currentOrdinal { continue }
                if messages.count >= limits.maxMessages {
                    truncated = true
                    stopReading = true
                    return
                }
                let id = "preview-\(messages.count)-\(Self.stableHash("\(candidate.role)\u{1f}\(candidate.text)\u{1f}\(candidate.timestamp ?? "")") )"
                messages.append(SessionPreviewMessage(id: id, role: candidate.role, text: candidate.text, timestamp: candidate.timestamp))
            }
            _ = line // Keep parsing explicit and avoid retaining the source bytes.
        }

        while !stopReading {
            try Task<Never, Never>.checkCancellation()
            let remaining = limits.maxDecompressedBytes - consumed
            if remaining <= 0 {
                truncated = true
                break
            }
            let chunkSize = min(limits.readChunkBytes, remaining + 1)
            let chunk: Data
            do {
                chunk = try source.read(upToCount: chunkSize)
            } catch let error as SessionPreviewReaderError {
                throw error
            } catch {
                throw SessionPreviewReaderError.unreadable(url, error.localizedDescription)
            }
            if chunk.isEmpty { break }
            consumed += chunk.count
            if consumed > limits.maxDecompressedBytes {
                let allowed = chunk.count - (consumed - limits.maxDecompressedBytes)
                if allowed > 0 { pending.append(chunk.prefix(allowed)) }
                truncated = true
            } else {
                pending.append(chunk)
            }

            if discardingLine {
                if let newline = pending.firstIndex(of: 10) {
                    pending.removeSubrange(...newline)
                    discardingLine = false
                } else {
                    pending.removeAll(keepingCapacity: true)
                    continue
                }
            }
            while let newline = pending.firstIndex(of: 10), !stopReading {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.count > limits.maxLineBytes {
                    malformed += 1
                    continue
                }
                try consumeLine(line)
            }
            if pending.count > limits.maxLineBytes {
                // A line without a newline cannot grow without bound. Skip its
                // bytes up to the next newline while retaining only a marker.
                malformed += 1
                discardingLine = true
                if let newline = pending.firstIndex(of: 10) {
                    pending.removeSubrange(...newline)
                    discardingLine = false
                } else {
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        if !stopReading && !truncated && !discardingLine && !pending.isEmpty && pending.count <= limits.maxLineBytes {
            try consumeLine(pending)
        } else if !pending.isEmpty && pending.count > limits.maxLineBytes && !discardingLine {
            malformed += 1
        }

        var warnings: [String] = []
        if malformed > 0 { warnings.append("已跳过 \(malformed) 行损坏或无法解码的记录。") }
        if skippedTools { warnings.append("工具调用、工具输出、reasoning 和元数据未纳入预览。") }
        if truncated {
            warnings.append("仅读取文件开头的最多 \(limits.maxDecompressedBytes / (1024 * 1024)) MiB，且最多展示 \(limits.maxMessages) 条正文；预览已截断。")
        }
        if messages.isEmpty {
            if truncated {
                warnings.append("在已读取范围内没有发现可展示的用户或助手正文，文件后续内容未扫描。")
                return SessionPreview(messages: [], truncated: true, warning: warnings.joined(separator: " "))
            }
            if validRecords == 0 && malformed > 0 { throw SessionPreviewReaderError.malformedFile(url, malformed) }
            throw SessionPreviewReaderError.noDisplayableContent(url)
        }
        return SessionPreview(messages: messages, truncated: truncated, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    private struct Candidate {
        let role: String
        let text: String
        let timestamp: String?
        let origin: String
    }

    private struct Extraction {
        var messages: [Candidate] = []
        var hadToolOrMetadata = false
    }

    private static func extractMessages(from record: [String: Any]) -> Extraction {
        var result = Extraction()
        let timestamp = stringValue(record["timestamp"])
        let recordType = stringValue(record["type"])?.lowercased()
        var payload = record["payload"] as? [String: Any]
        if payload == nil, recordType == "response_item" { payload = record["item"] as? [String: Any] }
        let body = payload ?? record
        let bodyType = stringValue(body["type"])?.lowercased()

        if recordType == "event_msg", let bodyType {
            switch bodyType {
            case "user_message", "user":
                appendText(from: body, role: "user", timestamp: timestamp, origin: "event", to: &result.messages)
            case "agent_message", "assistant_message", "assistant":
                appendText(from: body, role: "assistant", timestamp: timestamp, origin: "event", to: &result.messages)
            default:
                result.hadToolOrMetadata = true
            }
            return result
        }

        if bodyType == "message" {
            let role = stringValue(body["role"])?.lowercased()
            if role == "user" || role == "assistant" {
                appendText(from: body, role: role!, timestamp: timestamp, origin: recordType == "response_item" ? "response" : "direct", to: &result.messages)
            } else { result.hadToolOrMetadata = true }
            return result
        }

        // Some fixtures and older exports contain a message object directly.
        if recordType == "message" {
            let role = stringValue(record["role"])?.lowercased()
            if role == "user" || role == "assistant" {
                appendText(from: record, role: role!, timestamp: timestamp, origin: "direct", to: &result.messages)
            } else { result.hadToolOrMetadata = true }
        } else if ["function_call", "function_call_output", "tool_call", "tool_result", "reasoning", "compaction", "turn_context"].contains(bodyType ?? recordType ?? "") {
            result.hadToolOrMetadata = true
        }
        return result
    }

    private static func appendText(from object: [String: Any], role: String, timestamp: String?, origin: String, to output: inout [Candidate]) {
        let effectiveTimestamp = timestamp ?? stringValue(object["timestamp"])
        if let content = object["content"] {
            let text = texts(from: content).filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty { output.append(Candidate(role: role, text: text, timestamp: effectiveTimestamp, origin: origin)) }
            return
        }
        for key in ["text", "message", "input", "output"] {
            if let text = stringValue(object[key]), !text.isEmpty {
                output.append(Candidate(role: role, text: text, timestamp: effectiveTimestamp, origin: origin))
                return
            }
        }
    }

    private static func texts(from value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let array = value as? [Any] {
            return array.flatMap { item -> [String] in
                if let string = item as? String { return [string] }
                guard let dictionary = item as? [String: Any] else { return [] }
                let type = stringValue(dictionary["type"])?.lowercased()
                guard type == nil || ["input_text", "output_text", "text"].contains(type!) else { return [] }
                if let value = stringValue(dictionary["text"]) { return [value] }
                return texts(from: dictionary["content"] as Any)
            }
        }
        if let dictionary = value as? [String: Any] {
            if let text = stringValue(dictionary["text"]) { return [text] }
            if let content = dictionary["content"] { return texts(from: content) }
        }
        return []
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}

private final class ByteSource {
    private let handle: FileHandle
    private var process: Process?

    init(url: URL) throws {
        if url.pathExtension.lowercased() == "zst" {
            guard let executable = Self.findZstd() else { throw SessionPreviewReaderError.decompressorUnavailable }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-dc", "--", url.path]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw SessionPreviewReaderError.decompressionFailed(error.localizedDescription) }
            self.handle = output.fileHandleForReading
            self.process = process
        } else {
            do { self.handle = try FileHandle(forReadingFrom: url) }
            catch { throw SessionPreviewReaderError.unreadable(url, error.localizedDescription) }
        }
    }

    func read(upToCount count: Int) throws -> Data {
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.isEmpty, let process else { return data }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SessionPreviewReaderError.decompressionFailed("zstd 退出码 \(process.terminationStatus)。")
        }
        return data
    }

    func close() {
        try? handle.close()
        guard let process else { return }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        // A non-zero status after an intentional limit/cancellation is
        // expected because the decompressor was terminated by the reader.
    }

    private static func findZstd() -> String? {
        var paths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd", "/bin/zstd"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { String($0) + "/zstd" })
        }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
