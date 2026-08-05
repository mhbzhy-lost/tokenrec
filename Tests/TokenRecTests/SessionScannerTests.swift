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
    func testUsageStoreSkipsMetaWhenTranscriptExistsForRun() throws {
        let sessions = root.appendingPathComponent("sessions")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try write("{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"cwd\":\"\(project.path)\",\"usage\":{\"input\":1}}", to: "sessions/main.jsonl")
        try write("{\"recordType\":\"message\",\"role\":\"assistant\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"usage\":{\"input\":2}}", to: "project/.pi-subagents/artifacts/run_executor_transcript.jsonl")
        try write("{\"timestamp\":\"2026-01-01T00:00:00Z\",\"modelAttempts\":[{\"usage\":{\"input\":99}}]}", to: "project/.pi-subagents/artifacts/run_meta.json")
        let store = UsageStore(scanner: SessionScanner(userDefaults: defaults, environment: ["PI_CODING_AGENT_SESSION_DIR": sessions.path], homeDirectory: root))
        // refresh 为异步后台解析，等待记录就绪
        let exp = expectation(description: "async refresh")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if !store.records.isEmpty { exp.fulfill(); timer.invalidate() }
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(store.records.map(\.totalTokens), [1, 2])
    }

    @discardableResult private func write(_ contents: String, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
