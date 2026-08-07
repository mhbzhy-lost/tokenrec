import Foundation

/// 统计口径：小时/今天/7天/30天（非历法，用于面板切换与模型用量窗口）
enum UsageWindow: CaseIterable, Hashable, Sendable, Identifiable {
    case hour
    case today
    case days7
    case days30

    var id: Self { self }

    var title: String {
        switch self {
        case .hour: "小时"
        case .today: "今天"
        case .days7: "7天"
        case .days30: "30天"
        }
    }

    /// 窗口内数据点数量（图表）
    var pointCount: Int {
        switch self {
        case .hour, .today: 24
        case .days7: 7
        case .days30: 30
        }
    }

    /// 数据点间隔组件
    fileprivate var pointComponent: Calendar.Component {
        switch self {
        case .hour, .today: .hour
        case .days7, .days30: .day
        }
    }

    /// 窗口起点（byModel 聚合口径）
    fileprivate func windowStart(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .hour:
            return calendar.date(byAdding: .hour, value: -(24 - 1), to: calendar.dateInterval(of: .hour, for: now)!.start)
        case .today:
            return calendar.dateInterval(of: .day, for: now)?.start
        case .days7:
            return calendar.date(byAdding: .day, value: -(7 - 1), to: calendar.dateInterval(of: .day, for: now)!.start)
        case .days30:
            return calendar.date(byAdding: .day, value: -(30 - 1), to: calendar.dateInterval(of: .day, for: now)!.start)
        }
    }
}

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
    let windowTokens: Int
    let windowCost: Double
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

    /// 按窗口生成图表数据点（小时=近24整点、今天=今日24整点、7天/30天=逐自然日），升序补零。
    static func points(
        records: [UsageRecord],
        window: UsageWindow,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UsagePoint] {
        guard let firstBucket = window.windowStart(now: now, calendar: calendar),
              let currentBucket = calendar.dateInterval(of: window.pointComponent, for: now)?.start else {
            return []
        }
        var tokenTotals: [Date: Int] = [:]
        var costTotals: [Date: Double] = [:]
        for record in records {
            guard let bucket = calendar.dateInterval(of: window.pointComponent, for: record.timestamp)?.start,
                  bucket >= firstBucket, bucket <= currentBucket else { continue }
            tokenTotals[bucket, default: 0] += record.totalTokens
            costTotals[bucket, default: 0] += record.cost
        }
        return (0..<window.pointCount).compactMap { offset in
            guard let bucket = calendar.date(byAdding: window.pointComponent, value: offset, to: firstBucket) else { return nil }
            return UsagePoint(date: bucket, totalTokens: tokenTotals[bucket, default: 0], cost: costTotals[bucket, default: 0])
        }
    }

    /// 按模型分组统计（窗口内用量/成本 + 全量累计），按窗口 tokens 降序；无 model 记录归入 "unknown"。
    /// 窗口口径跟随 UsageWindow：近 24 小时 / 今天 0 点起 / 近 7 天 / 近 30 天。
    static func byModel(
        _ records: [UsageRecord],
        window: UsageWindow,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ModelUsage] {
        guard let start = window.windowStart(now: now, calendar: calendar) else { return [] }
        var groups: [String: (window: Int, windowCost: Double, total: Int, cost: Double)] = [:]
        for record in records {
            let name = (record.model?.isEmpty == false) ? record.model! : "unknown"
            var group = groups[name] ?? (0, 0, 0, 0)
            group.total += record.totalTokens
            group.cost += record.cost
            if record.timestamp >= start {
                group.window += record.totalTokens
                group.windowCost += record.cost
            }
            groups[name] = group
        }
        return groups.map {
            ModelUsage(model: $0.key, windowTokens: $0.value.window, windowCost: $0.value.windowCost,
                       totalTokens: $0.value.total, totalCost: $0.value.cost)
        }
        .sorted { $0.windowTokens > $1.windowTokens }
    }
}
