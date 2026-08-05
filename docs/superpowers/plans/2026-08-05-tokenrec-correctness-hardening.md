# TokenRec 数据正确性与运行稳态修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 TokenRec 的跨源重复计数、真实成本、目录发现、错误可见性与不可移植测试，并为已完成的单实例/性能修复建立可重复门禁。

**Architecture:** 将“文件发现与源优先级”从 `UsageStore` 抽成可测试的 `UsageRepository`，以 child session > transcript > meta 的 runId 级优先级去重；Parser 只负责格式与 cost，Aggregator 负责统计摘要，MainActor Store 只发布 Repository 结果。所有真实数据测试改用脱敏 fixture，最终在 clean archive 和安装版进程中验收。

**Tech Stack:** Swift 6.0、Swift Package Manager、XCTest、SwiftUI/Charts、Foundation、macOS 13+

## Global Constraints

- 任何逻辑修复先在 `docs/bugs/` 写六要素根因文档，再写 tests-only RED，再做最小 GREEN。
- 不引入第三方依赖，不改写 Git 历史，不提交 `dist/`、`.build/` 或本机 session 数据。
- 默认数据源优先级：UserDefaults `sessionDir` > `PI_CODING_AGENT_SESSION_DIR` > 已存在且含 JSONL 的 `~/pi-config/var/sessions` > `~/.pi/agent/sessions`。
- 同一 subagent run 的权威顺序：Pi child session > artifact transcript > artifact meta；不得按 token tuple 猜测去重，也不得像 `96d9410` 一样完全删除 artifact-only fallback。
- `UsageRecord.cost` 使用 provider/runtime 报告的真实 total；无 cost 时为 0，不做价格估算。
- 性能门禁必须验证“解析调用次数/主线程发布边界”，不得只采瞬时 `%CPU`。
- 验收启动的 TokenRec 进程必须记录 PID 并在 trap 中结束，不得使用宽泛 `pkill`。

## 文件职责

| 文件 | 职责 |
|---|---|
| `Sources/TokenRec/UsageModels.swift` | token/cost 数据模型与 source metadata |
| `Sources/TokenRec/UsageParser.swift` | session/transcript/meta 格式解析，不做跨文件去重 |
| `Sources/TokenRec/SessionScanner.swift` | session descriptor、runId/cwd 提取、默认目录候选 |
| `Sources/TokenRec/UsageRepository.swift` | 文件缓存、权威源选择、错误收集、并发解析 |
| `Sources/TokenRec/UsageAggregator.swift` | 今日/本月/累计/cost 与四粒度 points 的纯函数摘要 |
| `Sources/TokenRec/UsageStore.swift` | MainActor 发布 Repository snapshot 与 timer 生命周期 |
| `Tests/TokenRecTests/Fixtures/**` | 脱敏、可移植的 session/transcript/meta fixture |
| `scripts/verify-installed-app.sh` | 单实例、进程 ownership、稳态运行的可重复验收 |

## DAG

```text
T1 Parser + cost fixtures ─────┐
                               ├──> T4 Repository source selection ──> T5 Store + UI ──> T6 Runtime/package gate ──> T7 Final review
T2 Scanner + directory resolver┘
T3 Pure usage summary ────────────────────────────────────────┘
```

依赖理由：

- T4 依赖 T1 的 cost/parser contract 和 T2 的 `SessionDescriptor`，否则无法定义 runId 级源优先级。
- T5 依赖 T3 的 `UsageSummary` 和 T4 的 `UsageLoadResult`，只负责发布稳定接口。
- T6 依赖 T4/T5 的可观测解析计数和 UI 发布结果，才能做非瞬时性能门禁。
- T7 只依赖最终业务切片，不阻塞前面可并行的纯函数任务。

## 并行调度组（Wave）

- **Wave 1:** T1、T2、T3（可并行，写入不重叠）
- **Wave 2:** T4
- **Wave 3:** T5
- **Wave 4:** T6
- **Wave 5:** T7

Wave 不是派发屏障；前驱完成即可派发。

---

### Task 1: Parser 真实 cost 与脱敏 fixture

**Deps:** none

**WritePaths:**
- `docs/bugs/bug-tokenrec-cost-and-parser-fixtures.md`
- `Sources/TokenRec/UsageModels.swift`
- `Sources/TokenRec/UsageParser.swift`
- `Tests/TokenRecTests/UsageParserTests.swift`
- `Tests/TokenRecTests/Fixtures/parser/**`

**Interfaces:**
- Produces: `UsageRecord.cost: Double`
- Produces: `UsageParser.parseSession/parseSubagentTranscript/parseSubagentMeta` 保持现有签名
- Cost contract: number 或 `{ "total": number }` 均解析为 `UsageRecord.cost`

- [ ] **Step 1: 记录根因**

创建六要素文档，明确当前 `UsageRecord` 丢弃 runtime cost、UI 曾伪造 `$0.00`，以及绝对路径测试无法在 clean clone 复现。

- [ ] **Step 2: 写 RED fixture 与测试**

加入脱敏文件：

```json
{"type":"message","timestamp":"2026-08-05T01:00:00Z","message":{"usage":{"input":10,"output":2,"cost":{"total":0.0125}}}}
```

```json
{"version":1,"recordType":"message","runId":"run-1","role":"assistant","timestamp":"2026-08-05T01:00:00Z","usage":{"input":10,"output":2,"cost":0.0125}}
```

测试断言：

```swift
func testParsesReportedCostFromSessionAndTranscriptFixtures() throws {
    XCTAssertEqual(try fixtureRecords("session-cost.jsonl").single.cost, 0.0125, accuracy: 0.000_001)
    XCTAssertEqual(try transcriptFixtureRecords("transcript-cost.jsonl").single.cost, 0.0125, accuracy: 0.000_001)
}
```

同时删除 `testRealFilesProduceRecords` 的 `/Users/mhbzhy/...` 依赖。

- [ ] **Step 3: 验证 RED**

Run: `swift test --filter UsageParserTests`

Expected: FAIL，`UsageRecord` 没有 `cost` 或解析结果为 0。

- [ ] **Step 4: 最小 GREEN**

为 `UsageRecord` 增加默认值：

```swift
let cost: Double
// init(..., cost: Double = 0, ...)
```

Parser 的 `record` 只读取报告值：

```swift
let cost = double(usage["cost"]) ?? double(dictionary(usage["cost"])?["total"]) ?? 0
```

- [ ] **Step 5: 验证并提交**

Run: `swift test --filter UsageParserTests && swift test`

```bash
git add docs/bugs/bug-tokenrec-cost-and-parser-fixtures.md Sources/TokenRec/UsageModels.swift Sources/TokenRec/UsageParser.swift Tests/TokenRecTests/UsageParserTests.swift Tests/TokenRecTests/Fixtures/parser
git commit -m "fix(parser): 保留真实用量成本并移除本机测试依赖"
```

---

### Task 2: SessionDescriptor 与默认目录发现

**Deps:** none

**WritePaths:**
- `docs/bugs/bug-tokenrec-session-directory-and-run-identity.md`
- `Sources/TokenRec/SessionScanner.swift`
- `Tests/TokenRecTests/SessionScannerTests.swift`
- `Tests/TokenRecTests/Fixtures/scanner/**`

**Interfaces:**
- Produces:

```swift
struct SessionDescriptor: Equatable, Sendable {
    let url: URL
    let sessionId: String
    let cwd: String
    let subagentRunId: String?
}
```

- Produces: `SessionScanner.sessionDescriptors(in:) -> [SessionDescriptor]`
- Produces: `SessionScanner.resolveSessionDir() -> URL`

- [ ] **Step 1: 记录根因**

文档说明默认 `~/.pi/agent/sessions` 在当前安装为空，真实目录为 `~/pi-config/var/sessions`；child session 的 `session_info.name=subagent-<agent>-<uuid>-<index>` 是 runId 的稳定来源。

- [ ] **Step 2: 写 RED**

fixture 前 5 行包含 `session` 和 `session_info`：

```json
{"type":"session","id":"session-1","cwd":"/project"}
{"type":"session_info","name":"subagent-executor-461a119b-b402-47bf-ac62-397c3b5b336f-1"}
```

测试断言 `subagentRunId` 为 UUID；UserDefaults/env 的空白字符串视为未配置；无有效显式配置时选择存在且含 JSONL 的 `~/pi-config/var/sessions`，不存在时才回退默认目录。

- [ ] **Step 3: 验证 RED**

Run: `swift test --filter SessionScannerTests`

Expected: FAIL，缺少 `SessionDescriptor/sessionDescriptors`，fallback 仍固定到 `.pi/agent/sessions`。

- [ ] **Step 4: 最小 GREEN**

只读取每个文件前 64KB/20 行，解析 `session.id/cwd` 与 `session_info.name`。runId 正则必须只接受 UUID：

```swift
/^subagent-(?:executor|spark|delegate)-([0-9a-f-]{36})-[0-9]+$/
```

目录候选必须通过“目录存在且递归至少一个 `.jsonl`”验证。

- [ ] **Step 5: 验证并提交**

Run: `swift test --filter SessionScannerTests && swift test`

```bash
git add docs/bugs/bug-tokenrec-session-directory-and-run-identity.md Sources/TokenRec/SessionScanner.swift Tests/TokenRecTests/SessionScannerTests.swift Tests/TokenRecTests/Fixtures/scanner
git commit -m "fix(scanner): 发现实际会话目录并识别子代理运行"
```

---

### Task 3: 纯函数 UsageSummary

**Deps:** none

**WritePaths:**
- `Sources/TokenRec/UsageAggregator.swift`
- `Tests/TokenRecTests/UsageAggregatorTests.swift`

**Interfaces:**
- Produces:

```swift
struct UsageSummary: Equatable, Sendable {
    let todayTokens: Int
    let monthTokens: Int
    let totalTokens: Int
    let totalCost: Double
    let points: [Granularity: [UsagePoint]]
}

static func summarize(_ records: [UsageRecord], now: Date = Date(), calendar: Calendar = .current) -> UsageSummary
```

- [ ] **Step 1: 写 RED**

构造同一天两个小时和上月一条记录，断言 `todayTokens` 是两小时之和、`monthTokens` 只含本月、`totalCost` 精确求和。

```swift
XCTAssertEqual(summary.todayTokens, 300)
XCTAssertEqual(summary.monthTokens, 300)
XCTAssertEqual(summary.totalTokens, 350)
XCTAssertEqual(summary.totalCost, 0.35, accuracy: 0.000_001)
```

- [ ] **Step 2: 验证 RED**

Run: `swift test --filter UsageAggregatorTests`

Expected: FAIL，`UsageSummary/summarize` 不存在。

- [ ] **Step 3: 最小 GREEN**

今日/本月边界使用 `calendar.dateInterval(of: .day/.month, for: now)`；四粒度 points 复用现有 `aggregate`，不在 SwiftUI body 重算。

- [ ] **Step 4: 验证并提交**

Run: `swift test --filter UsageAggregatorTests && swift test`

```bash
git add Sources/TokenRec/UsageAggregator.swift Tests/TokenRecTests/UsageAggregatorTests.swift
git commit -m "feat(stats): 统一计算今日本月累计与真实成本"
```

---

### Task 4: UsageRepository 跨源去重、缓存与错误

**Deps:** Task 1, Task 2

**WritePaths:**
- `docs/bugs/bug-tokenrec-subagent-usage-double-count.md`
- `Sources/TokenRec/UsageRepository.swift`
- `Tests/TokenRecTests/UsageRepositoryTests.swift`
- `Tests/TokenRecTests/Fixtures/repository/**`

**Interfaces:**
- Consumes: `SessionDescriptor`、Parser cost contract
- Produces:

```swift
struct UsageLoadError: Equatable, Sendable { let path: String; let message: String }
struct UsageLoadResult: Equatable, Sendable { let records: [UsageRecord]; let errors: [UsageLoadError] }
actor UsageRepository {
    func load(sessionDir: URL) async -> UsageLoadResult
}
```

- [ ] **Step 1: 记录根因**

写入真实复现：child session 与 `461a..._executor_transcript.jsonl` 各 12 条、各 301,379 tokens，旧实现相加为双倍；`96d9410` 又完全移除 transcript/meta，导致 artifact-only 历史 run 被漏计。两者都不符合“child session > transcript > meta”的权威顺序。

- [ ] **Step 2: 写 RED fixture**

创建同一 runId 的 child session、transcript、meta，三者 token 分别为 12/12/99；断言只选择 child session 的 12。再创建只有 transcript+meta 的 run，断言选择 transcript；只有 meta 的 run，断言选择 meta。

- [ ] **Step 3: 写缓存与错误 RED**

注入 counting parser/file reader：连续两次 load 未变文件时每个文件只解析一次；修改一个文件后只重解析该文件。加入 malformed/permission fixture，断言 `errors` 非空而不是静默返回少量记录。

- [ ] **Step 4: 验证 RED**

Run: `swift test --filter UsageRepositoryTests`

Expected: FAIL，模块不存在。

- [ ] **Step 5: 最小 GREEN**

先建立 `Set(descriptors.compactMap(\.subagentRunId))`；artifact 分组后按以下规则选源：

```swift
if childRunIDs.contains(runID) { skip artifact }
else if transcriptExists { parse transcript only }
else { parse meta }
```

缓存 entry 保存 canonical URL、file resource identity、mtime、size、首尾 4KB digest、parsed offset 与 trailing partial line。文件只增长且 identity 不变时只解析追加字节；缩短、identity/digest 漂移或同尺寸替换时全量重解析。解析失败保留旧成功值并返回 error，不能把失败结果写成永久空缓存。

- [ ] **Step 6: 验证并提交**

Run: `swift test --filter UsageRepositoryTests && swift test`

```bash
git add docs/bugs/bug-tokenrec-subagent-usage-double-count.md Sources/TokenRec/UsageRepository.swift Tests/TokenRecTests/UsageRepositoryTests.swift Tests/TokenRecTests/Fixtures/repository
git commit -m "fix(usage): 按运行身份消除主会话与子代理重复计数"
```

---

### Task 5: Store 发布、错误 UI 与成本卡片

**Deps:** Task 3, Task 4

**WritePaths:**
- `Sources/TokenRec/UsageStore.swift`
- `Sources/TokenRec/TokenRecApp.swift`
- `Sources/TokenRec/ContentView.swift`
- `Sources/TokenRec/UsageStatsView.swift`
- `Sources/TokenRec/UsageChartView.swift`
- `Tests/TokenRecTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `UsageRepository.load`、`UsageAggregator.summarize`
- Produces: `UsageStore.summary: UsageSummary`、`lastError: String?`、四粒度 points

- [ ] **Step 1: 写 Store RED**

用 fake repository 返回两小时记录和一个 error，等待 `refresh()` 后断言：

```swift
XCTAssertEqual(store.summary.todayTokens, 300)
XCTAssertEqual(store.summary.totalCost, 0.35, accuracy: 0.000_001)
XCTAssertNotNil(store.lastError)
```

测试必须等待显式 async `await store.refresh()`，不得 Timer polling。

- [ ] **Step 2: 验证 RED**

Run: `swift test --filter UsageStoreTests`

Expected: FAIL，Store 没有可注入 Repository/async refresh/summary。

- [ ] **Step 3: 最小 GREEN**

`UsageStore` 只在 background load 完成后于 MainActor 一次发布 summary/errors；timer 调用同一 async API并防重入。UI：

- MenuBarLabel 只读 `summary.todayTokens`；
- 恢复第四张“累计成本”卡，显示 `summary.totalCost`；
- `lastError` 在面板显示可见告警和当前数据目录；
- 图表只读 summary points。

- [ ] **Step 4: 验证并提交**

Run: `swift test --filter UsageStoreTests && swift test && swift build -c release`

```bash
git add Sources/TokenRec/UsageStore.swift Sources/TokenRec/TokenRecApp.swift Sources/TokenRec/ContentView.swift Sources/TokenRec/UsageStatsView.swift Sources/TokenRec/UsageChartView.swift Tests/TokenRecTests/UsageStoreTests.swift
git commit -m "fix(ui): 展示正确日用量成本与解析错误"
```

---

### Task 6: 性能、单实例与安装验收门禁

**Deps:** Task 4, Task 5

**WritePaths:**
- `docs/bugs/bug-tokenrec-performance-fix-lacks-regression-gate.md`
- `Sources/TokenRec/ProcessSingleton.swift`
- `Tests/TokenRecTests/ProcessSingletonTests.swift`
- `Tests/TokenRecTests/UsageRepositoryTests.swift`
- `scripts/verify-installed-app.sh`
- `scripts/build-app.sh`
- `.gitignore`

**Interfaces:**
- Consumes: Repository counting parser、installed app path
- Produces: `scripts/verify-installed-app.sh`，退出码 0 表示单实例/稳态/teardown 均通过

- [ ] **Step 1: 记录根因**

文档指出 `8353ec0` 只有 singleton RED，异步/缓存/聚合预计算是实现后测试；瞬时 `%CPU=0` 不能证明 60 秒稳态，且历史验收命令泄漏进程。

- [ ] **Step 2: 写 RED 门禁**

Repository test 断言 6 个不变文件在两次 refresh 中解析总次数仍为 6；一个文件追加后只解析新增行；同尺寸替换并恢复 mtime 仍因 digest 漂移重解析。并发 parser fixture 用 barrier 记录 `maxConcurrentParses`，断言大于 1，防止 `96d9410` 把文件解析放在 `NSLock` 临界区而把“8 路并发”退化为串行。脚本测试通过 shell fixture 验证 trap 会结束精确 PID，拒绝使用 `pkill`/`killall`。

- [ ] **Step 3: 验证 RED**

Run: `swift test --filter UsageRepositoryTests`

Expected: FAIL，当前缓存不在可注入 Repository 中或解析次数重复。

- [ ] **Step 4: 最小 GREEN**

验收脚本必须：

```bash
APP_PID=""
trap 'test -z "$APP_PID" || kill "$APP_PID" 2>/dev/null || true' EXIT INT TERM
open -n "$HOME/Applications/TokenRec.app"
# 通过 bundle executable 精确取得 PID，第二次 open 后仍只有该 PID。
```

CPU 以 `ps -o time=` 的 60 秒增量计算，不使用单点 `%CPU`；阈值和测试数据规模写入输出。结束后确认 PID 不存在。

- [ ] **Step 5: 验证并提交**

Run:

```bash
swift test
swift build -c release
./scripts/build-app.sh
./scripts/verify-installed-app.sh
```

```bash
git add docs/bugs/bug-tokenrec-performance-fix-lacks-regression-gate.md Sources/TokenRec/ProcessSingleton.swift Tests/TokenRecTests/ProcessSingletonTests.swift Tests/TokenRecTests/UsageRepositoryTests.swift scripts/verify-installed-app.sh scripts/build-app.sh .gitignore
git commit -m "test(runtime): 固化单实例缓存与稳态进程门禁"
```

---

### Task 7: Clean archive、文档与独立复审

**Deps:** Task 5, Task 6

**WritePaths:**
- `README.md`
- `docs/summaries/2026-08-05-tokenrec-correctness-verification.md`

**Interfaces:**
- Produces: 最终命令、fixture 总量、安装版 PID/CPU/签名与 residual risk 报告

- [ ] **Step 1: 更新 README**

写清目录自动选择优先级、手工覆盖、child session/transcript/meta 权威顺序、reported cost 含义、首次索引与增量刷新行为。

- [ ] **Step 2: Clean archive 验证**

从 `HEAD` 创建临时 archive，不复制 ignored/untracked 文件，运行：

```bash
swift test
swift build -c release
./scripts/build-app.sh
```

断言没有 `/Users/mhbzhy/` 测试路径，`git ls-files dist .build` 为空。

- [ ] **Step 3: 真实 fixture 与安装版验证**

对脱敏重复 fixture 断言 canonical total；运行 `scripts/verify-installed-app.sh`；执行 `codesign --verify --deep --strict`。

- [ ] **Step 4: 独立代码复审**

审查累计 diff，重点检查 source precedence、cost 双计、actor/thread safety、cache invalidation、错误重试、process ownership；最多两轮。

- [ ] **Step 5: 记录并提交**

```bash
git add README.md docs/summaries/2026-08-05-tokenrec-correctness-verification.md
git commit -m "docs(tokenrec): 记录数据正确性与运行验收"
```

**Acceptance Commands:**

```bash
swift test
swift build -c release
./scripts/build-app.sh
./scripts/verify-installed-app.sh
codesign --verify --deep --strict "$HOME/Applications/TokenRec.app"
git diff --check
git status --short
```
