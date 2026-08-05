import Foundation

struct UsageRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let source: String
    let model: String?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        source: String,
        model: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.source = source
        self.model = model
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }
}
