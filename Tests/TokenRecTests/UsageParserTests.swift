import XCTest
@testable import TokenRec

final class UsageParserTests: XCTestCase {
    func testParsesMessageUsage() throws {
        let records = try UsageParser.parseSession("{\"type\":\"message\",\"timestamp\":\"2026-08-04T13:15:14.158Z\",\"message\":{\"usage\":{\"input\":10,\"output\":20,\"cacheRead\":30,\"cacheWrite\":40}}}")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].totalTokens, 100)
    }

    func testParsesReportedCostFromSessionAndTranscriptFixtures() throws {
        let sessionRecords = try UsageParser.parseSession(url: fixtureURL("session-cost.jsonl"))
        let transcriptRecords = try UsageParser.parseSubagentTranscript(url: fixtureURL("transcript-cost.jsonl"))

        XCTAssertEqual(sessionRecords.count, 1)
        XCTAssertEqual(sessionRecords[0].cost, 0.0125, accuracy: 0.000_001)
        XCTAssertEqual(transcriptRecords.count, 1)
        XCTAssertEqual(transcriptRecords[0].cost, 0.0125, accuracy: 0.000_001)
    }

    func testParsesToolResultAndCompactionUsage() throws {
        let input = "{\"type\":\"toolResult\",\"timestamp\":\"2026-08-04T13:15:14Z\",\"usage\":{\"input\":1,\"output\":2}}\n{\"type\":\"compaction\",\"timestamp\":\"2026-08-04T13:16:14Z\",\"usage\":{\"input\":3,\"output\":4}}"
        XCTAssertEqual(try UsageParser.parseSession(input).map(\.totalTokens), [3, 7])
    }

    func testParsesUnixMillisecondsTimestamp() throws {
        let records = try UsageParser.parseSession("{\"type\":\"compaction\",\"timestamp\":1785351293347,\"usage\":{\"input\":1,\"output\":1}}")
        XCTAssertEqual(records[0].timestamp.timeIntervalSince1970, 1_785_351_293.347, accuracy: 0.001)
    }

    func testSkipsMalformedLines() throws {
        let input = "not json\n{\"type\":\"message\",\"timestamp\":\"bad\",\"message\":{\"usage\":{\"input\":1}}}\n{\"type\":\"message\",\"timestamp\":\"2026-08-04T13:15:14Z\",\"message\":{\"usage\":{\"input\":2}}}"
        XCTAssertEqual(try UsageParser.parseSession(input).count, 1)
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try UsageParser.parseSession(" \n"))
    }

    func testParsesOnlyAssistantSubagentMessages() throws {
        let input = "{\"recordType\":\"message\",\"role\":\"user\",\"timestamp\":\"2026-08-04T13:15:14Z\",\"usage\":{\"input\":99}}\n{\"recordType\":\"message\",\"role\":\"assistant\",\"timestamp\":\"2026-08-04T13:15:14Z\",\"usage\":{\"input\":1,\"output\":2,\"cacheRead\":3,\"cacheWrite\":4}}"
        XCTAssertEqual(try UsageParser.parseSubagentTranscript(input).map(\.totalTokens), [10])
    }

    func testParsesSubagentMetaAttempts() throws {
        let input = "{\"timestamp\":1785351293347,\"modelAttempts\":[{\"model\":\"one\",\"usage\":{\"input\":1,\"output\":2}},{\"model\":\"two\",\"usage\":{\"input\":3,\"cacheRead\":4}}]}"
        let records = try UsageParser.parseSubagentMeta(input)
        XCTAssertEqual(records.map(\.totalTokens), [3, 7])
        XCTAssertEqual(records[0].model, "one")
    }

    func testExtractsSubagentRunID() {
        XCTAssertEqual(UsageParser.subagentRunId(from: "461a119b-b402-47bf-ac62-397c3b5b336f_executor_transcript.jsonl"), "461a119b-b402-47bf-ac62-397c3b5b336f")
        XCTAssertNil(UsageParser.subagentRunId(from: "unrelated.jsonl"))
    }

    func testRepositoryFixturesProduceRecordsWithoutMachinePaths() throws {
        XCTAssertFalse(try UsageParser.parseSession(url: fixtureURL("session-cost.jsonl")).isEmpty)
        XCTAssertFalse(try UsageParser.parseSubagentTranscript(url: fixtureURL("transcript-cost.jsonl")).isEmpty)
    }

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/parser")!
    }

    func testParseSessionFromOffsetOnlyParsesTail() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenrec-offset-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let line1 = "{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"usage\":{\"input\":1}}\n"
        let line2 = "{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:01Z\",\"usage\":{\"input\":2}}\n"
        let line3 = "{\"type\":\"message\",\"timestamp\":\"2026-01-01T00:00:02Z\",\"usage\":{\"input\":3}}"
        try (line1 + line2 + line3).write(to: tmp, atomically: true, encoding: .utf8)

        // offset = 前两行字节长度 → 只应解析出第 3 行
        let offset = Int64((line1 + line2).data(using: .utf8)!.count)
        let records = try UsageParser.parseSession(url: tmp, fromOffset: offset)
        XCTAssertEqual(records.map(\.totalTokens), [3])

        // offset = 0 → 全量解析
        let all = try UsageParser.parseSession(url: tmp, fromOffset: 0)
        XCTAssertEqual(all.map(\.totalTokens), [1, 2, 3])

        // offset = 文件末尾 → 无新记录
        let fileSize = try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as! Int
        let empty = try UsageParser.parseSession(url: tmp, fromOffset: Int64(fileSize))
        XCTAssertTrue(empty.isEmpty)
    }
}
