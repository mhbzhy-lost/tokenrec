import SwiftUI

/// 按模型分组的用量列表（累计 tokens 降序）
struct ModelUsageView: View {
    let modelUsage: [ModelUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模型用量")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(modelUsage) { usage in
                HStack(spacing: 8) {
                    Text(usage.model)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 150, alignment: .leading)
                        .help(usage.model)

                    Text("今日 \(TokenFormat.compact(usage.todayTokens))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 90, alignment: .trailing)

                    Text("累计 \(TokenFormat.compact(usage.totalTokens))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 100, alignment: .trailing)

                    Spacer(minLength: 0)

                    Text(String(format: "$%.2f", usage.totalCost))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if modelUsage.isEmpty {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
