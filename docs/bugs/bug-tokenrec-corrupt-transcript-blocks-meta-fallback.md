# TokenRec 损坏 transcript 阻断 meta fallback

## 1. 预期行为

artifact-only run 应优先采用可解析的 transcript；若 transcript 存在但读取或解析失败，应保留该错误并降级到同 runId 的合法 meta，避免整次用量归零。

## 2. 实际行为

Repository 在文件发现阶段只要看到 transcript 就不选择 meta。后续 transcript parse 失败只返回 error，不再尝试 meta。

## 3. 稳定复现

为同一 runId 创建含非法 usage JSON 的 `_transcript.jsonl` 与记录 40 tokens 的合法 `_meta.json`，且不创建 child session。当前 `load` 返回 transcript 错误，但 records 不含 40 tokens。

## 4. 根因

“来源权威顺序”在发现阶段被实现为静态单选，而不是“按顺序选择首个可用且可解析的来源”。解析阶段没有保留次级候选信息。

## 5. 影响范围

transcript 写入中断、权限瞬态或文件损坏时，artifact-only run 的 token 与 reported cost 会长期显示为 0；meta 明明可用却被存在性判断遮蔽。

## 6. 修复与验证

在 transcript 候选上保留同 runId 的 meta URL。仅当 transcript 首次解析失败且没有可保留的旧成功缓存时解析 meta；结果仍返回 transcript 错误以提示数据降级。先写损坏 transcript + 合法 meta RED，再运行 Repository 与全量测试。
