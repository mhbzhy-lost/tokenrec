# Bug: TokenRec 多实例残留与 99% CPU 空转

日期：2026-08-05

## 现象（Symptom）

- 状态栏出现 3 个 TokenRec 图标，仅 1 个正常，其余 2 个卡住。
- 卡住的进程 99% CPU 持续空转（实测 25 分钟累计 25:30 CPU 时间）。
- `~/Applications/TokenRec.app` 正常启动的实例同样 99% CPU（实测 8 秒内 98.8%）。

## 影响（Impact）

- 多实例并存：executor 验证脚本（`.build/debug/TokenRec & sleep N`）每次运行都会留下一个后台残留实例，累积多个。
- 单实例也 99% CPU：UI 主线程被阻塞数十秒，状态栏图标无响应（"卡住"）。

## 根因（Root Cause）

三级问题：

1. **UI body 内 O(n) 聚合 × 高频重绘**（最终根因，sample 采样实证）：`MenuBarLabel.body` 每次求值都执行 `UsageAggregator.aggregate(records, granularity: .hour)`（遍历全部记录做 Calendar 计算），而状态栏 label 被高频重绘 → 主线程持续满载。`ContentView` 的统计卡片与图表同样在 body 内重复聚合。
2. **启动/刷新性能灾难**：
   - `UsageParser.date(_:)` 对**每一行 JSONL** 都新建 2 个 `ISO8601DateFormatter`（ICU `udat_open` 资源加载，sample 显示全部热点）。
   - `UsageStore.refresh()` 每 10 秒**全量重新解析全部文件**（无 mtime 缓存、无增量），单次解析数十秒，Timer 永远追不上 → CPU 持续 100%。
   - `SessionScanner.projectCwds` 每次 refresh 全量读 864 个文件所有行找 cwd。
   - 解析在 **@MainActor 主线程同步**执行（`init → startMonitoring → refresh`），阻塞 UI。

3. **无单实例保护**：任意启动方式都会再起一个进程，状态栏图标堆积。

## 触发条件（Trigger）

- 任何方式第二次启动 TokenRec（包括验证脚本的后台启动残留）。
- 首次启动即触发（主线程同步全量解析 + label 高频聚合）。

## 复现步骤（Reproduction）

1. `swift build -c release && .build/release/TokenRec &` 启动。
2. `ps -p <pid> -o %cpu` 观察：数秒内即达 ~99% 且持续（25 分钟累计 25:30 CPU）。
3. 重复执行启动命令 → 状态栏出现多个图标。
4. `sample <pid> 3` 采样：热点在 `MenuBarLabel.body → UsageAggregator.aggregate` 与 `UsageParser.date → ISO8601DateFormatter 创建`。

## 修复方案（Fix）

1. **单实例**：`ProcessSingleton`（flock 文件锁 `/var/folders/.../T/tokenrec.lock`），`tryAcquire()` 失败即 `exit(0)`；进程退出/崩溃自动释放。
2. **聚合预计算**：`UsageStore` 后台聚合全部 4 粒度与统计指标（today/month/total）后 `@Published` 发布；`MenuBarLabel`/`ContentView`/`UsageStatsView`/`UsageChartView` 只读预计算结果，不再在 body 内聚合。
3. **formatter 复用**：两个 `ISO8601DateFormatter` 静态只读实例（带/不带毫秒）；NSDateFormatter 官方线程安全，无锁共享。
4. **增量刷新**：`fileCache`（mtime+size+解析结果）只重解析变化文件；`projectCwds` 结果缓存（key=文件清单 mtime 摘要）；`projectCwds` 只读文件头 64KB/前 20 行（cwd 恒在首条 session entry）。
5. **异步解析**：全部发现/解析/聚合在 `Task.detached(utility)` + 8 路并发（DispatchSemaphore），主线程仅赋值发布。
6. **快速预筛**：解析器逐行 `contains("usage")` 预筛，无 usage 行（绝大多数）跳过 JSON 解析。

## 验证（Verification）

- `ProcessSingletonTests` 4 用例（互斥/释放后可获取/不同锁文件不冲突/反复获取稳定）；全量 24 测试绿。
- 首启：~20 秒完成首次全量加载（后台，UI 不卡）；稳态 60 秒窗口新增 CPU 2.2 秒（~4%），瞬时 0.0%（修复前 100% 持续）。
- 双开：第二实例立即退出（exit 0），仅一个进程、一个状态栏图标。
