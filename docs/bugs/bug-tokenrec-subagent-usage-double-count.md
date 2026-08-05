# TokenRec 子代理跨源重复计数与 fallback 丢失

## 1. 预期行为

同一 subagent run 应按 child session > artifact transcript > artifact meta 选择唯一权威来源；没有 child session 的合法历史 run 仍应由 transcript 或 meta 提供 fallback。文件错误必须可见且可重试，未变化文件应复用缓存。

## 2. 实际行为

旧实现同时累加 child session 和 transcript，真实样本 `461a119b-...` 两边 token 序列相同而被计算两次。`96d9410` 为避免双计又彻底停止扫描 transcript/meta，使 artifact-only run 永久漏计。当前 Store 还用 `try? ... ?? []` 吞掉解析错误并可能缓存空结果。

## 3. 稳定复现

1. 为同一 runId 准备 child session、transcript、meta，分别记录 12、12、99 tokens。
2. 再准备 transcript+meta 的 artifact-only run 和仅 meta 的 run。
3. 旧多源实现对第一组计算 123，`96d9410` 之后只计算 child 12 且遗漏后两组。
4. 让 parser 首次读取失败；当前结果为空、`lastError` 不赋值，后续在元数据不变时可能继续复用错误状态。

## 4. 根因

跨源文件发现与 runId 权威选择没有独立领域层：Store 既扫描、解析、缓存又聚合。旧代码只能按文件累加，后续修复则把“选择权威源”误简化为“删除数据源”。缓存也没有区分成功结果和读取失败。

## 5. 影响范围

TokenRec 会在不同 Pi/subagent 布局下高估或低估 token/cost；失败、迁移期或只有 artifact 的合法 run 尤其容易漏计。权限和临时 IO 故障会静默展示不完整数据，用户无法判断统计是否可信。

## 6. 修复与验证

新增 actor `UsageRepository`，先按 session header 建立 child runId 集，再按 runId 选择 transcript 或 meta fallback。文件缓存只保存成功解析，使用 identity、mtime、size 与首尾 digest 判定变化；追加 session 按安全字节偏移增量解析，失败保留旧成功值并返回结构化错误。以三源 fixture、fail-once parser、解析计数、同尺寸替换和并发计数测试先验证 RED，再做最小实现。
