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

    private func record(_ timestamp: String, input: Int, output: Int = 0) -> UsageRecord {
        UsageRecord(timestamp: date(timestamp), inputTokens: input, outputTokens: output, source: "test")
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
