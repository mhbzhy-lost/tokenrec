# TokenRec

TokenRec 是原生 macOS 状态栏 Token 消耗记录工具。它从本机 pi 会话文件读取用量，无网络同步、无第三方依赖。

## 功能

- 状态栏图标旁显示当天 Token 总量。
- 点击状态栏菜单可查看今日、本月、累计和成本统计卡片。
- 支持按小时、天、周、月四种粒度查看用量折线图。
- 同时统计 pi 主会话和 subagent 会话；读取 transcript 与 meta 数据并避免重复计数。
- 每 10 秒刷新一次数据。
- 可在面板中设置会话目录。

## 数据来源

默认会话目录为 `~/.pi/agent/sessions`。也可以通过环境变量 `PI_CODING_AGENT_SESSION_DIR` 指定目录，或在应用面板中使用“设置目录”修改。TokenRec 只读取本地会话数据。

## 构建与安装

需要 macOS 13 或更高版本，以及 Swift 6 工具链。

```bash
# 运行测试
swift test

# 构建、生成 .app、ad-hoc 签名并安装到 ~/Applications
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```

脚本会先执行 `swift build -c release`，然后生成 `dist/TokenRec.app`，并安装为 `~/Applications/TokenRec.app`。构建完成后可从 Finder 的“应用程序”目录启动 TokenRec。

若只需构建可执行文件：

```bash
swift build -c release
.build/release/TokenRec
```
