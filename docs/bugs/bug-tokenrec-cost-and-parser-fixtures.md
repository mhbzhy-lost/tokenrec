# TokenRec 丢失真实成本且解析测试依赖本机文件

## 1. 预期行为

TokenRec 应保留 Pi runtime/provider 在 session、subagent transcript 或 meta 中报告的真实成本，并能在任意 clean clone 中使用仓库内脱敏 fixture 验证解析行为。

## 2. 实际行为

`UsageRecord` 没有成本字段，`UsageParser.record` 只保留 token 与 model；即使输入包含 `usage.cost` 或 `usage.cost.total`，结果也永久丢失。`UsageParserTests.testRealFilesProduceRecords` 还写死 `<home>/...`，离开当前主机即失败。

## 3. 稳定复现

1. 向 `UsageParser.parseSession` 输入含 `"cost":{"total":0.0125}` 的 usage。
2. 向 `UsageParser.parseSubagentTranscript` 输入含 `"cost":0.0125` 的 usage。
3. 当前返回值无法表达该成本。
4. 在没有所写死绝对路径的 clean clone 中运行 `swift test --filter UsageParserTests`，真实文件测试失败。

## 4. 根因

早期数据模型只围绕 token 统计设计，Parser 的公共收口函数没有把 provider/runtime 的 reported cost 传入模型。测试则把开发机真实文件当作 fixture，错误地把本机目录结构和数据可用性变成测试前置条件。

## 5. 影响范围

累计成本和按时间粒度的成本始终为零，UI 无法恢复真实成本卡片；session、transcript、meta 三类输入都受影响。绝对路径测试导致 clean archive、CI 和其他开发机无法可靠复现验收。

## 6. 修复与验证

为 `UsageRecord` 增加默认值为 0 的 `cost`，Parser 只读取 runtime/provider 报告的 number 或 `{total:number}`，不做价格估算。以仓库内脱敏 fixture 替换绝对路径，并先验证 cost 测试在旧实现上 RED，再执行 Parser 专项和全量 Swift 测试。
