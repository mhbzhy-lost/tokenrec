import SwiftUI

/// 按模型分组的用量列表：窗口口径跟随粒度切换（近 24 小时 / 30 天 / 12 周 / 12 月），按窗口 tokens 降序
struct ModelUsageView: View {
    let modelUsage: [ModelUsage]
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("模型用量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(window.title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ForEach(modelUsage) { usage in
                HStack(spacing: 8) {
                    Text(usage.model)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 140, alignment: .leading)
                        .help(usage.model)

                    Text(TokenFormat.compact(usage.windowTokens))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)

                    Text(TokenFormat.compact(usage.totalTokens))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)

                    Spacer(minLength: 0)

                    Text(String(format: "$%.2f", usage.windowCost))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
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
