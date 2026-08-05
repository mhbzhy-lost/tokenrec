# TokenRec 拒绝带连字符的已配置子代理名称

## 1. 预期行为

任何由 Pi subagent runtime 创建、名称满足 `subagent-<agent>-<uuid>-<index>` 的 child session 都应提取同一个 runId，与该 run 的 transcript/meta 做权威源选择。

## 2. 实际行为

Scanner 的正则只接受 `executor|spark|delegate`。例如仓库已有的 `plan-reviewer` 等已配置 agent 会返回 `subagentRunId=nil`。

## 3. 稳定复现

输入 `session_info.name=subagent-plan-reviewer-44444444-4444-4444-8444-444444444444-1`。当前 `sessionDescriptors` 能读取 sessionId/cwd，但 runId 为空。

## 4. 根因

实现把当前常用 agent 白名单误当成 runtime 命名协议；而 agent catalog 可扩展，agent 名还允许连字符。身份解析不应依赖固定名称枚举。

## 5. 影响范围

这类 child session 本身会计数，但 Repository 不知道它已覆盖同 runId 的 artifact，于是 transcript/meta 仍被加入，造成 token 与 cost 双计。

## 6. 修复与验证

正则改为接受非空的字母数字、点、下划线或连字符 agent 名，并仍严格要求末尾标准 UUID 与数字 index。先增加 `plan-reviewer` fixture 验证旧实现 RED，再运行 Scanner、Repository 和全量测试。
