# TokenRec 默认会话目录失配且缺少子代理运行身份

## 1. 预期行为

没有有效手工配置时，TokenRec 应自动选择当前 Pi 实际使用且含 JSONL 的 session 目录；扫描结果还应从 child session 头部稳定提取 session id、cwd 与 subagent runId，为跨源权威选择提供身份依据。

## 2. 实际行为

`resolveSessionDir` 固定回退 `~/.pi/agent/sessions`，并把空字符串配置当作路径；当前主机该目录没有 JSONL，而 `~/pi-config/var/sessions` 有真实数据。Scanner 只返回 URL，并未提取 child session 中的 subagent runId。

## 3. 稳定复现

1. 将 UserDefaults `sessionDir` 设为空字符串或只含空格。
2. 保持 `~/pi-config/var/sessions` 含 JSONL、`~/.pi/agent/sessions` 为空。
3. 当前 resolver 返回空路径或旧默认目录，应用展示零数据。
4. 输入含 `session_info.name=subagent-executor-<uuid>-1` 的 child session，当前 Scanner 无 API 返回该 UUID。

## 4. 根因

目录解析只做 nil 合并，没有规范化空白配置，也没有验证候选目录是否存在并含 JSONL；默认值仍沿用旧 Pi 布局。文件扫描与 session 头部解析分离不足，导致 repository 无法以 runId 判断 child session 是否覆盖 transcript/meta。

## 5. 影响范围

默认安装可能直接显示零数据；错误空配置会永久遮蔽有效环境变量和默认候选。缺少 runId 会迫使上层按 token 内容猜测去重或彻底删除 artifact 数据源，两者都会造成错误统计。

## 6. 修复与验证

增加 `SessionDescriptor` 与只读前 64KB/20 行的头部解析，runId 只接受受支持 agent 名称后的标准 UUID。目录解析过滤空白值，并按显式配置、环境变量、`~/pi-config/var/sessions`、旧目录依次选择存在且含 JSONL 的候选。先用脱敏 fixture 和临时目录测试验证旧实现 RED，再运行 Scanner 专项与全量测试。
