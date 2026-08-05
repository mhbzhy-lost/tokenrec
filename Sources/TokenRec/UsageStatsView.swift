import SwiftUI

struct UsageStatsView: View {
    let records: [UsageRecord]

    private var calendar: Calendar { .current }
    private var todayTokens: Int {
        UsageAggregator.aggregate(records, granularity: .hour, calendar: calendar).last?.totalTokens ?? 0
    }
    private var monthTokens: Int {
        records.filter { calendar.isDate($0.timestamp, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.totalTokens }
    }
    private var totalTokens: Int { records.reduce(0) { $0 + $1.totalTokens } }

    var body: some View {
        HStack(spacing: 10) {
            StatCard(title: "今日", value: todayTokens.formatted(.number.notation(.compactName)), unit: "tokens")
            StatCard(title: "本月", value: monthTokens.formatted(.number.notation(.compactName)), unit: "tokens")
            StatCard(title: "累计", value: totalTokens.formatted(.number.notation(.compactName)), unit: "tokens")
            StatCard(title: "累计成本", value: "$0.00", unit: "")
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
