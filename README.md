# TokenRec

TokenRec 是原生 macOS 状态栏 Token 消耗记录工具。它只读取本机 Pi 会话与 subagent 运行产物，无网络同步、无第三方依赖。

## 功能

- 状态栏显示当天累计 Token，而不是当前小时。
- 面板展示今日、本月、累计 Token 和 runtime/provider 报告的累计成本。
- 支持按小时、天、周、月四种粒度查看用量折线图。
- 同时统计 Pi 主会话、child session 与 artifact-only subagent run。
- 首次建立文件缓存；点击面板立即增量刷新，5 分钟轮询作为兜底。
- 解析失败会在面板显示文件路径与错误，不会把失败结果缓存为空数据。
- `flock` 单实例保护避免重复状态栏图标。

## 数据来源与优先级

会话目录按以下顺序选择，空白配置会被忽略，候选目录必须存在且递归包含 `.jsonl`：

1. 面板“设置目录”保存的 `sessionDir`；
2. 环境变量 `PI_CODING_AGENT_SESSION_DIR`；
3. `~/pi-config/var/sessions`；
4. 兼容旧布局的 `~/.pi/agent/sessions`。

同一 subagent run 只选择一个权威来源：

```text
Pi child session > artifact transcript > artifact meta
```

因此 child session 与 transcript 不会重复计数，同时仍保留没有 child session 的 artifact-only fallback。权威选择以 runId 为依据，不按 token 数值猜测去重。

成本只采用 runtime/provider 在 usage 中报告的数值或 `cost.total`；缺失时记为 0，不根据模型价格估算。

## 构建与安装

需要 macOS 13 或更高版本，以及 Swift 6 工具链。

```bash
swift test
./scripts/build-app.sh
```

构建脚本执行 release build，生成并 ad-hoc 签名 `dist/TokenRec.app`，然后安装到 `~/Applications/TokenRec.app`。`dist/` 与 `.build/` 均不纳入 Git。

若只需构建可执行文件：

```bash
swift build -c release
.build/release/TokenRec
```

## 安装版验收

先退出任何已运行、并非本次验收启动的 TokenRec，再运行：

```bash
./scripts/verify-installed-app.sh
```

脚本会直接启动安装包中的 executable 并记录精确 PID，验证第二实例立即退出，在默认 60 秒窗口比较同一 PID 的累计 CPU 时间，最后只回收本次启动的 PID。若发现既有 TokenRec 进程，脚本会 fail closed，不会自行终止。

可在受控调试环境覆盖采样参数：

```bash
TOKENREC_VERIFY_SECONDS=60 TOKENREC_MAX_CPU_SECONDS=5 ./scripts/verify-installed-app.sh
```
