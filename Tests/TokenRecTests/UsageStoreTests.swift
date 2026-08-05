import Foundation
import XCTest
@testable import TokenRec

final class UsageStoreTests: XCTestCase {
    @MainActor
    func testRefreshPublishesSummaryCostErrorsAndDataDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenrec-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try "{}\n".write(to: sessionDir.appendingPathComponent("marker.jsonl"), atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "UsageStoreTests.\(UUID().uuidString)")!
        defaults.set(sessionDir.path, forKey: "sessionDir")
        let scanner = SessionScanner(userDefaults: defaults, environment: [:], homeDirectory: root)
        let now = date("2026-08-19T13:30:00Z")
        let records = [
            record("2026-08-19T10:15:00Z", tokens: 100, cost: 0.10),
            record("2026-08-19T13:15:00Z", tokens: 200, cost: 0.20),
        ]
        let repository = StubUsageRepository(result: UsageLoadResult(
            records: records,
            errors: [UsageLoadError(path: "/fixture/bad.jsonl", message: "permission denied")]
        ))
        let store = UsageStore(
            repository: repository,
            scanner: scanner,
            now: { now },
            calendar: utcCalendar,
            startsMonitoring: false
        )

        await store.refresh()

        XCTAssertEqual(store.summary.todayTokens, 300)
        XCTAssertEqual(store.summary.monthTokens, 300)
        XCTAssertEqual(store.summary.totalTokens, 300)
        XCTAssertEqual(store.summary.totalCost, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(store.dataDirectory.standardizedFileURL.path, sessionDir.standardizedFileURL.path)
        XCTAssertEqual(store.lastError, "/fixture/bad.jsonl: permission denied")
    }

    @MainActor
    func testConcurrentRefreshCallsDoNotOverlapRepositoryLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenrec-store-overlap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try "{}\n".write(to: sessionDir.appendingPathComponent("marker.jsonl"), atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "UsageStoreTests.\(UUID().uuidString)")!
        defaults.set(sessionDir.path, forKey: "sessionDir")
        let repository = SlowUsageRepository()
        let store = UsageStore(
            repository: repository,
            scanner: SessionScanner(userDefaults: defaults, environment: [:], homeDirectory: root),
            startsMonitoring: false
        )

        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)

        let loadCount = await repository.loadCount()
        XCTAssertEqual(loadCount, 1)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func record(_ timestamp: String, tokens: Int, cost: Double) -> UsageRecord {
        UsageRecord(timestamp: date(timestamp), inputTokens: tokens, outputTokens: 0, cost: cost, source: "test")
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private actor StubUsageRepository: UsageLoading {
    let result: UsageLoadResult

    init(result: UsageLoadResult) {
        self.result = result
    }

    func load(sessionDir: URL) async -> UsageLoadResult {
        result
    }
}

private actor SlowUsageRepository: UsageLoading {
    private var count = 0

    func load(sessionDir: URL) async -> UsageLoadResult {
        count += 1
        try? await Task.sleep(for: .milliseconds(50))
        return UsageLoadResult(records: [], errors: [])
    }

    func loadCount() -> Int {
        count
    }
}
