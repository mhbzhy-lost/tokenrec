import Foundation

enum Granularity: CaseIterable, Hashable, Sendable {
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

struct UsageSummary: Equatable, Sendable {
    let todayTokens: Int
    let monthTokens: Int
    let totalTokens: Int
    let totalCost: Double
    let points: [Granularity: [UsagePoint]]
}

struct ModelUsage: Identifiable, Equatable, Sendable {
    let model: String
    let todayTokens: Int
    let monthTokens: Int
    let totalTokens: Int
    let totalCost: Double

    var id: String { model }
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

        var tokenTotals: [Date: Int] = [:]
        var costTotals: [Date: Double] = [:]
        for record in records {
            guard let bucket = calendar.dateInterval(of: granularity.component, for: record.timestamp)?.start,
                  bucket >= firstBucket, bucket <= currentBucket else { continue }
            tokenTotals[bucket, default: 0] += record.totalTokens
            costTotals[bucket, default: 0] += record.cost
        }

        return (0..<granularity.bucketCount).compactMap { offset in
            guard let bucket = calendar.date(byAdding: granularity.component, value: offset, to: firstBucket) else {
                return nil
            }
            return UsagePoint(date: bucket, totalTokens: tokenTotals[bucket, default: 0], cost: costTotals[bucket, default: 0])
        }
    }

    static func summarize(
        _ records: [UsageRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageSummary {
        let day = calendar.dateInterval(of: .day, for: now)
        let month = calendar.dateInterval(of: .month, for: now)
        var todayTokens = 0
        var monthTokens = 0
        var totalTokens = 0
        var totalCost = 0.0
        for record in records {
            totalTokens += record.totalTokens
            totalCost += record.cost
            if day?.contains(record.timestamp) == true { todayTokens += record.totalTokens }
            if month?.contains(record.timestamp) == true { monthTokens += record.totalTokens }
        }
        let points = Dictionary(uniqueKeysWithValues: Granularity.allCases.map { granularity in
            (granularity, aggregate(records, granularity: granularity, now: now, calendar: calendar))
        })
        return UsageSummary(todayTokens: todayTokens, monthTokens: monthTokens, totalTokens: totalTokens, totalCost: totalCost, points: points)
    }

    /// 按模型分组统计（今日/本月/累计/成本），按累计 tokens 降序；无 model 记录归入 "unknown"。
    static func byModel(
        _ records: [UsageRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ModelUsage] {
        let day = calendar.dateInterval(of: .day, for: now)
        let month = calendar.dateInterval(of: .month, for: now)
        var groups: [String: (today: Int, month: Int, total: Int, cost: Double)] = [:]
        for record in records {
            let name = (record.model?.isEmpty == false) ? record.model! : "unknown"
            var group = groups[name] ?? (0, 0, 0, 0)
            group.total += record.totalTokens
            group.cost += record.cost
            if day?.contains(record.timestamp) == true { group.today += record.totalTokens }
            if month?.contains(record.timestamp) == true { group.month += record.totalTokens }
            groups[name] = group
        }
        return groups.map { ModelUsage(model: $0.key, todayTokens: $0.value.today, monthTokens: $0.value.month, totalTokens: $0.value.total, totalCost: $0.value.cost) }
            .sorted { $0.totalTokens > $1.totalTokens }
    }
}
