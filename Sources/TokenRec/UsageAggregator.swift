import Foundation

enum Granularity: CaseIterable, Sendable {
    case hour
    case day
    case week
    case month

    var title: String {
        switch self {
        case .hour: "按小时"
        case .day: "按天"
        case .week: "按周"
        case .month: "按月"
        }
    }

    var bucketCount: Int {
        switch self {
        case .hour: 24
        case .day: 30
        case .week, .month: 12
        }
    }

    fileprivate var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

struct UsagePoint: Identifiable, Equatable, Sendable {
    let id: Date
    let date: Date
    let totalTokens: Int
    let cost: Double

    init(date: Date, totalTokens: Int, cost: Double = 0) {
        self.id = date
        self.date = date
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

enum UsageAggregator {
    static func aggregate(
        _ records: [UsageRecord],
        granularity: Granularity,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UsagePoint] {
        guard let currentBucket = calendar.dateInterval(of: granularity.component, for: now)?.start,
              let firstBucket = calendar.date(byAdding: granularity.component, value: -(granularity.bucketCount - 1), to: currentBucket) else {
            return []
        }

        var totals: [Date: Int] = [:]
        for record in records {
            guard let bucket = calendar.dateInterval(of: granularity.component, for: record.timestamp)?.start,
                  bucket >= firstBucket, bucket <= currentBucket else { continue }
            totals[bucket, default: 0] += record.totalTokens
        }

        return (0..<granularity.bucketCount).compactMap { offset in
            guard let bucket = calendar.date(byAdding: granularity.component, value: offset, to: firstBucket) else {
                return nil
            }
            return UsagePoint(date: bucket, totalTokens: totals[bucket, default: 0])
        }
    }
}
