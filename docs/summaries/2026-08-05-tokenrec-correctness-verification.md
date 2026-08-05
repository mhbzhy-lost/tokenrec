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

- clean rebuild：45 tests，0 failures，编译输出无 warning。
- `UsageRepositoryTests`：覆盖三源权威顺序、artifact-only fallback、六次静态 load、append、partial line、同尺寸恢复 mtime 替换、失败重试与并发解析。
- `UsageStoreTests`：覆盖 MainActor 摘要发布、reported cost、错误、数据目录和 refresh 防重入。
- `RuntimeVerificationScriptTests`：teardown probe 只结束本次 owned PID，无关 sentinel 继续存活。

## Clean archive 验证

从提交 `b627452` 的 `git archive` 创建无 ignored/untracked 文件的临时目录，并使用隔离 HOME 执行最终 clean archive 验证。

```text
swift test                         PASS（45/45）
swift build -c release             PASS
./scripts/build-app.sh              PASS
codesign --verify --deep --strict  PASS
git ls-files dist .build           空
git grep /Users/mhbzhy/ Sources Tests scripts Package.swift  无匹配
```

临时安装包位于隔离 HOME，未覆盖真实 `~/Applications/TokenRec.app`。

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
