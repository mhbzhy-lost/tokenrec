import Charts
import SwiftUI

struct UsageChartView: View {
    let points: [UsagePoint]
    let window: UsageWindow

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("时间", point.date),
                y: .value("Token", point.totalTokens)
            )
            .foregroundStyle(.blue.opacity(0.16))
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("时间", point.date),
                y: .value("Token", point.totalTokens)
            )
            .foregroundStyle(.blue)
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: axisFormat)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(TokenFormat.compact(tokens))
                    }
                }
            }
        }
        .frame(height: 210)
    }

    private var axisFormat: Date.FormatStyle {
        switch window {
        case .today: .dateTime.hour()
        case .days7, .days30: .dateTime.month().day()
        }
    }
}
