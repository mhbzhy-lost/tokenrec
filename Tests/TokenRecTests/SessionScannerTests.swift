import XCTest
@testable import TokenRec

final class SessionScannerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "SessionScannerTests.\(UUID().uuidString)")!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")
    }

    func testResolveSessionDirUsesDefaultsThenEnvironmentThenHome() {
        let scanner = SessionScanner(userDefaults: defaults, environment: ["PI_CODING_AGENT_SESSION_DIR": "~/environment"], homeDirectory: root)
        XCTAssertEqual(scanner.resolveSessionDir(), root.appendingPathComponent("environment"))
        defaults.set("~/configured", forKey: "sessionDir")
        XCTAssertEqual(scanner.resolveSessionDir(), root.appendingPathComponent("configured"))
        let fallback = SessionScanner(userDefaults: UserDefaults(suiteName: UUID().uuidString)!, environment: [:], homeDirectory: root)
        XCTAssertEqual(fallback.resolveSessionDir(), root.appendingPathComponent(".pi/agent/sessions"))
    }

    func testAllSessionFilesRecursivelyCollectsSortedJSONLFiles() throws {
        try write("", to: "z.jsonl")
        try write("", to: "nested/a.jsonl")
        try write("", to: "nested/ignore.txt")
        XCTAssertEqual(SessionScanner.allSessionFiles(in: root).map(\.lastPathComponent), ["a.jsonl", "z.jsonl"])
    }

    func testProjectCwdsExtractsUniqueValues() throws {
        let first = try write("{\"cwd\":\"/one\"}\n{\"cwd\":\"/two\"}", to: "one.jsonl")
        let second = try write("{\"cwd\":\"/one\"}", to: "two.jsonl")
        XCTAssertEqual(SessionScanner.projectCwds(from: [second, first]), ["/one", "/two"])
    }

    func testSubagentArtifactDirsOnlyReturnsExistingDirectories() throws {
        let existing = root.appendingPathComponent("project/.pi-subagents/artifacts")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        XCTAssertEqual(SessionScanner.subagentArtifactDirs(for: [root.appendingPathComponent("missing").path, root.appendingPathComponent("project").path]).map(\.standardizedFileURL), [existing.standardizedFileURL])
    }

    func testAllSubagentFilesFindsTranscriptAndMetaFiles() throws {
        try write("", to: "x_transcript.jsonl")
        try write("", to: "nested/y_meta.json")
        try write("", to: "z.jsonl")
        XCTAssertEqual(SessionScanner.allSubagentFiles(in: [root]).map(\.lastPathComponent), ["y_meta.json", "x_transcript.jsonl"])
    }

    @MainActor
    func testUsageStoreIncludesNestedSubagentSessions() throws {
        // subagent 进程的会话记录位于 var/sessions 下嵌套目录（<parent>/<hash>/run-0/session.jsonl）
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try write("{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"usage\":{\"input\":1}}", to: "sessions/main.jsonl")
        try write("{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:01Z\",\"usage\":{\"input\":2}}", to: "sessions/2026-01-01T00-00-00Z_parent/abc123/run-0/session.jsonl")
        try write("{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:02Z\",\"usage\":{\"input\":3}}", to: "sessions/2026-01-01T00-00-00Z_parent/def456/run-0/session.jsonl")
        let store = UsageStore(scanner: SessionScanner(userDefaults: defaults, environment: ["PI_CODING_AGENT_SESSION_DIR": sessions.path], homeDirectory: root))
        // refresh 为异步后台解析，等待记录就绪
        let exp = expectation(description: "async refresh")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if !store.records.isEmpty { exp.fulfill(); timer.invalidate() }
        }
        wait(for: [exp], timeout: 5)
        // 合并顺序按文件路径排序，无序比较 token 集合
        XCTAssertEqual(Set(store.records.map(\.totalTokens)), [1, 2, 3])
    }

    @MainActor
    private func waitForRecords(_ store: UsageStore, timeout: TimeInterval = 5) {
        let exp = expectation(description: "async refresh")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if !store.records.isEmpty { exp.fulfill(); timer.invalidate() }
        }
        wait(for: [exp], timeout: timeout)
        timer.invalidate()
    }

    @MainActor
    func testUsageStoreIncrementalAppendOnlyParsesNewLines() throws {
        // pi 会话文件 append-only：追加行后二次 refresh 应只增量解析、不重复不遗漏
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let main = try write("{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"usage\":{\"input\":1}}\n{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:01Z\",\"usage\":{\"input\":2}}", to: "sessions/main.jsonl")
        let store = UsageStore(scanner: SessionScanner(userDefaults: defaults, environment: ["PI_CODING_AGENT_SESSION_DIR": sessions.path], homeDirectory: root))
        waitForRecords(store)
        XCTAssertEqual(Set(store.records.map(\.totalTokens)), [1, 2])

        // 追加一行（模拟 pi 新消息），sleep 确保 mtime 变化
        try Thread.sleep(forTimeInterval: 1.1)
        let handle = try FileHandle(forWritingTo: main)
        try handle.seekToEnd()
        try handle.write(contentsOf: "\n{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:02Z\",\"usage\":{\"input\":3}}".data(using: .utf8)!)
        try handle.close()

        // 等待下一次轮询触发（测试内手动触发 refresh）
        let before = store.records
        store.refresh()
        let exp = expectation(description: "incremental refresh")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if store.records.count > before.count { exp.fulfill(); timer.invalidate() }
        }
        wait(for: [exp], timeout: 5)
        timer.invalidate()
        XCTAssertEqual(Set(store.records.map(\.totalTokens)), [1, 2, 3])
    }

    @MainActor
    func testUsageStoreFullReparseWhenFileRewritten() throws {
        // 文件被重写（size 变小）：应全量重解析，不残留旧记录
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let main = try write("{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"usage\":{\"input\":1}}\n{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:01Z\",\"usage\":{\"input\":2}}", to: "sessions/main.jsonl")
        let store = UsageStore(scanner: SessionScanner(userDefaults: defaults, environment: ["PI_CODING_AGENT_SESSION_DIR": sessions.path], homeDirectory: root))
        waitForRecords(store)
        XCTAssertEqual(Set(store.records.map(\.totalTokens)), [1, 2])

        try Thread.sleep(forTimeInterval: 1.1)
        try "{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:05Z\",\"usage\":{\"input\":9}}".write(to: main, atomically: true, encoding: .utf8)

        store.refresh()
        let exp = expectation(description: "reparse refresh")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if store.records.map(\.totalTokens) == [9] { exp.fulfill(); timer.invalidate() }
        }
        wait(for: [exp], timeout: 5)
        timer.invalidate()
        XCTAssertEqual(store.records.map(\.totalTokens), [9])
    }

    @discardableResult private func write(_ contents: String, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
