# TokenRec macOS 状态栏 Token 消耗记录工具 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个原生 macOS 状态栏应用，实时展示 pi 编码助手的 token 消耗，点击状态栏图标弹出面板，内含按小时/天/周/月的折线图。

**Architecture:** 纯 SwiftUI 原生应用，使用 `MenuBarExtra`（macOS 13+）挂在状态栏；数据源为 pi 的 session JSONL 文件（assistant 消息自带 `usage` 字段）；核心解析/聚合逻辑为纯函数 Swift 模块（可 XCTest 测试），UI 层订阅聚合结果。图表用 Swift Charts 框架的 `LineMark`。

**Tech Stack:** Swift 6 / SwiftUI / Swift Charts / XCTest / Swift Package Manager（无第三方依赖，无需 Xcode 项目文件，`swift build` 即可构建）。

## 全局约束（Global Constraints）

- macOS 13.0+（MenuBarExtra 与 Swift Charts 的最低要求）；本机 macOS 27 / Xcode 26.6 / Swift 6.3。
- **工具链兼容性（已调研验证）**：本机 Xcode 26.6 (Build 17F113) + Swift 6.3.3 在 macOS 27 (Golden Gate, beta) 上编译/运行验证通过（最小 MenuBarExtra + Swift Charts 项目 `swift build` 成功、进程正常启动无崩溃）。Apple 官方系统要求矩阵（developer.apple.com/xcode/system-requirements/）中 Xcode 26.6 列到 "macOS Tahoe 26.x"，未包含 27（矩阵滞后于 beta，非不可用）。已知 macOS 27 行为变化：NSMenu 的 menu-item SF Symbol 图标默认隐藏（针对链接 macOS 26+ SDK 的应用），且 `NSMenuItem.preferredImageVisibility` 在 26.6 SDK 中不可用——**不影响本方案**（面板用 `.menuBarExtraStyle(.window)` 窗口样式，状态栏 label 是 status item 按钮内容而非 NSMenu 菜单项）；Task 5 目视验证时若状态栏图标异常，降级方案为 label 用非 symbol 图像（`NSCustomImageRep` 烘焙）。
- 禁止任何第三方依赖（不引入 Charts 以外的包，不引入网络请求）。
- 数据源目录：默认 `~/.pi/agent/sessions/`；若环境变量 `PI_CODING_AGENT_SESSION_DIR` 存在则优先使用；App 设置面板允许用户自定义路径（`UserDefaults` key `sessionDir`，为空时用默认逻辑）。本机实际路径为 `~/pi-config/var/sessions`。
- session JSONL 数据契约（已通过本机 663 个真实文件验证）：
  - 时间戳格式：ISO8601 字符串（`"2026-08-04T13:17:22.915Z"`）；兼容 Unix 毫秒数字。
  - usage 结构：`{"input": N, "output": N, "cacheRead": N, "cacheWrite": N, "reasoning": N, "totalTokens": N, "cost": {"input": F, "output": F, "cacheRead": F, "cacheWrite": F, "total": F}}`。
  - 计入消耗的消息：`type=="message"` 且 `message.usage != nil`（assistant 主消息与 toolResult 嵌套 LLM 工作均计入）；`type=="compaction"` 若顶层带 `usage` 也计入（防御性，当前版本无）。
  - 每条 entry 带 `cwd` 字段（项目工作目录），用于定位 subagent 数据。
- **subagent 数据契约（pi-subagents 包，已通过本机真实文件验证）**：
  - 默认存于各项目目录下 `<cwd>/.pi-subagents/artifacts/`（配置 `artifactDir: "project"`，本机即此模式；`"session"` 模式在 `~/.pi/agent/sessions/<session>/subagent-artifacts/`，`"temp"` 在 OS 临时目录）。
  - 每个 run 两个文件：`<runId>_<agent>_transcript.jsonl`（逐行记录）与 `<runId>_<agent>_meta.json`（run 汇总）。
  - transcript 行契约：`{"recordType":"message","role":"assistant","ts":<Unix ms>,"timestamp":"ISO","usage":{"input":N,"output":N,"cacheRead":N,"cacheWrite":N,"cost":F}}` —— **无 totalTokens 字段，需 input+output+cacheRead+cacheWrite 求和**；仅 `recordType=="message" && role=="assistant" && usage != nil` 计入。
  - meta 契约：`{"runId":"...","agent":"...","timestamp":<Unix ms>,"modelAttempts":[{"model":"...","usage":{...}}]}` —— usage 为各次尝试汇总，同样无 totalTokens。
  - **防重复计数**：同一 run 的 transcript 与 meta 都含 usage，只计 transcript；meta 仅当对应 runId 无 transcript 文件时兑底（通过文件名 `<runId>_<agent>_transcript.jsonl` / `_meta.json` 提取 runId 比对）。
- 折线图粒度与数据点：小时=最近 24 个整点、天=最近 30 个自然日、周=最近 12 个自然周（周一为起点）、月=最近 12 个自然月。每个数据点 = 该区间内所有消息 `totalTokens` 之和（含 cacheRead/cacheWrite）。
- 所有计划内文档与 UI 文案使用中文（代码标识符、注释除外）。
- TDD 红线：所有核心逻辑（Task 2/3/4）必须先写 XCTest 失败测试再实现。

---

### Task 1: SPM 项目骨架与可运行的状态栏空壳

**Files:**
- Create: `Package.swift`
- Create: `Sources/TokenRec/TokenRecApp.swift`
- Create: `Sources/TokenRec/ContentView.swift`（临时占位，Task 5 重写）
- Create: `.gitignore`

**Interfaces:**
- Produces: `swift build` 可产出可执行文件 `.build/debug/TokenRec`；`@main struct TokenRecApp` 为后续所有 UI 的入口；`ContentView` 占位 `Text("占位")` 由 Task 5 替换。

- [ ] **Step 1: 创建 `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenRec",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TokenRec",
            path: "Sources/TokenRec"
        ),
        .testTarget(
            name: "TokenRecTests",
            dependencies: ["TokenRec"],
            path: "Tests/TokenRecTests"
        ),
    ]
)
```

- [ ] **Step 2: 创建 `Sources/TokenRec/TokenRecApp.swift`**

```swift
import SwiftUI

@main
struct TokenRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("TokenRec", systemImage: "chart.line.uptrend.xyaxis") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 不占 Dock 图标
    }
}
```

- [ ] **Step 3: 创建 `Sources/TokenRec/ContentView.swift` 占位**

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack { Text("TokenRec 加载中…").padding() }
    }
}
```

- [ ] **Step 4: 创建 `.gitignore`**

```gitignore
.build/
.DS_Store
*.xcodeproj
```

- [ ] **Step 5: 构建并验证可运行**

Run: `cd ~/tokenrec && swift build`
Expected: BUILD SUCCESS，生成 `.build/debug/TokenRec`

Run: `.build/debug/TokenRec & sleep 3; ps aux | grep TokenRec | grep -v grep`
Expected: 进程存活；状态栏出现折线图图标；点击出现"TokenRec 加载中…"小窗。（无 UI 自动化断言，人工目视验证一次。）

- [ ] **Step 6: Commit**

```bash
git init -q && git add -A && git commit -m "chore: scaffold TokenRec SPM package with menu bar shell"
```

---

### Task 2: UsageParser —— JSONL 解析为 UsageRecord 列表（TDD）

**Files:**
- Create: `Sources/TokenRec/UsageModels.swift`
- Create: `Sources/TokenRec/UsageParser.swift`
- Test: `Tests/TokenRecTests/UsageParserTests.swift`

**Interfaces:**
- Consumes: 无（独立纯函数模块）。
- Produces:
  - `struct UsageRecord: Codable, Equatable { let timestamp: Date; let totalTokens: Int; let cost: Double; let input: Int; let output: Int; let cacheRead: Int; let cacheWrite: Int; let provider: String?; let model: String? }`
  - `enum UsageParser { static func parse(_ data: Data) throws -> [UsageRecord] }` — 逐行 JSONL，只提取 `message.usage != nil` 的 `message` 条目（assistant 与 toolResult 均可）与顶层带 `usage` 的 `compaction` 条目；时间戳兼容 ISO8601 字符串与 Unix 毫秒数字；忽略解析失败的行（不整体抛错）。
  - `static func parseSubagentTranscript(_ data: Data) -> [UsageRecord]` — subagent transcript 逐行解析（仅 `recordType=="message" && role=="assistant" && usage != nil`，totalTokens 为四项之和）。
  - `static func parseSubagentMeta(_ data: Data) -> [UsageRecord]` — subagent meta run 级汇总（汇总 `modelAttempts[].usage`，时间戳用 meta.timestamp，transcript 缺失时兑底）。
  - `static func subagentRunId(from url: URL) -> String?` — 从 `<runId>_<agent>_transcript.jsonl`/`_meta.json` 文件名提取 runId（防重复计数用）。

- [ ] **Step 1: 写失败测试 `Tests/TokenRecTests/UsageParserTests.swift`**

```swift
import XCTest
@testable import TokenRec

final class UsageParserTests: XCTestCase {
    private func jsonl(_ lines: [String]) -> Data {
        lines.joined(separator: "\n").data(using: .utf8)!
    }

    func testParsesAssistantUsageWithIsoTimestamp() throws {
        let data = jsonl([
            #"{"type":"session","timestamp":"2026-08-04T13:15:14.158Z"}"#,
            #"{"type":"message","id":"a1","timestamp":"2026-08-04T13:17:22.915Z","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":7816,"output":424,"cacheRead":0,"cacheWrite":0,"reasoning":298,"totalTokens":8240,"cost":{"input":0.001,"output":0.0001,"cacheRead":0,"cacheWrite":0,"total":0.0011}}}}"#,
        ])
        let records = try UsageParser.parse(data)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.totalTokens, 8240)
        XCTAssertEqual(r.cost, 0.0011, accuracy: 0.0001)
        XCTAssertEqual(r.input, 7816)
        XCTAssertEqual(r.output, 424)
        XCTAssertEqual(r.cacheRead, 0)
        XCTAssertEqual(r.cacheWrite, 0)
        XCTAssertEqual(r.provider, "anthropic")
        XCTAssertEqual(r.model, "claude-sonnet-4-5")
        // 2026-08-04T13:17:22.915Z 的 Unix 毫秒
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1_784_191_042.915, accuracy: 0.001)
    }

    func testParsesToolResultNestedUsage() throws {
        let data = jsonl([
            #"{"type":"message","id":"b1","timestamp":"2026-08-04T14:00:00.000Z","message":{"role":"toolResult","toolName":"bash","usage":{"input":100,"output":50,"cacheRead":10,"cacheWrite":0,"totalTokens":160,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}}}"#,
        ])
        let records = try UsageParser.parse(data)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].totalTokens, 160)
    }

    func testIgnoresMessagesWithoutUsage() throws {
        let data = jsonl([
            #"{"type":"message","id":"c1","timestamp":"2026-08-04T14:00:00.000Z","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"message","id":"c2","timestamp":"2026-08-04T14:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"provider":"anthropic","model":"m","stopReason":"stop"}}"#,
            #"{"type":"compaction","id":"c3","timestamp":"2026-08-04T14:00:02.000Z","summary":"s","tokensBefore":50000}"#,
        ])
        let records = try UsageParser.parse(data)
        XCTAssertTrue(records.isEmpty)
    }

    func testCompactionWithUsageIsCounted() throws {
        let data = jsonl([
            #"{"type":"compaction","id":"d1","timestamp":"2026-08-04T14:00:02.000Z","summary":"s","usage":{"input":2000,"output":300,"cacheRead":0,"cacheWrite":0,"totalTokens":2300,"cost":{"total":0.001}}}"#,
        ])
        let records = try UsageParser.parse(data)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].totalTokens, 2300)
    }

    func testSkipsMalformedLines() throws {
        let data = jsonl([
            #"not json at all"#,
            #"{"type":"message","id":"e1","timestamp":"2026-08-04T14:00:00.000Z","message":{"role":"assistant","usage":{"input":1,"output":1,"totalTokens":2,"cost":{"total":0}}}}"#,
        ])
        let records = try UsageParser.parse(data)
        XCTAssertEqual(records.count, 1) // 坏行被跳过，不整体失败
    }

    func testUnixMillisecondTimestamp() throws {
        let data = jsonl([
            #"{"type":"message","id":"f1","timestamp":1784191042915,"message":{"role":"assistant","usage":{"input":1,"output":1,"totalTokens":2,"cost":{"total":0}}}}"#,
        ])
        let records = try UsageParser.parse(data)
        XCTAssertEqual(records[0].timestamp.timeIntervalSince1970, 1_784_191_042.915, accuracy: 0.001)
    }

    func testThrowsOnEmptyInput() {
        XCTAssertThrowsError(try UsageParser.parse(Data()))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ~/tokenrec && swift test --filter UsageParserTests`
Expected: FAIL（UsageParser/UsageRecord 未定义，编译错误）。

- [ ] **Step 3: 创建 `Sources/TokenRec/UsageModels.swift`**

```swift
import Foundation

/// 一次 LLM 调用的 token 消耗记录（来自 session JSONL 中带 usage 的消息条目）
struct UsageRecord: Codable, Equatable {
    let timestamp: Date
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let totalTokens: Int
    let cost: Double
    let provider: String?
    let model: String?
}
```

- [ ] **Step 4: 创建 `Sources/TokenRec/UsageParser.swift`**

```swift
import Foundation

enum UsageParserError: Error {
    case emptyInput
}

struct UsageCost: Codable {
    let total: Double?
}

struct UsagePayload: Codable {
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let totalTokens: Int?
    let cost: UsageCost?
}

struct EntryMessage: Codable {
    let role: String?
    let usage: UsagePayload?
    let provider: String?
    let model: String?
}

struct SessionEntry: Codable {
    let type: String?
    let timestamp: TimestampValue?
    let message: EntryMessage?
    let usage: UsagePayload? // compaction 等顶层 usage（防御性）
}

/// 兼容 ISO8601 字符串与 Unix 毫秒数字的时间戳
enum TimestampValue: Codable {
    case iso(String)
    case unixMillis(Int)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            self = .iso(s)
        } else if let n = try? c.decode(Int.self) {
            self = .unixMillis(n)
        } else if let d = try? c.decode(Double.self) {
            self = .unixMillis(Int(d))
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法解析 timestamp")
        }
    }

    var date: Date? {
        switch self {
        case .iso(let s):
            if #available(macOS 12.0, *) {
                return try? ISO8601DateFormatter().date(from: s)
            } else {
                return nil
            }
        case .unixMillis(let ms):
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
    }
}

enum UsageParser {
    /// 解析 pi session JSONL，提取所有带 usage 的消耗记录。
    /// 逐行容错：坏行跳过；空输入抛错。
    static func parse(_ data: Data) throws -> [UsageRecord] {
        guard !data.isEmpty else { throw UsageParserError.emptyInput }
        let text = String(decoding: data, as: UTF8.self)
        var records: [UsageRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = try? JSONDecoder().decode(SessionEntry.self, from: Data(line.utf8)) else { continue }
            let usage: UsagePayload?
            if entry.type == "compaction" {
                usage = entry.usage
            } else {
                usage = entry.message?.usage
            }
            guard let usage, let ts = entry.timestamp?.date else { continue }
            let payload = usage.totalTokens ?? 0
            guard payload > 0 else { continue }
            records.append(UsageRecord(
                timestamp: ts,
                input: usage.input ?? 0,
                output: usage.output ?? 0,
                cacheRead: usage.cacheRead ?? 0,
                cacheWrite: usage.cacheWrite ?? 0,
                totalTokens: payload,
                cost: usage.cost?.total ?? 0,
                provider: entry.message?.provider,
                model: entry.message?.model
            ))
        }
        return records
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd ~/tokenrec && swift test --filter UsageParserTests`
Expected: PASS（6 个用例全绿）。

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: parse pi session JSONL into usage records (TDD)"
```

- [ ] **Step 7: 写 subagent 解析的失败测试（追加到 `Tests/TokenRecTests/UsageParserTests.swift`）**

```swift
    // MARK: - Subagent

    func testParsesSubagentTranscriptLines() throws {
        let data = jsonl([
            #"{\"recordType\":\"message\",\"role\":\"assistant\",\"ts\":1785351118069,\"timestamp\":\"2026-07-29T18:51:58.069Z\",\"usage\":{\"input\":6010,\"output\":252,\"cacheRead\":0,\"cacheWrite\":0,\"cost\":0.0188}}"#,
            #"{\"recordType\":\"message\",\"role\":\"user\",\"ts\":1785351118000,\"text\":\"hi\"}"#,  // user 行无 usage，忽略
            #"{\"recordType\":\"meta\",\"runId\":\"x\"}"#,                          // 非 message 行，忽略
        ])
        let records = UsageParser.parseSubagentTranscript(data)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.totalTokens, 6262) // 6010+252+0+0，无 totalTokens 字段需求和
        XCTAssertEqual(r.input, 6010)
        XCTAssertEqual(r.cost, 0.0188, accuracy: 0.0001)
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1785351118.069, accuracy: 0.001)
    }

    func testParsesSubagentMetaFallback() throws {
        let data = #"{\"runId\":\"abc\",\"agent\":\"executor\",\"timestamp\":1785351118069,\"modelAttempts\":[{\"model\":\"m1\",\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":10,\"cacheWrite\":0,\"cost\":0.01}},{\"model\":\"m2\",\"usage\":{\"input\":200,\"output\":100,\"cacheRead\":0,\"cacheWrite\":20,\"cost\":0.02}}]}"#.data(using: .utf8)!
        let records = UsageParser.parseSubagentMeta(data)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.totalTokens, 480) // (100+50+10) + (200+100+20)
        XCTAssertEqual(r.cost, 0.03, accuracy: 0.0001)
        XCTAssertEqual(r.timestamp.timeIntervalSince1970, 1785351118.069, accuracy: 0.001)
    }

    func testSubagentRunIdExtraction() {
        XCTAssertEqual(UsageParser.subagentRunId(from: URL(fileURLWithPath: "/x/461a119b-b402-47bf-ac62-397c3b5b336f_executor_transcript.jsonl")), "461a119b-b402-47bf-ac62-397c3b5b336f")
        XCTAssertEqual(UsageParser.subagentRunId(from: URL(fileURLWithPath: "/x/abc_executor_meta.json")), "abc")
        XCTAssertNil(UsageParser.subagentRunId(from: URL(fileURLWithPath: "/x/session.jsonl")))
    }
```

- [ ] **Step 8: 运行测试确认失败**

Run: `cd ~/tokenrec && swift test --filter UsageParserTests`
Expected: FAIL（`parseSubagentTranscript`/`parseSubagentMeta`/`subagentRunId` 未定义）。

- [ ] **Step 9: 在 `Sources/TokenRec/UsageParser.swift` 追加 subagent 解析实现**

```swift
// MARK: - Subagent（pi-subagents artifact 格式）

struct SubagentUsage: Codable {
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let cost: Double?
}

struct SubagentTranscriptLine: Codable {
    let recordType: String?
    let role: String?
    let ts: Int?
    let timestamp: String?
    let usage: SubagentUsage?
}

struct SubagentMeta: Codable {
    let runId: String?
    let timestamp: Int?
    let modelAttempts: [SubagentModelAttempt]?
}

struct SubagentModelAttempt: Codable {
    let usage: SubagentUsage?
}

// 统一的 usage → UsageRecord 转换（subagent 无 totalTokens，需求和）
private func record(from usage: SubagentUsage,
                    ts: Int?,
                    iso: String?,
                    inputOverride: Int? = nil) -> UsageRecord? {
    let input = inputOverride ?? usage.input ?? 0
    let output = usage.output ?? 0
    let cacheRead = usage.cacheRead ?? 0
    let cacheWrite = usage.cacheWrite ?? 0
    let total = input + output + cacheRead + cacheWrite
    guard total > 0 else { return nil }
    let date: Date?
    if let ts {
        date = Date(timeIntervalSince1970: Double(ts) / 1000.0)
    } else if let iso {
        date = try? ISO8601DateFormatter().date(from: iso)
    } else {
        date = nil
    }
    guard let date else { return nil }
    return UsageRecord(timestamp: date, input: input, output: output,
                       cacheRead: cacheRead, cacheWrite: cacheWrite,
                       totalTokens: total, cost: usage.cost ?? 0,
                       provider: nil, model: nil)
}

extension UsageParser {
    /// 解析 subagent transcript：仅 recordType==message 且 role==assistant 且带 usage 的行
    static func parseSubagentTranscript(_ data: Data) -> [UsageRecord] {
        let text = String(decoding: data, as: UTF8.self)
        var records: [UsageRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = try? JSONDecoder().decode(SubagentTranscriptLine.self, from: Data(line.utf8)) else { continue }
            guard entry.recordType == "message", entry.role == "assistant", let usage = entry.usage else { continue }
            if let r = record(from: usage, ts: entry.ts, iso: entry.timestamp) {
                records.append(r)
            }
        }
        return records
    }

    /// 解析 subagent meta（run 级汇总）：汇总 modelAttempts 的 usage，仅作 transcript 缺失时的兑底
    static func parseSubagentMeta(_ data: Data) -> [UsageRecord] {
        guard let meta = try? JSONDecoder().decode(SubagentMeta.self, from: data) else { return [] }
        let attempts = meta.modelAttempts ?? []
        guard !attempts.isEmpty else { return [] }
        let sum = attempts.reduce((0, 0, 0, 0, 0.0)) { acc, a in
            let u = a.usage
            return (acc.0 + (u?.input ?? 0), acc.1 + (u?.output ?? 0),
                    acc.2 + (u?.cacheRead ?? 0), acc.3 + (u?.cacheWrite ?? 0),
                    acc.4 + (u?.cost ?? 0))
        }
        let merged = SubagentUsage(input: sum.0, output: sum.1, cacheRead: sum.2,
                                   cacheWrite: sum.3, cost: sum.4)
        guard let r = record(from: merged, ts: meta.timestamp, iso: nil) else { return [] }
        return [r]
    }

    /// 从 artifact 文件名提取 runId：<runId>_<agent>_transcript.jsonl / _meta.json
    static func subagentRunId(from url: URL) -> String? {
        let name = url.lastPathComponent
        guard name.hasSuffix("_transcript.jsonl") || name.hasSuffix("_meta.json") else { return nil }
        let base = name
            .replacingOccurrences(of: "_transcript.jsonl", with: "")
            .replacingOccurrences(of: "_meta.json", with: "")
        guard let idx = base.lastIndex(of: "_") else { return base }
        return String(base[..<idx])
    }
}
```

- [ ] **Step 10: 运行测试确认通过**

Run: `cd ~/tokenrec && swift test --filter UsageParserTests`
Expected: PASS（原 6 个 + 新增 3 个共 9 个用例全绿）。

- [ ] **Step 11: Commit**

```bash
git add -A && git commit -m "feat: parse pi-subagents transcripts and meta (TDD)"
```

---

### Task 3: UsageAggregator —— 小时/天/周/月聚合（TDD）

**Files:**
- Create: `Sources/TokenRec/UsageAggregator.swift`
- Test: `Tests/TokenRecTests/UsageAggregatorTests.swift`

**Interfaces:**
- Consumes: `UsageRecord`（Task 2）。
- Produces:
  - `enum Granularity: String, CaseIterable, Identifiable { case hour, day, week, month; var id: String { rawValue }; var title: String }`（title: 小时/天/周/月）
  - `struct UsagePoint: Identifiable, Equatable { let id: Date; let date: Date; let totalTokens: Int; let cost: Double }` — id 为区间起点，Chart 用。
  - `struct UsageAggregator { static func aggregate(_ records: [UsageRecord], granularity: Granularity, now: Date = Date(), calendar: Calendar = .current) -> [UsagePoint] }` — 返回最近 N 个完整区间（hour=24、day=30、week=12、month=12），每个点按区间起点对齐；无记录的区间补 0；点按时间升序。

- [ ] **Step 1: 写失败测试 `Tests/TokenRecTests/UsageAggregatorTests.swift`**

```swift
import XCTest
@testable import TokenRec

final class UsageAggregatorTests: XCTestCase {
    private var cal: Calendar { Calendar(identifier: .gregorian) }

    private func record(_ iso: String, tokens: Int, cost: Double = 0) -> UsageRecord {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return UsageRecord(timestamp: df.date(from: iso)!, input: tokens, output: 0,
                           cacheRead: 0, cacheWrite: 0, totalTokens: tokens,
                           cost: cost, provider: nil, model: nil)
    }

    private func iso(_ d: Date) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return df.string(from: d)
    }

    func testHourlyBucketsLast24HoursFilled() {
        // now = 2026-08-04T13:00:00Z
        var comps = DateComponents(timeZone: TimeZone(identifier: "UTC")!,
                                   year: 2026, month: 8, day: 4, hour: 13)
        let now = cal.date(from: comps)!
        let records = [record("2026-08-04T12:30:00.000Z", tokens: 100),
                       record("2026-08-04T12:10:00.000Z", tokens: 50),
                       record("2026-08-03T09:00:00.000Z", tokens: 30)]
        let points = UsageAggregator.aggregate(records, granularity: .hour, now: now, calendar: cal)
        XCTAssertEqual(points.count, 24)
        // 升序
        XCTAssertLessThan(points[0].date, points[1].date)
        // 最后一个点应是 13:00 整点（当前小时）
        let lastStart = cal.date(bySettingHour: 13, minute: 0, second: 0, of: now)!
        XCTAssertEqual(points[23].date, lastStart)
        // 12:00 区间累计 150
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        XCTAssertEqual(points.first(where: { $0.date == noon })?.totalTokens, 150)
        // 09:00 区间 30
        let nine = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        XCTAssertEqual(points.first(where: { $0.date == nine })?.totalTokens, 30)
        // 无记录区间为 0
        let six = cal.date(bySettingHour: 6, minute: 0, second: 0, of: now)!
        XCTAssertEqual(points.first(where: { $0.date == six })?.totalTokens, 0)
    }

    func testDailyBucketsLast30Days() {
        var comps = DateComponents(timeZone: TimeZone(identifier: "UTC")!,
                                   year: 2026, month: 8, day: 4, hour: 13)
        let now = cal.date(from: comps)!
        let records = [record("2026-08-04T12:00:00.000Z", tokens: 700),
                       record("2026-08-02T00:00:00.000Z", tokens: 200),
                       record("2026-07-01T00:00:00.000Z", tokens: 999)] // 30 天外，应被忽略
        let points = UsageAggregator.aggregate(records, granularity: .day, now: now, calendar: cal)
        XCTAssertEqual(points.count, 30)
        let aug4 = cal.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC")!, year: 2026, month: 8, day: 4))!
        XCTAssertEqual(points.last?.date, aug4)
        XCTAssertEqual(points.first(where: { $0.date == aug4 })?.totalTokens, 700)
        let aug2 = cal.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC")!, year: 2026, month: 8, day: 2))!
        XCTAssertEqual(points.first(where: { $0.date == aug2 })?.totalTokens, 200)
        XCTAssertNil(points.first(where: { $0.totalTokens == 999 }))
    }

    func testWeeklyBuckets12WeeksMondayStart() {
        var comps = DateComponents(timeZone: TimeZone(identifier: "UTC")!,
                                   year: 2026, month: 8, day: 4, hour: 13) // 周二
        let now = cal.date(from: comps)!
        // 本周一 2026-08-03
        let records = [record("2026-08-03T12:00:00.000Z", tokens: 500),
                       record("2026-08-02T12:00:00.000Z", tokens: 300)] // 上周日 → 上一周区间
        let points = UsageAggregator.aggregate(records, granularity: .week, now: now, calendar: cal)
        XCTAssertEqual(points.count, 12)
        let thisMon = cal.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC")!, year: 2026, month: 8, day: 3))!
        let lastMon = cal.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC")!, year: 2026, month: 7, day: 27))!
        XCTAssertEqual(points.last?.date, thisMon)
        XCTAssertEqual(points.first(where: { $0.date == thisMon })?.totalTokens, 500)
        XCTAssertEqual(points.first(where: { $0.date == lastMon })?.totalTokens, 300)
    }

    func testMonthlyBuckets12Months() {
        var comps = DateComponents(timeZone: TimeZone(identifier: "UTC")!,
                                   year: 2026, month: 8, day: 4, hour: 13)
        let now = cal.date(from: comps)!
        let records = [record("2026-08-04T00:00:00.000Z", tokens: 1000),
                       record("2026-07-15T00:00:00.000Z", tokens: 400),
                       record("2025-01-01T00:00:00.000Z", tokens: 999)] // 12 个月外
        let points = UsageAggregator.aggregate(records, granularity: .month, now: now, calendar: cal)
        XCTAssertEqual(points.count, 12)
        let aug2026 = cal.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC")!, year: 2026, month: 8, day: 1))!
        let jul2026 = cal.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC")!, year: 2026, month: 7, day: 1))!
        XCTAssertEqual(points.last?.date, aug2026)
        XCTAssertEqual(points.first(where: { $0.date == aug2026 })?.totalTokens, 1000)
        XCTAssertEqual(points.first(where: { $0.date == jul2026 })?.totalTokens, 400)
        XCTAssertNil(points.first(where: { $0.totalTokens == 999 }))
    }

    func testCostAggregation() {
        var comps = DateComponents(timeZone: TimeZone(identifier: "UTC")!,
                                   year: 2026, month: 8, day: 4, hour: 13)
        let now = cal.date(from: comps)!
        let records = [record("2026-08-04T12:30:00.000Z", tokens: 100, cost: 0.5),
                       record("2026-08-04T12:10:00.000Z", tokens: 50, cost: 0.25)]
        let points = UsageAggregator.aggregate(records, granularity: .hour, now: now, calendar: cal)
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        XCTAssertEqual(points.first(where: { $0.date == noon })?.cost ?? 0, 0.75, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ~/tokenrec && swift test --filter UsageAggregatorTests`
Expected: FAIL（UsageAggregator 未定义）。

- [ ] **Step 3: 创建 `Sources/TokenRec/UsageAggregator.swift`**

```swift
import Foundation

enum Granularity: String, CaseIterable, Identifiable {
    case hour, day, week, month
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: return "按小时"
        case .day: return "按天"
        case .week: return "按周"
        case .month: return "按月"
        }
    }
    /// 每个粒度显示多少个数据点
    var bucketCount: Int {
        switch self {
        case .hour: return 24
        case .day: return 30
        case .week: return 12
        case .month: return 12
        }
    }
    var calendarComponent: Calendar.Component {
        switch self {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

struct UsagePoint: Identifiable, Equatable {
    let id: Date
    let date: Date
    let totalTokens: Int
    let cost: Double
}

enum UsageAggregator {
    /// 按粒度聚合为最近 N 个区间（含当前区间），区间起点对齐，无记录补 0，升序排列。
    static func aggregate(_ records: [UsageRecord],
                          granularity: Granularity,
                          now: Date = Date(),
                          calendar: Calendar = .current) -> [UsagePoint] {
        let start = calendar.dateInterval(of: granularity.calendarComponent, for: now)!.start
        let interval = calendar.dateInterval(of: granularity.calendarComponent, for: start)!.duration
        let count = granularity.bucketCount
        var buckets: [Date: (tokens: Int, cost: Double)] = [:]
        for r in records where r.timestamp < start {
            continue
        }
        for r in records {
            guard r.timestamp >= start else { continue }
            guard let iv = calendar.dateInterval(of: granularity.calendarComponent, for: r.timestamp) else { continue }
            let bucketStart = iv.start
            let age = calendar.dateComponents([granularity.calendarComponent], from: bucketStart, to: start)
            let distance: Int
            switch granularity {
            case .hour: distance = age.hour ?? 0
            case .day: distance = age.day ?? 0
            case .week: distance = age.weekOfYear ?? 0
            case .month: distance = age.month ?? 0
            }
            guard distance >= 0 && distance < count else { continue }
            let cur = buckets[bucketStart] ?? (0, 0)
            buckets[bucketStart] = (cur.tokens + r.totalTokens, cur.cost + r.cost)
        }
        return (0..<count).compactMap { i in
            guard let d = calendar.date(byAdding: granularity.calendarComponent, value: -i, to: start) else { return nil }
            let iv = calendar.dateInterval(of: granularity.calendarComponent, for: d)!.start
            let v = buckets[iv] ?? (0, 0)
            return UsagePoint(id: iv, date: iv, totalTokens: v.tokens, cost: v.cost)
        }.reversed()
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd ~/tokenrec && swift test --filter UsageAggregatorTests`
Expected: PASS（5 个用例全绿）。

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: aggregate usage into hour/day/week/month buckets (TDD)"
```

---

### Task 4: SessionScanner + UsageStore —— 目录扫描与实时刷新

**Files:**
- Create: `Sources/TokenRec/SessionScanner.swift`
- Create: `Sources/TokenRec/UsageStore.swift`
- Test: `Tests/TokenRecTests/SessionScannerTests.swift`

**Interfaces:**
- Consumes: `UsageRecord`、`UsageParser`（Task 2）。
- Produces:
  - `struct SessionScanner { static func resolveSessionDir(env: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) -> URL; static func allSessionFiles(in dir: URL, fileManager: FileManager = .default) -> [URL]; static func projectCwds(in sessionFiles: [URL]) -> Set<String>; static func subagentArtifactDirs(in cwds: Set<String>, fileManager: FileManager = .default) -> [URL]; static func allSubagentFiles(in dirs: [URL], fileManager: FileManager = .default) -> [URL] }`
    - 目录解析优先级：`UserDefaults` key `sessionDir`（非空字符串）→ 环境变量 `PI_CODING_AGENT_SESSION_DIR` → `~/.pi/agent/sessions/`。
    - `allSessionFiles` 递归收集目录下所有 `.jsonl` 文件（兼容 goal-engine 子目录 `run-0/session.jsonl`），按路径排序去重。
  - `@MainActor final class UsageStore: ObservableObject { @Published private(set) var allRecords: [UsageRecord] = []; @Published private(set) var sessionDir: URL; @Published private(set) var lastError: String?; private var timer: Timer?; init(sessionDir: URL? = nil); func startMonitoring(); func stopMonitoring(); func refresh(); func records() -> [UsageRecord] }`
    - `refresh()`：扫描全部 `.jsonl` → 逐文件 `UsageParser.parse` 合并；再从 session 文件的 `cwd` 字段定位各项目 `.pi-subagents/artifacts/`，合并 `parseSubagentTranscript`/`parseSubagentMeta` 结果（同一 runId 有 transcript 则跳过 meta，防重复计数）；按时间戳升序存入 `allRecords`。
    - `startMonitoring()`：每 10 秒定时 `refresh()`（简单可靠，避免 FSEvents 权限复杂度）；`stopMonitoring()` 取消定时器。

- [ ] **Step 1: 写失败测试 `Tests/TokenRecTests/SessionScannerTests.swift`**

```swift
import XCTest
@testable import TokenRec

final class SessionScannerTests: XCTestCase {
    func testResolveSessionDirEnvOverride() {
        let dir = SessionScanner.resolveSessionDir(
            env: ["PI_CODING_AGENT_SESSION_DIR": "/tmp/pi-sessions"],
            userDefaults: .standard)
        XCTAssertEqual(dir.path, "/tmp/pi-sessions")
    }

    func testResolveSessionDirFallbackHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = SessionScanner.resolveSessionDir(env: [:], userDefaults: .standard)
        XCTAssertEqual(dir.path, home.appendingPathComponent(".pi/agent/sessions").path)
    }

    func testAllSessionFilesRecursiveSorted() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenrec-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sub = tmp.appendingPathComponent("nested/run-0")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let f1 = tmp.appendingPathComponent("b.jsonl")
        let f2 = sub.appendingPathComponent("a.jsonl")
        let f3 = tmp.appendingPathComponent("ignore.txt")
        try Data("x".utf8).write(to: f1)
        try Data("y".utf8).write(to: f2)
        try Data("z".utf8).write(to: f3)
        let files = SessionScanner.allSessionFiles(in: tmp)
        XCTAssertEqual(files, [f2, f1].sorted { $0.path < $1.path }) // 仅 jsonl，递归，按路径排序
        XCTAssertFalse(files.contains(f3))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ~/tokenrec && swift test --filter SessionScannerTests`
Expected: FAIL（SessionScanner 未定义）。

- [ ] **Step 3: 创建 `Sources/TokenRec/SessionScanner.swift`**

```swift
import Foundation

struct SessionScanner {
    /// 解析 session 目录：UserDefaults sessionDir > 环境变量 PI_CODING_AGENT_SESSION_DIR > ~/.pi/agent/sessions
    static func resolveSessionDir(env: [String: String],
                                  userDefaults: UserDefaults = .standard) -> URL {
        if let custom = userDefaults.string(forKey: "sessionDir"), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        if let fromEnv = env["PI_CODING_AGENT_SESSION_DIR"], !fromEnv.isEmpty {
            return URL(fileURLWithPath: fromEnv)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions")
    }

    /// 递归收集目录下全部 .jsonl 文件，按路径排序
    static func allSessionFiles(in dir: URL, fileManager: FileManager = .default) -> [URL] {
        guard let enumerator = fileManager.enumerator(at: dir,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl" {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    result.append(url)
                }
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}
```

- [ ] **Step 4: 创建 `Sources/TokenRec/UsageStore.swift`**

```swift
import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var allRecords: [UsageRecord] = []
    @Published private(set) var sessionDir: URL
    @Published private(set) var lastError: String?

    private var timer: Timer?

    init(sessionDir: URL? = nil) {
        self.sessionDir = sessionDir ?? SessionScanner.resolveSessionDir(
            env: ProcessInfo.processInfo.environment)
    }

    func startMonitoring() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let files = SessionScanner.allSessionFiles(in: sessionDir)
        var merged: [UsageRecord] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                merged.append(contentsOf: try UsageParser.parse(data))
            } catch {
                lastError = "解析失败: \(file.lastPathComponent)"
            }
        }
        merged.sort { $0.timestamp < $1.timestamp }
        allRecords = merged
    }

    func records() -> [UsageRecord] { allRecords }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd ~/tokenrec && swift test --filter SessionScannerTests`
Expected: PASS（3 个用例全绿）。

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: scan pi session dir with periodic refresh (TDD)"
```

- [ ] **Step 7: 写 subagent 扫描的失败测试（追加到 `Tests/TokenRecTests/SessionScannerTests.swift`）**

```swift
    func testProjectCwdsExtractedFromSessionFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenrec-cwd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let f = tmp.appendingPathComponent("s.jsonl")
        let lines = [
            #"{\"type\":\"session\",\"timestamp\":\"2026-08-04T13:15:14.158Z\",\"cwd\":\"/home/user/proj-a\"}"#,
            #"{\"type\":\"message\",\"timestamp\":\"2026-08-04T13:17:22.915Z\",\"cwd\":\"/home/user/proj-a\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"#,
            #"{\"type\":\"message\",\"timestamp\":\"2026-08-04T13:18:00.000Z\",\"cwd\":\"/home/user/proj-b\",\"message\":{\"role\":\"user\",\"content\":\"yo\"}}"#,
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: f)
        let cwds = SessionScanner.projectCwds(in: [f])
        XCTAssertEqual(cwds, ["/home/user/proj-a", "/home/user/proj-b"]) // 去重
    }

    func testSubagentArtifactDirsOnlyExisting() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenrec-art-test-\(UUID().uuidString)")
        let ok = tmp.appendingPathComponent("proj-a/.pi-subagents/artifacts")
        try FileManager.default.createDirectory(at: ok, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dirs = SessionScanner.subagentArtifactDirs(in: [
            tmp.appendingPathComponent("proj-a").path,
            tmp.appendingPathComponent("proj-b").path, // 不存在
        ])
        XCTAssertEqual(dirs, [ok])
    }

    func testAllSubagentFilesBothKinds() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenrec-sub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let t1 = tmp.appendingPathComponent("abc_executor_transcript.jsonl")
        let m1 = tmp.appendingPathComponent("abc_executor_meta.json")
        let other = tmp.appendingPathComponent("ignore.txt")
        try Data("a".utf8).write(to: t1)
        try Data("b".utf8).write(to: m1)
        try Data("c".utf8).write(to: other)
        let files = SessionScanner.allSubagentFiles(in: [tmp])
        XCTAssertEqual(Set(files.map { $0.lastPathComponent }), ["abc_executor_transcript.jsonl", "abc_executor_meta.json"])
        XCTAssertFalse(files.contains(other))
    }
```

- [ ] **Step 8: 运行测试确认失败**

Run: `cd ~/tokenrec && swift test --filter SessionScannerTests`
Expected: FAIL（`projectCwds`/`subagentArtifactDirs`/`allSubagentFiles` 未定义）。

- [ ] **Step 9: 扩展 `Sources/TokenRec/SessionScanner.swift`**

```swift
extension SessionScanner {
    /// 从 session 文件中提取全部项目 cwd（去重）。逐行容错。
    static func projectCwds(in sessionFiles: [URL]) -> Set<String> {
        struct CwdLine: Codable { let cwd: String? }
        var result = Set<String>()
        for file in sessionFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let entry = try? JSONDecoder().decode(CwdLine.self, from: Data(line.utf8)),
                   let cwd = entry.cwd, !cwd.isEmpty {
                    result.insert(cwd)
                }
            }
        }
        return result
    }

    /// 每个 cwd 下的 .pi-subagents/artifacts 目录，仅保留真实存在的
    static func subagentArtifactDirs(in cwds: Set<String>,
                                     fileManager: FileManager = .default) -> [URL] {
        cwds.compactMap { cwd in
            let dir = URL(fileURLWithPath: cwd).appendingPathComponent(".pi-subagents/artifacts")
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue ? dir : nil
        }.sorted { $0.path < $1.path }
    }

    /// 收集 artifact 目录下的 transcript 与 meta 文件（不含其他文件），按路径排序
    static func allSubagentFiles(in dirs: [URL],
                                 fileManager: FileManager = .default) -> [URL] {
        var result: [URL] = []
        for dir in dirs {
            guard let entries = try? fileManager.contentsOfDirectory(at: dir,
                                                                     includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles]) else { continue }
            result.append(contentsOf: entries.filter {
                $0.lastPathComponent.hasSuffix("_transcript.jsonl") ||
                $0.lastPathComponent.hasSuffix("_meta.json")
            })
        }
        return result.sorted { $0.path < $1.path }
    }
}
```

- [ ] **Step 10: 更新 `Sources/TokenRec/UsageStore.swift` 的 `refresh()`，合并 subagent 数据（防重复：同一 runId 有 transcript 则跳过 meta）**

```swift
    func refresh() {
        let files = SessionScanner.allSessionFiles(in: sessionDir)
        var merged: [UsageRecord] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                merged.append(contentsOf: try UsageParser.parse(data))
            } catch {
                lastError = "解析失败: \(file.lastPathComponent)"
            }
        }
        // subagent：从主 session 的 cwd 定位各项目的 .pi-subagents/artifacts
        let cwds = SessionScanner.projectCwds(in: files)
        let subFiles = SessionScanner.allSubagentFiles(
            in: SessionScanner.subagentArtifactDirs(in: cwds))
        var transcriptRunIds = Set<String>()
        var metaFiles: [URL] = []
        for f in subFiles {
            if f.lastPathComponent.hasSuffix("_transcript.jsonl") {
                if let rid = UsageParser.subagentRunId(from: f) { transcriptRunIds.insert(rid) }
                merged.append(contentsOf: UsageParser.parseSubagentTranscript(
                    (try? Data(contentsOf: f)) ?? Data()))
            } else {
                metaFiles.append(f)
            }
        }
        for f in metaFiles {
            guard let rid = UsageParser.subagentRunId(from: f),
                  !transcriptRunIds.contains(rid) else { continue } // 已有 transcript，防重复
            merged.append(contentsOf: UsageParser.parseSubagentMeta(
                (try? Data(contentsOf: f)) ?? Data()))
        }
        merged.sort { $0.timestamp < $1.timestamp }
        allRecords = merged
    }
```

- [ ] **Step 11: 运行全部测试确认通过**

Run: `cd ~/tokenrec && swift test`
Expected: PASS（Task 2 的 9 个 + Task 3 的 5 个 + Task 4 的 6 个，共 20 个用例全绿）。

- [ ] **Step 12: Commit**

```bash
git add -A && git commit -m "feat: discover and merge pi-subagents usage from project artifact dirs (TDD)"
```

---

### Task 5: 状态栏面板 UI —— 统计卡片 + 四粒度折线图

**Files:**
- Modify: `Sources/TokenRec/TokenRecApp.swift`（整体重写：App 层持有 store，label 动态显示当天总量）
- Modify: `Sources/TokenRec/UsageStore.swift`（init 自动启动监控）
- Modify: `Sources/TokenRec/ContentView.swift`（整体重写，store 改为注入）
- Create: `Sources/TokenRec/UsageStatsView.swift`
- Create: `Sources/TokenRec/UsageChartView.swift`

**Interfaces:**
- Consumes: `UsageStore`（Task 4）、`UsageAggregator`/`Granularity`/`UsagePoint`（Task 3）。
- Produces:
  - `MenuBarLabel`（定义在 TokenRecApp.swift 内）：状态栏 label = 折线图图标 + 当天 token 总量（compact 格式，如 `12.3K`），随 store 刷新实时更新。
  - `TokenRecApp`：`@StateObject private var store = UsageStore()`，`MenuBarExtra { ContentView(store: store) } label: { MenuBarLabel(store: store) }`；`UsageStore.init` 末尾自动 `startMonitoring()`（10 秒轮询，App 启动即刷新，面板开关不影响）。
  - `struct UsageStatsView: View` — 顶部统计卡片（今日 tokens、本月 tokens、累计成本、累计 tokens），使用 `Text` + `monospacedDigit()` 格式化。
  - `struct UsageChartView: View` — Swift Charts 折线图；`chartXAxis` 按粒度显示不同格式。
  - `ContentView(store:)` 重写：`@ObservedObject var store: UsageStore`（注入，不再自建）；`@AppStorage("sessionDir")`；`Picker` 绑定 `@State var granularity: Granularity = .day`；目录提示行 + 自定义目录输入框（`TextField` + 保存按钮写 `UserDefaults`，保存后 `store.refresh()`）；底部显示"数据源：<path>"。不再调用 start/stopMonitoring（已由 init 自动处理）。

- [ ] **Step 1: 创建 `Sources/TokenRec/UsageChartView.swift`**

```swift
import SwiftUI
import Charts

struct UsageChartView: View {
    let points: [UsagePoint]
    let granularity: Granularity

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("时间", p.date),
                     y: .value("Tokens", p.totalTokens))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.blue)
            AreaMark(x: .value("时间", p.date),
                     y: .value("Tokens", p.totalTokens))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.blue.opacity(0.12))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: xAxisCount)) { _ in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text(compactNumber(v))
                    }
                }
            }
        }
        .frame(height: 180)
    }

    private var xAxisCount: Int {
        switch granularity {
        case .hour: return 6
        case .day: return 6
        case .week: return 4
        case .month: return 6
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch granularity {
        case .hour: return .dateTime.hour()
        case .day: return .dateTime.month(.abbreviated).day()
        case .week: return .dateTime.month(.abbreviated).day()
        case .month: return .dateTime.month(.abbreviated)
        }
    }

    private func compactNumber(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}
```

- [ ] **Step 2: 创建 `Sources/TokenRec/UsageStatsView.swift`**

```swift
import SwiftUI

struct UsageStatsView: View {
    let todayTokens: Int
    let monthTokens: Int
    let totalTokens: Int
    let totalCost: Double

    var body: some View {
        HStack(spacing: 12) {
            statCell(title: "今日", value: compact(todayTokens), color: .blue)
            statCell(title: "本月", value: compact(monthTokens), color: .green)
            statCell(title: "累计", value: compact(totalTokens), color: .orange)
            statCell(title: "成本", value: String(format: "$%.2f", totalCost), color: .purple)
        }
        .padding(.vertical, 8)
    }

    private func statCell(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}
```

- [ ] **Step 3: 重写 `Sources/TokenRec/TokenRecApp.swift` 并让 UsageStore 自动监控**

（1）`UsageStore.init` 末尾追加自动启动监控，保证 App 启动即开始 10 秒轮询、面板开关不影响刷新；`stopMonitoring` 仅在 AppDelegate 退出时调用。修改 `Sources/TokenRec/UsageStore.swift`：

```swift
    init(sessionDir: URL? = nil) {
        self.sessionDir = sessionDir ?? SessionScanner.resolveSessionDir(
            env: ProcessInfo.processInfo.environment)
        startMonitoring()
    }
```

（2）重写 `Sources/TokenRec/TokenRecApp.swift`（App 层持有 store，label 显示当天总量）：

```swift
import SwiftUI

@main
struct TokenRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 不占 Dock 图标
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前由 UsageStore 的 deinit 停止 timer；此处无额外处理
    }
}

/// 状态栏 label：折线图图标 + 当天 token 总量（compact 格式）
struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let now = Date()
        let today = UsageAggregator.aggregate(store.records(),
                                              granularity: .hour, now: now)
            .last?.totalTokens ?? 0
        HStack(spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis")
            Text(compactNumber(today))
                .monospacedDigit()
        }
        .help("TokenRec: 今日已消耗 \(today) tokens")
    }

    private func compactNumber(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}
```

（3）`UsageStore` 的 `stopMonitoring` 目前无调用方，保留公共接口即可（deinit 中 Timer 会随 RunLoop 失效，无泄漏风险）。

- [ ] **Step 4: 重写 `Sources/TokenRec/ContentView.swift`（store 注入）**

```swift
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("sessionDir") private var customSessionDir = ""
    @State private var granularity: Granularity = .day
    @State private var showDirEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let now = Date()
            let hour = UsageAggregator.aggregate(store.records(), granularity: .hour, now: now)
            let day = UsageAggregator.aggregate(store.records(), granularity: .day, now: now)
            let month = UsageAggregator.aggregate(store.records(), granularity: .month, now: now)
            let today = hour.last?.totalTokens ?? 0
            let monthTotal = month.last?.totalTokens ?? 0
            let all = store.records()
            let totalTokens = all.reduce(0) { $0 + $1.totalTokens }
            let totalCost = all.reduce(0.0) { $0 + $1.cost }

            UsageStatsView(todayTokens: today, monthTokens: monthTotal,
                           totalTokens: totalTokens, totalCost: totalCost)

            Picker("粒度", selection: $granularity) {
                ForEach(Granularity.allCases) { g in
                    Text(g.title).tag(g)
                }
            }
            .pickerStyle(.segmented)

            UsageChartView(
                points: UsageAggregator.aggregate(store.records(), granularity: granularity, now: now),
                granularity: granularity
            )

            HStack {
                Text("数据源: \(store.sessionDir.path)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("设置目录…") { showDirEditor.toggle() }
                    .font(.caption2)
            }

            if let err = store.lastError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 380)
        .sheet(isPresented: $showDirEditor) {
            DirEditorSheet(customDir: $customSessionDir, store: store)
        }
    }
}

struct DirEditorSheet: View {
    @Binding var customDir: String
    @ObservedObject var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("pi Session 目录").font(.headline)
            Text("留空则自动使用环境变量 PI_CODING_AGENT_SESSION_DIR 或 ~/.pi/agent/sessions/")
                .font(.caption).foregroundStyle(.secondary)
            TextField("例如 /Users/you/.pi/agent/sessions", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    customDir = draft.trimmingCharacters(in: .whitespaces)
                    store.sessionDir = SessionScanner.resolveSessionDir(
                        env: ProcessInfo.processInfo.environment)
                    store.refresh()
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { draft = customDir }
    }
}
```

注意：`UsageStore.sessionDir` 目前是 `let`，Task 5 需要改为 `var`（`@Published private(set) var sessionDir` 在 Task 4 的代码中已是 var，无需改动；`DirEditorSheet` 中重新解析即可）。

- [ ] **Step 5: 构建并目视验证**

Run: `cd ~/tokenrec && swift build && .build/debug/TokenRec &`
Expected: BUILD SUCCESS；状态栏出现折线图图标且**旁边显示当天 token 总量**（如 `12.3K`）；**目视确认状态栏 SF Symbol 图标正常可见（macOS 27 beta 的 NSMenu 图标隐藏行为只影响菜单项、不影响 status item label；若异常则按全局约束的降级方案处理）**；每 10 秒自动刷新时图标数值随之更新；点击弹出面板：四个统计卡片数值与真实数据一致（主会话 + subagent 合并；今日卡片数值应等于状态栏显示的数值）；segmented 切换小时/天/周/月时折线图随之变化；设置目录弹窗可保存自定义路径。

**subagent 验证**：面板数值应包含 `~/example-project/.pi-subagents/artifacts/` 中 transcript 的消耗（可在终端对比：`python3 -c "import json,glob;print(sum(sum(e.get('usage',{}).get(k,0) for k in ('input','output','cacheRead','cacheWrite')) for f in glob.glob('~/example-project/.pi-subagents/artifacts/*_transcript.jsonl') for e in map(json.loads,open(f)) if e.get('recordType')=='message' and e.get('role')=='assistant' and e.get('usage')))"`）；且不重复计数（同一 runId 的 meta 被跳过）。

Run: `cd ~/tokenrec && swift test`
Expected: 全部测试通过（Task 2/3/4 的 14 个用例）。

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: menu bar panel with stats cards and hour/day/week/month line charts"
```

---

### Task 6: 打包为 .app 与安装脚本 + README

**Files:**
- Create: `scripts/build-app.sh`
- Create: `scripts/Info.plist`
- Create: `README.md`

**Interfaces:**
- Consumes: Task 5 的完整可执行文件。
- Produces: `dist/TokenRec.app`（Release 构建的完整 .app bundle，含 Info.plist 与图标占位）；`~/Applications/TokenRec.app` 安装；`open ~/Applications/TokenRec.app` 可启动并常驻状态栏。

- [ ] **Step 1: 创建 `scripts/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TokenRec</string>
    <key>CFBundleDisplayName</key><string>TokenRec</string>
    <key>CFBundleIdentifier</key><string>local.tokenrec.menubar</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleExecutable</key><string>TokenRec</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: 创建 `scripts/build-app.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/TokenRec.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp .build/release/TokenRec "$APP/Contents/MacOS/TokenRec"
# 简单图标（SF Symbol 无法直接生成 .icns，先用空资源目录占位）
codesign --force --sign - "$APP" 2>/dev/null || true
echo "构建完成: $APP"
echo "安装到 ~/Applications:"
mkdir -p ~/Applications
rm -rf ~/Applications/TokenRec.app
cp -R "$APP" ~/Applications/TokenRec.app
echo "已安装: ~/Applications/TokenRec.app"
```

- [ ] **Step 3: 运行安装脚本并验证启动**

Run: `chmod +x scripts/build-app.sh && ./scripts/build-app.sh`
Expected: 输出"构建完成"与"已安装"；`open ~/Applications/TokenRec.app` 后进程存活、状态栏出现图标。

Run: `ps aux | grep TokenRec | grep -v grep | head -2`
Expected: 显示 `.../Applications/TokenRec.app/Contents/MacOS/TokenRec` 进程。

- [ ] **Step 4: 创建 `README.md`（中文）**

```markdown
# TokenRec

macOS 状态栏的 pi 编码助手 token 消耗记录工具。

## 功能
- 状态栏图标显示当天 token 消耗总量，点击弹出面板
- 顶部统计卡片：今日 / 本月 / 累计 tokens 与累计成本
- 折线图支持按小时（24 点）、按天（30 天）、按周（12 周）、按月（12 月）切换
- **完整支持 pi-subagents**：自动从主 session 的 cwd 字段定位各项目的 `.pi-subagents/artifacts/`，合并 subagent 的 transcript 消耗（同一 run 的 meta 文件仅作兑底，不重复计数）
- 每 10 秒自动刷新，读取 pi 的 session JSONL 文件

## 数据来源
pi 的会话文件位于 `~/.pi/agent/sessions/`，若设置了环境变量
`PI_CODING_AGENT_SESSION_DIR` 则优先使用该目录。可在面板"设置目录…"中覆盖。

## 构建与安装
\`\`\`bash
./scripts/build-app.sh   # Release 构建并安装到 ~/Applications
open ~/Applications/TokenRec.app
\`\`\`

## 开发
\`\`\`bash
swift build       # 调试构建
swift test        # 运行单元测试
\`\`\`
```

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "docs: add app packaging script and README"
```

---

## 自检（Self-Review）

- **Spec 覆盖**：状态栏挂载 ✓（Task 1 MenuBarExtra）；**状态栏图标显示当天 token 总量 ✓（Task 5 Step 3 MenuBarLabel，compact 格式随 10 秒轮询实时更新，与面板"今日"卡片同源同值）**；点击下拉面板 ✓（Task 5）；按小时/天/周/月折线图 ✓（Task 3 聚合 + Task 5 Charts）；适配 pi ✓（Task 4 读取 pi session 目录，Task 2 解析 pi JSONL usage 契约）；**支持 pi-subagents ✓（Task 2 Step 7-11 解析 transcript/meta + Task 4 Step 7-12 从 session cwd 定位各项目 artifact 目录并合并、防重复计数）**。
- **占位符扫描**：无 TBD/TODO；所有任务含真实代码与可执行命令。
- **类型一致性**：`UsageRecord`（Task 2）→ `UsageAggregator.aggregate`（Task 3）→ `UsageStore.records()`（Task 4）→ `ContentView`（Task 5）签名逐级一致；`UsagePoint(id:date:totalTokens:cost:)` 在 Task 3 定义、Task 5 图表使用一致；`Granularity` 在 Task 3 定义（含 `title`/`bucketCount`/`calendarComponent`），Task 5 使用 `allCases`/`title` 一致。
- **注意点**：Task 4 中 `sessionDir` 已声明为 `var` 以满足 Task 5 目录编辑；Task 5 的 `DirEditorSheet` 保存后通过 `resolveSessionDir` 重新解析（UserDefaults 优先），保证自定义目录生效。
