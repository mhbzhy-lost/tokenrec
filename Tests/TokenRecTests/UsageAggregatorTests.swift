import XCTest
@testable import TokenRec

final class UsageAggregatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private var now: Date { date("2026-08-19T13:30:00Z") }

    func testGranularityMetadata() {
        XCTAssertEqual(Granularity.hour.title, "按小时")
        XCTAssertEqual(Granularity.day.title, "按天")
        XCTAssertEqual(Granularity.week.title, "按周")
        XCTAssertEqual(Granularity.month.title, "按月")
        XCTAssertEqual([Granularity.hour.bucketCount, Granularity.day.bucketCount, Granularity.week.bucketCount, Granularity.month.bucketCount], [24, 30, 12, 12])
    }

    func testHourlyAggregationIncludesCurrentHourAndSumsRecords() {
        let records = [record("2026-08-19T12:45:00Z", input: 3, output: 4), record("2026-08-19T13:15:00Z", input: 5)]
        let points = UsageAggregator.aggregate(records, granularity: .hour, now: now, calendar: calendar)

        XCTAssertEqual(points.count, 24)
        XCTAssertEqual(points.suffix(2).map(\.totalTokens), [7, 5])
        XCTAssertEqual(points.last?.date, date("2026-08-19T13:00:00Z"))
    }

    func testDailyAggregationFillsMissingBucketsInAscendingOrder() {
        let points = UsageAggregator.aggregate([record("2026-08-01T12:00:00Z", input: 9)], granularity: .day, now: now, calendar: calendar)

        XCTAssertEqual(points.count, 30)
        XCTAssertEqual(points.first?.date, date("2026-07-21T00:00:00Z"))
        XCTAssertEqual(points.map(\.date), points.map(\.date).sorted())
        XCTAssertEqual(points.first?.totalTokens, 0)
        XCTAssertEqual(points[11].totalTokens, 9)
        XCTAssertEqual(points.last?.totalTokens, 0)
    }

    func testWeeklyAggregationUsesCalendarWeeks() {
        let points = UsageAggregator.aggregate([record("2026-08-18T12:00:00Z", input: 10)], granularity: .week, now: now, calendar: calendar)

        XCTAssertEqual(points.count, 12)
        XCTAssertEqual(points.last?.date, date("2026-08-17T00:00:00Z"))
        XCTAssertEqual(points.last?.totalTokens, 10)
    }

    func testMonthlyAggregationGroupsRecordsAndDefaultsCostToZero() {
        let records = [record("2026-08-01T12:00:00Z", input: 4), record("2026-08-18T12:00:00Z", input: 6)]
        let points = UsageAggregator.aggregate(records, granularity: .month, now: now, calendar: calendar)

        XCTAssertEqual(points.count, 12)
        XCTAssertEqual(points.last?.date, date("2026-08-01T00:00:00Z"))
        XCTAssertEqual(points.last?.totalTokens, 10)
        XCTAssertEqual(points.last?.cost, 0)
    }

    func testSummaryUsesWholeDayAndMonthAndSumsReportedCost() {
        let records = [
            record("2026-08-19T10:15:00Z", input: 100, cost: 0.10),
            record("2026-08-19T13:15:00Z", input: 200, cost: 0.20),
            record("2026-07-31T23:00:00Z", input: 50, cost: 0.05),
        ]

        let summary = UsageAggregator.summarize(records, now: now, calendar: calendar)

        XCTAssertEqual(summary.todayTokens, 300)
        XCTAssertEqual(summary.monthTokens, 300)
        XCTAssertEqual(summary.totalTokens, 350)
        XCTAssertEqual(summary.totalCost, 0.35, accuracy: 0.000_001)
        XCTAssertEqual(summary.points[.hour]?.last?.totalTokens, 200)
        XCTAssertEqual(summary.points[.hour]?.last?.cost ?? -1, 0.20, accuracy: 0.000_001)
    }

    func testByModelGroupsPerModelWithTodayMonthTotalCost() {
        let records = [
            record("2026-08-19T10:15:00Z", input: 100, cost: 0.10, model: "model-a"),
            record("2026-08-19T13:15:00Z", input: 200, cost: 0.20, model: "model-a"),
            record("2026-08-19T10:00:00Z", input: 50, cost: 0.05, model: "model-b"), // 今天
            record("2026-07-31T23:00:00Z", input: 30, cost: 0.03, model: "model-b"), // 上月
            record("2026-08-19T09:00:00Z", input: 10, cost: 0.01, model: nil), // 无 model → unknown
        ]

        let byModel = UsageAggregator.byModel(records, now: now, calendar: calendar)
        XCTAssertEqual(byModel.count, 3)

        let a = byModel.first { $0.model == "model-a" }
        XCTAssertEqual(a?.todayTokens, 300)
        XCTAssertEqual(a?.monthTokens, 300)
        XCTAssertEqual(a?.totalTokens, 300)
        XCTAssertEqual(a?.totalCost ?? 0, 0.30, accuracy: 0.000_001)

        let b = byModel.first { $0.model == "model-b" }
        XCTAssertEqual(b?.todayTokens, 50)
        XCTAssertEqual(b?.monthTokens, 50)
        XCTAssertEqual(b?.totalTokens, 80)
        XCTAssertEqual(b?.totalCost ?? 0, 0.08, accuracy: 0.000_001)

        let unknown = byModel.first { $0.model == "unknown" }
        XCTAssertEqual(unknown?.totalTokens, 10)
        XCTAssertEqual(unknown?.totalCost ?? 0, 0.01, accuracy: 0.000_001)
    }

    func testByModelSortsByTotalTokensDescending() {
        let records = [
            record("2026-08-19T10:00:00Z", input: 10, model: "small"),
            record("2026-08-19T11:00:00Z", input: 500, model: "large"),
            record("2026-08-19T12:00:00Z", input: 100, model: "medium"),
        ]
        let byModel = UsageAggregator.byModel(records, now: now, calendar: calendar)
        XCTAssertEqual(byModel.map(\.model), ["large", "medium", "small"])
    }

    private func record(_ timestamp: String, input: Int, output: Int = 0, cost: Double = 0, model: String? = nil) -> UsageRecord {
        UsageRecord(timestamp: date(timestamp), inputTokens: input, outputTokens: output, cost: cost, source: "test", model: model)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
