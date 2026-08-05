import Foundation

enum UsageParserError: Error, Equatable {
    case emptyInput
}

enum UsageParser {
    static func parseSession(_ jsonl: String) throws -> [UsageRecord] {
        guard !jsonl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageParserError.emptyInput
        }

        return jsonl.split(whereSeparator: \.isNewline).compactMap { line in
            // 快速预筛：无 usage 字段的行（绝大多数 user/tool 行）跳过完整 JSON 解析
            guard line.contains("usage") else { return nil }
            guard let object = jsonObject(String(line)),
                  let timestamp = date(object["timestamp"]),
                  let usage = usage(in: object),
                  isMainUsageRecord(object) else { return nil }
            return record(usage: usage, timestamp: timestamp, source: "session", model: string(object["model"]) ?? string(dictionary(object["message"])?["model"]))
        }
    }

    static func parseSession(url: URL) throws -> [UsageRecord] {
        try parseSession(url: url, fromOffset: 0)
    }

    /// 从指定字节偏移处开始解析（pi 会话文件 append-only，偏移=已解析长度时仅处理新增行）。
    /// offset=0 等价于全量解析；offset 可超出当前文件大小（视为无新内容）。
    static func parseSession(url: URL, fromOffset: Int64) throws -> [UsageRecord] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, fromOffset)))
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty else { return [] }
        return try parseSession(String(decoding: data, as: UTF8.self))
    }

    static func parseSubagentTranscript(_ jsonl: String) throws -> [UsageRecord] {
        guard !jsonl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageParserError.emptyInput
        }

        return jsonl.split(whereSeparator: \.isNewline).compactMap { line in
            // 快速预筛：无 usage 字段的行跳过完整 JSON 解析
            guard line.contains("usage") else { return nil }
            guard let object = jsonObject(String(line)),
                  string(object["recordType"]) == "message",
                  string(object["role"]) == "assistant",
                  let timestamp = date(object["timestamp"]) ?? date(object["ts"]),
                  let usage = dictionary(object["usage"]) else { return nil }
            return record(usage: usage, timestamp: timestamp, source: "subagentTranscript", model: string(object["model"]))
        }
    }

    static func parseSubagentTranscript(url: URL) throws -> [UsageRecord] {
        try parseSubagentTranscript(String(contentsOf: url, encoding: .utf8))
    }

    static func parseSubagentMeta(_ json: String) throws -> [UsageRecord] {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsageParserError.emptyInput
        }
        guard let object = jsonObject(json),
              let timestamp = date(object["timestamp"]),
              let attempts = object["modelAttempts"] as? [[String: Any]] else { return [] }

        return attempts.compactMap { attempt in
            guard let usage = dictionary(attempt["usage"]) else { return nil }
            return record(usage: usage, timestamp: timestamp, source: "subagentMeta", model: string(attempt["model"]))
        }
    }

    static func parseSubagentMeta(url: URL) throws -> [UsageRecord] {
        try parseSubagentMeta(String(contentsOf: url, encoding: .utf8))
    }

    static func subagentRunId(from filename: String) -> String? {
        let name = URL(fileURLWithPath: filename).lastPathComponent
        let suffixes = ["_transcript.jsonl", "_meta.json"]
        guard let suffix = suffixes.first(where: { name.hasSuffix($0) }) else { return nil }
        let runID = String(name.dropLast(suffix.count)).components(separatedBy: "_").first
        return runID?.isEmpty == false ? runID : nil
    }

    static func subagentRunId(from url: URL) -> String? {
        subagentRunId(from: url.lastPathComponent)
    }

    private static func isMainUsageRecord(_ object: [String: Any]) -> Bool {
        guard let type = string(object["type"]) else { return false }
        return type == "message" || type == "toolResult" || type == "tool_result" || type == "compaction"
    }

    private static func usage(in object: [String: Any]) -> [String: Any]? {
        dictionary(dictionary(object["message"])?["usage"]) ?? dictionary(object["usage"])
    }

    private static func record(usage: [String: Any], timestamp: Date, source: String, model: String?) -> UsageRecord {
        let cost = double(usage["cost"]) ?? double(dictionary(usage["cost"])?["total"]) ?? 0
        return UsageRecord(timestamp: timestamp, inputTokens: integer(usage["input"]), outputTokens: integer(usage["output"]), cacheReadTokens: integer(usage["cacheRead"]), cacheWriteTokens: integer(usage["cacheWrite"]), cost: cost, source: source, model: model)
    }

    private static func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    private static func string(_ value: Any?) -> String? { value as? String }
    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }
    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let milliseconds = value as? NSNumber { return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000) }
        guard let string = value as? String else { return nil }
        if let milliseconds = Double(string) { return Date(timeIntervalSince1970: milliseconds / 1_000) }
        return cachedFormatter.date(from: string) ?? cachedPlainFormatter.date(from: string)
    }

    /// ISO8601DateFormatter 创建成本极高（ICU 资源加载），复用同一实例避免每行新建。
    /// 苹果文档：NSDateFormatter 自 macOS 10.9 起线程安全，可直接共享；
    /// nonisolated(unsafe) 声明为不可变只读常量。
    nonisolated(unsafe) private static let cachedFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    /// 兼容无毫秒时间戳的默认选项 formatter
    nonisolated(unsafe) private static let cachedPlainFormatter = ISO8601DateFormatter()
}
