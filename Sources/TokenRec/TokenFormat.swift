import Foundation

/// Token 数值的压缩显示格式
enum TokenFormat {
    /// ≥1 亿显示 E，≥100 万显示 M（百万），≥1 千显示 K，否则原值；如 5.0E / 68.3M / 24.5K
    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case 100_000_000...:
            return String(format: "%.1fE", Double(tokens) / 100_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(tokens) / 1_000)
        default:
            return "\(tokens)"
        }
    }
}
