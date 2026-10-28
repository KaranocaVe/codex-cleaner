import Foundation
import XCTest
@testable import CodexCleaner

final class SessionPreviewReaderTests: XCTestCase {
    func testResponseAndEventRecordsDeduplicateAndSkipTools() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rollout.jsonl")
        let lines = [
            #"{"timestamp":"2026-01-01T00:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello 世界"}]}}"#,
            #"{"timestamp":"2026-01-01T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hello 世界"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"},{"type":"output_text","text":"continued"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell"}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let preview = try SessionPreviewReader.read(url: url)
        XCTAssertEqual(preview.messages.map(\.role), ["user", "assistant", "assistant", "assistant"])
        XCTAssertEqual(preview.messages.first?.text, "hello 世界")
        XCTAssertEqual(preview.messages[1].text, "answer")
        XCTAssertEqual(preview.messages[2].text, "answer\ncontinued")
        XCTAssertTrue(preview.warning?.contains("工具") == true)
    }

    func testUTF8AcrossChunksAndMalformedLine() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rollout.jsonl")
        let value = #"{"type":"message","role":"user","content":[{"type":"input_text","text":"跨块 UTF-8"}]}"#
        let bytes = Data(("not-json\n" + value + "\n").utf8)
        try bytes.write(to: url)

        let preview = try SessionPreviewReader.read(url: url, limits: .init(readChunkBytes: 2))
        XCTAssertEqual(preview.messages.count, 1)
        XCTAssertEqual(preview.messages[0].text, "跨块 UTF-8")
        XCTAssertTrue(preview.warning?.contains("损坏") == true)
    }

    func testMessageLimitReturnsTruncatedPreview() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rollout.jsonl")
        let rows = (0..<3).map { index in #"{"type":"message","role":"user","text":"row-\#(index)"}"# }
        try rows.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let preview = try SessionPreviewReader.read(url: url, limits: .init(maxMessages: 2))
        XCTAssertEqual(preview.messages.count, 2)
        XCTAssertTrue(preview.truncated)
        XCTAssertTrue(preview.warning?.contains("文件开头") == true)
    }

    func testByteLimitAndOversizedLineRecoverWithoutParsingPartialLine() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rollout.jsonl")
        let huge = String(repeating: "x", count: 400)
        let text = huge + "\n" + #"{"type":"message","role":"user","text":"visible"}"# + "\n" + String(repeating: "y", count: 100)
        try text.data(using: .utf8)!.write(to: url)

        let preview = try SessionPreviewReader.read(url: url, limits: .init(maxDecompressedBytes: 480, readChunkBytes: 11, maxLineBytes: 256))
        XCTAssertEqual(preview.messages.map { $0.text }, ["visible"])
        XCTAssertTrue(preview.truncated)
        XCTAssertTrue(preview.warning?.contains("损坏") == true)
    }

    func testPreCancelledReadThrowsCancellationError() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rollout.jsonl")
        try Data(#"{"type":"message","role":"user","text":"cancel"}"#.utf8).write(to: url)
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SessionPreviewReader.read(url: url)
        }
        do {
            _ = try await worker.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testMissingAndNo正文AreExplicitErrors() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.jsonl")
        XCTAssertThrowsError(try SessionPreviewReader.read(url: missing)) { error in
            guard case SessionPreviewReaderError.fileMissing = error else { return XCTFail("unexpected error: \(error)") }
        }
        let toolOnly = root.appendingPathComponent("tool.jsonl")
        try #"{"type":"response_item","payload":{"type":"function_call","name":"x"}}"#.data(using: .utf8)!.write(to: toolOnly)
        XCTAssertThrowsError(try SessionPreviewReader.read(url: toolOnly)) { error in
            guard case SessionPreviewReaderError.noDisplayableContent = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testZstdRoundTripWhenInstalled() throws {
        guard let zstd = findZstd() else { throw XCTSkip("zstd is not installed") }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("rollout.jsonl")
        let compressed = root.appendingPathComponent("rollout.jsonl.zst")
        try #"{"type":"message","role":"assistant","text":"compressed"}"#.data(using: .utf8)!.write(to: plain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-f", "-q", plain.path, "-o", compressed.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let preview = try SessionPreviewReader.read(url: compressed)
        XCTAssertEqual(preview.messages.first?.text, "compressed")
    }

    func testCorruptZstdIsAnExplicitDecompressionError() throws {
        guard findZstd() != nil else { throw XCTSkip("zstd is not installed") }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("broken.jsonl.zst")
        try Data("not a zstd stream".utf8).write(to: url)
        XCTAssertThrowsError(try SessionPreviewReader.read(url: url)) { error in
            guard case SessionPreviewReaderError.decompressionFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testRealDataSmokeIsOptInAndDoesNotPrint正文() throws {
        guard ProcessInfo.processInfo.environment["CODEX_CLEANER_TEST_REAL_DATA"] == "1" else {
            throw XCTSkip("Set CODEX_CLEANER_TEST_REAL_DATA=1 to inspect live rollout files.")
        }
        let root = SessionStore.defaultCodexRoot()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? []
        let allowed = files.filter { url in
            url.pathComponents.contains("sessions") || url.pathComponents.contains("archived_sessions")
        }
        guard let plain = allowed.first(where: { $0.pathExtension == "jsonl" }),
              let compressed = allowed.first(where: { $0.lastPathComponent.hasSuffix(".jsonl.zst") }) else {
            throw XCTSkip("No ordinary and compressed rollout pair under sessions/archived_sessions.")
        }
        for url in [plain, compressed] {
            let preview = try SessionPreviewReader.read(url: url)
            XCTAssertTrue(!preview.messages.isEmpty || preview.truncated)
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexCleanerPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func findZstd() -> String? {
        ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd", "/bin/zstd"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
