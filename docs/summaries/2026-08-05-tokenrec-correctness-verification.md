# TokenRec 数据正确性与运行验收记录

日期：2026-08-05

## 修复范围

- session、transcript、meta 均保留 runtime/provider reported cost。
- 默认目录优先发现 `~/pi-config/var/sessions`，过滤空白覆盖值。
- 从 child session header 提取 subagent runId。
- Repository 按 `child session > transcript > meta` 选择权威源，保留 artifact-only fallback。
- actor 内维护成功缓存；解析失败返回可见错误且后续重试。
- 文件解析限 8 路并发；未变化文件复用缓存；append 只解析安全尾部；不完整末行不会丢失。
- Store 只在 MainActor 发布一次摘要，UI 展示全天、当月、累计 Token、reported cost 和错误路径。
- 安装验收脚本持有精确 PID，并用累计 CPU 时间而非瞬时 `%CPU` 判断稳态。

## 自动化证据

- clean rebuild：46 tests，0 failures，编译输出无 warning。
- `UsageRepositoryTests`：覆盖三源权威顺序、artifact-only fallback、六次静态 load、append、partial line、同尺寸恢复 mtime 替换、失败重试与并发解析。
- `UsageStoreTests`：覆盖 MainActor 摘要发布、reported cost、错误、数据目录和 refresh 防重入。
- `RuntimeVerificationScriptTests`：teardown probe 只结束本次 owned PID，无关 sentinel 继续存活。

## Clean archive 验证

从提交 `7e18818` 的 `git archive` 创建无 ignored/untracked 文件的临时目录，并使用隔离 HOME 执行最终 clean archive 验证。

```text
swift test                         PASS（46/46）
swift build -c release             PASS
./scripts/build-app.sh              PASS
codesign --verify --deep --strict  PASS
git ls-files dist .build           空
git grep /Users/mhbzhy/ Sources Tests scripts Package.swift  无匹配
```

临时安装包位于隔离 HOME，未覆盖真实 `~/Applications/TokenRec.app`。

## 独立复审

第一轮复审发现 transcript 存在但损坏时不会降级到同 runId 的 meta。该 Important 已按 bug-first/TDD 修复于 `7e18818`：无旧 transcript 成功缓存时，保留 transcript error 并采用合法 meta；专项和全量测试通过。第二轮只读复核未发现阻断项，建议代码验收通过。

保留一项 Minor residual：artifact 目录仍由 session header 中的 cwd 推导；如果 artifact-only run 只存在于未出现在任何 child session header 的 worktree 路径，可能漏计。当前实盘盘点的 23 个 artifact-only run 均为失败且零 usage；为发现任意 dispatch cwd 而反复全量扫描大型 parent session 会重新引入 CPU 风险，本轮不扩大扫描面。

## 尚待安装版 canary

真实安装版验收当前 fail closed：发现已有、非本次验收启动的进程：

```text
PID 88807 /Users/mhbzhy/Applications/TokenRec.app/Contents/MacOS/TokenRec
```

本次没有终止或接管该进程，也没有覆盖正在运行的真实安装包。另用隔离 `HOME/TMPDIR` 尝试启动同一 HEAD 的临时安装包，但 `FileManager.default.temporaryDirectory` 仍使用系统用户临时目录，临时实例因 PID `88807` 持有全局 singleton lock 而立即退出；验收脚本返回 70 且未误杀该 PID。这不能替代真实 canary。

待用户退出该实例后，执行：

```bash
./scripts/build-app.sh
./scripts/verify-installed-app.sh
codesign --verify --deep --strict "$HOME/Applications/TokenRec.app"
```

在上述 canary 与独立复审完成前，状态为：**代码与 clean archive 通过，真实安装版尚未最终验收**。
