# TokenRec 统计摘要分散且真实成本无法聚合

## 1. 预期行为

今日、本月、累计 token、累计 reported cost 和四种图表粒度应由同一个可测试的纯函数按给定时区与当前时间计算，UI 与状态栏只读取同一份摘要。

## 2. 实际行为

`UsageStore` 分别调用四次 aggregate 后自行取最后一个 bucket，再单独 reduce 累计 token；`UsageAggregator` 不聚合 `UsageRecord.cost`，也没有摘要接口。今日口径虽在近期提交中改为当天 bucket，但没有直接回归测试。

## 3. 稳定复现

构造同一天不同时段的 100、200 tokens 与上月 50 tokens，并分别附带 0.10、0.20、0.05 reported cost。当前代码无法一次返回 today=300、month=300、total=350、cost=0.35，也没有测试能阻止今日值退化为当前小时。

## 4. 根因

统计职责分散在 Store 和 Aggregator，Aggregator 的 bucket 状态只保存 token 整数，成本字段没有贯通。缺少稳定的 `now/calendar` 注入使业务边界只能通过异步 Store 间接验证。

## 5. 影响范围

状态栏、统计卡片和图表可能使用不同计算路径；成本图表始终为零；今日口径、月边界和时区行为容易再次回退且难以定位。

## 6. 修复与验证

增加 `UsageSummary` 和纯函数 `summarize(records, now, calendar)`，使用 Calendar 的日/月 DateInterval 计算边界，并让四粒度聚合同时累计 token 与 reported cost。先用手算字面量写 RED，再运行 Aggregator 专项与全量测试。
