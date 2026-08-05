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

    func testResolveSessionDirPrefersConfiguredThenEnvironmentDirectoryWithSessions() throws {
        try write("{}", to: "configured/session.jsonl")
        try write("{}", to: "environment/session.jsonl")
        defaults.set("~/configured", forKey: "sessionDir")
        let configured = SessionScanner(userDefaults: defaults, environment: ["PI_CODING_AGENT_SESSION_DIR": "~/environment"], homeDirectory: root)
        XCTAssertEqual(configured.resolveSessionDir(), root.appendingPathComponent("configured"))

        defaults.set("   ", forKey: "sessionDir")
        XCTAssertEqual(configured.resolveSessionDir(), root.appendingPathComponent("environment"))
    }

    func testResolveSessionDirIgnoresBlankOverridesAndUsesCurrentPiSessions() throws {
        try write("{}", to: "pi-config/var/sessions/session.jsonl")
        defaults.set(" ", forKey: "sessionDir")
        let scanner = SessionScanner(userDefaults: defaults, environment: ["PI_CODING_AGENT_SESSION_DIR": ""], homeDirectory: root)
        XCTAssertEqual(scanner.resolveSessionDir(), root.appendingPathComponent("pi-config/var/sessions"))
    }

    func testResolveSessionDirFallsBackToLegacyDirectoryWhenCurrentPiSessionsAreEmpty() throws {
        try write("{}", to: ".pi/agent/sessions/session.jsonl")
        let scanner = SessionScanner(userDefaults: defaults, environment: [:], homeDirectory: root)
        XCTAssertEqual(scanner.resolveSessionDir(), root.appendingPathComponent(".pi/agent/sessions"))
    }

    func testSessionDescriptorsExtractChildRunIdentityFromHeader() {
        let fixtureDir = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/scanner")
        let descriptors = SessionScanner.sessionDescriptors(in: fixtureDir)

        XCTAssertEqual(descriptors.count, 3)
        let child = descriptors.first { $0.sessionId == "fixture-session-1" }
        XCTAssertEqual(child?.cwd, "/fixture/project")
        XCTAssertEqual(child?.subagentRunId, "461a119b-b402-47bf-ac62-397c3b5b336f")
        let ordinary = descriptors.first { $0.sessionId == "fixture-session-2" }
        XCTAssertNil(ordinary?.subagentRunId)
        let configuredAgent = descriptors.first { $0.sessionId == "fixture-session-3" }
        XCTAssertEqual(configuredAgent?.subagentRunId, "44444444-4444-4444-8444-444444444444")
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

    @discardableResult private func write(_ contents: String, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
