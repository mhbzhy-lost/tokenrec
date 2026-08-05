import SwiftUI

struct UsageStatsView: View {
    let todayTokens: Int
    let monthTokens: Int
    let totalTokens: Int

    var body: some View {
        HStack(spacing: 10) {
            StatCard(title: "今日", value: TokenFormat.compact(todayTokens), unit: "tokens")
            StatCard(title: "本月", value: TokenFormat.compact(monthTokens), unit: "tokens")
            StatCard(title: "累计", value: TokenFormat.compact(totalTokens), unit: "tokens")
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
