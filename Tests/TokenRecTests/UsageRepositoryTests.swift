import Foundation
import XCTest
@testable import TokenRec

final class UsageRepositoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenrec-repository-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSelectsChildThenTranscriptThenMetaByRunIdentity() async {
        let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/repository")
        let repository = UsageRepository(artifactDirectories: { _ in
            [fixtures.appendingPathComponent("artifacts")]
        })

        let result = await repository.load(sessionDir: fixtures.appendingPathComponent("sessions"))

        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.records.map(\.totalTokens).sorted(), [1, 12, 20, 30])
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 63)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.cost }, 0.63, accuracy: 0.000_001)
        XCTAssertEqual(result.records.filter { $0.source == "subagentTranscript" }.count, 1)
        XCTAssertEqual(result.records.filter { $0.source == "subagentMeta" }.count, 1)
    }

    func testCorruptTranscriptFallsBackToMetaAndKeepsTranscriptError() async throws {
        let sessionDir = root.appendingPathComponent("sessions")
        try write("{\"type\":\"session\",\"version\":3,\"id\":\"parent\",\"cwd\":\"/fixture\"}\n", to: sessionDir.appendingPathComponent("parent.jsonl"))
        let artifacts = root.appendingPathComponent("artifacts")
        let runId = "55555555-5555-4555-8555-555555555555"
        try write("{\"recordType\":\"message\",\"role\":\"assistant\",\"usage\":{broken}\n", to: artifacts.appendingPathComponent("\(runId)_executor_transcript.jsonl"))
        try write("{\"timestamp\":\"2026-08-05T01:00:01Z\",\"modelAttempts\":[{\"usage\":{\"input\":40,\"cost\":0.40}}]}", to: artifacts.appendingPathComponent("\(runId)_executor_meta.json"))
        let repository = UsageRepository(artifactDirectories: { _ in [artifacts] })

        let result = await repository.load(sessionDir: sessionDir)

        XCTAssertEqual(result.records.map(\.totalTokens), [40])
        XCTAssertEqual(result.records.map(\.cost), [0.40])
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].path.hasSuffix("_transcript.jsonl"))
    }

    func testSixUnchangedLoadsReuseCacheAndAppendParsesOnlyTail() async throws {
        let sessionDir = root.appendingPathComponent("sessions")
        let file = try write(session(id: "cache", input: 1), to: sessionDir.appendingPathComponent("cache.jsonl"))
        let probe = ParserProbe(base: .live)
        let repository = UsageRepository(parser: probe.parser, artifactDirectories: { _ in [] })

        let first = await repository.load(sessionDir: sessionDir)
        XCTAssertEqual(first.records.map(\.totalTokens), [1])
        for _ in 0..<5 {
            let cached = await repository.load(sessionDir: sessionDir)
            XCTAssertEqual(cached.records.map(\.totalTokens), [1])
        }
        XCTAssertEqual(probe.parseCount, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: "{\"type\":\"message\",\"timestamp\":\"2026-08-05T01:00:02Z\",\"usage\":{\"input\":2}}\n".data(using: .utf8)!)
        try handle.close()

        let appended = await repository.load(sessionDir: sessionDir)
        XCTAssertEqual(appended.records.map(\.totalTokens), [1, 2])
        XCTAssertEqual(probe.parseCount, 2)
        XCTAssertGreaterThan(probe.offsets.last ?? 0, 0)
    }

    func testIncompleteTrailingLineIsRetriedAfterAppendInsteadOfLost() async throws {
        let sessionDir = root.appendingPathComponent("sessions")
        let initial = session(id: "partial", input: 1) +
            "{\"type\":\"message\",\"timestamp\":\"2026-08-05T01:00:02Z\",\"usage\":{\"input\":"
        let file = try write(initial, to: sessionDir.appendingPathComponent("partial.jsonl"))
        let repository = UsageRepository(artifactDirectories: { _ in [] })

        let beforeAppend = await repository.load(sessionDir: sessionDir)
        XCTAssertEqual(beforeAppend.records.map(\.totalTokens), [1])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: "2}}\n".data(using: .utf8)!)
        try handle.close()

        let afterAppend = await repository.load(sessionDir: sessionDir)
        XCTAssertEqual(afterAppend.records.map(\.totalTokens), [1, 2])
    }

    func testSameSizeReplacementWithRestoredMtimeIsReparsed() async throws {
        let sessionDir = root.appendingPathComponent("sessions")
        let url = try write(session(id: "rewrite", input: 1), to: sessionDir.appendingPathComponent("rewrite.jsonl"))
        let originalMtime = try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let probe = ParserProbe(base: .live)
        let repository = UsageRepository(parser: probe.parser, artifactDirectories: { _ in [] })
        let initial = await repository.load(sessionDir: sessionDir)
        XCTAssertEqual(initial.records.map(\.totalTokens), [1])

        let replacement = session(id: "rewrite", input: 9).data(using: .utf8)!
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: url.path)

        let result = await repository.load(sessionDir: sessionDir)
        XCTAssertEqual(result.records.map(\.totalTokens), [9])
        XCTAssertEqual(probe.parseCount, 2)
    }

    func testMalformedUsageJSONIsReportedInsteadOfSilentlyCachedAsEmpty() async throws {
        let sessionDir = root.appendingPathComponent("sessions")
        let malformed = "{\"type\":\"session\",\"version\":3,\"id\":\"malformed\",\"cwd\":\"/fixture\"}\n" +
            "{\"type\":\"message\",\"timestamp\":\"2026-08-05T01:00:01Z\",\"usage\":{broken}\n"
        try write(malformed, to: sessionDir.appendingPathComponent("malformed.jsonl"))
        let repository = UsageRepository(artifactDirectories: { _ in [] })

        let result = await repository.load(sessionDir: sessionDir)

        XCTAssertTrue(result.records.isEmpty)
        let error = try XCTUnwrap(result.errors.first)
        XCTAssertTrue(error.message.contains("malformed usage JSON"))
    }

    func testParseFailureIsReportedAndRetriedWithoutCachingEmptyResult() async throws {
        let sessionDir = root.appendingPathComponent("sessions")
        try write(session(id: "retry", input: 7), to: sessionDir.appendingPathComponent("retry.jsonl"))
        let probe = ParserProbe(base: .live, failuresRemaining: 1)
        let repository = UsageRepository(parser: probe.parser, artifactDirectories: { _ in [] })

        let failed = await repository.load(sessionDir: sessionDir)
        XCTAssertTrue(failed.records.isEmpty)
        XCTAssertEqual(failed.errors.count, 1)
        XCTAssertTrue(failed.errors[0].path.hasSuffix("retry.jsonl"))

        let retried = await repository.load(sessionDir: sessionDir)
        XCTAssertEqual(retried.errors, [])
        XCTAssertEqual(retried.records.map(\.totalTokens), [7])
        XCTAssertEqual(probe.parseCount, 2)
    }

    func testChangedFilesParseConcurrentlyOutsideResultLock() async throws {
        let sessionDir = root.appendingPathComponent("sessions")
        for index in 0..<6 {
            try write("{}\n", to: sessionDir.appendingPathComponent("\(index).jsonl"))
        }
        let probe = ParserProbe(delay: 0.05)
        let repository = UsageRepository(parser: probe.parser, artifactDirectories: { _ in [] })

        _ = await repository.load(sessionDir: sessionDir)

        XCTAssertGreaterThan(probe.maxConcurrentParses, 1)
        XCTAssertLessThanOrEqual(probe.maxConcurrentParses, 8)
    }

    @discardableResult
    private func write(_ contents: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func session(id: String, input: Int) -> String {
        "{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\",\"cwd\":\"/fixture\"}\n" +
            "{\"type\":\"message\",\"timestamp\":\"2026-08-05T01:00:01Z\",\"usage\":{\"input\":\(input)}}\n"
    }
}

private final class ParserProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let base: UsageFileParser?
    private let delay: TimeInterval
    private var failuresRemaining: Int
    private var active = 0
    private(set) var parseCount = 0
    private(set) var maxConcurrentParses = 0
    private(set) var offsets: [Int64] = []

    init(base: UsageFileParser? = nil, failuresRemaining: Int = 0, delay: TimeInterval = 0) {
        self.base = base
        self.failuresRemaining = failuresRemaining
        self.delay = delay
    }

    var parser: UsageFileParser {
        UsageFileParser { [self] url, source, offset in
            lock.lock()
            parseCount += 1
            offsets.append(offset)
            active += 1
            maxConcurrentParses = max(maxConcurrentParses, active)
            let shouldFail = failuresRemaining > 0
            if shouldFail { failuresRemaining -= 1 }
            lock.unlock()
            defer {
                lock.lock()
                active -= 1
                lock.unlock()
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if shouldFail { throw ProbeError.expected }
            if let base { return try base.parse(url: url, source: source, fromOffset: offset) }
            return UsageParsedFile(
                records: [UsageRecord(timestamp: Date(timeIntervalSince1970: 1_785_000_000), inputTokens: 1, outputTokens: 0, source: "probe")],
                parsedOffset: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            )
        }
    }
}

private enum ProbeError: Error {
    case expected
}
