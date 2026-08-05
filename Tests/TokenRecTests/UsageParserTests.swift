import XCTest
@testable import TokenRec

final class UsageParserTests: XCTestCase {
    func testParsesMessageUsage() throws {
        let records = try UsageParser.parseSession("{\"type\":\"message\",\"timestamp\":\"2026-08-04T13:15:14.158Z\",\"message\":{\"usage\":{\"input\":10,\"output\":20,\"cacheRead\":30,\"cacheWrite\":40}}}")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].totalTokens, 100)
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

    func testRealFilesProduceRecords() throws {
        let session = URL(fileURLWithPath: "/Users/mhbzhy/pi-config/var/sessions/2026-08-04T13-15-14-158Z_019fcce9-fb6e-7ed2-a823-32b520e22127.jsonl")
        let transcript = URL(fileURLWithPath: "/Users/mhbzhy/ai-lover-client/.pi-subagents/artifacts/461a119b-b402-47bf-ac62-397c3b5b336f_executor_transcript.jsonl")
        XCTAssertFalse(try UsageParser.parseSession(url: session).isEmpty)
        XCTAssertFalse(try UsageParser.parseSubagentTranscript(url: transcript).isEmpty)
    }
}
