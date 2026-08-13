# Changelog

本文件记录尚未发布和已发布版本中会影响接入方、协议行为或安全边界的变化。

## Unreleased

### Changed

- CLI `--stdin` 与 `--args` 由「整体替换」改为「合并，stdin 覆盖同名键」。原先「stdin 提供全量
  参数」的用法成为 `--args` 缺席时的退化情形，行为不变；stdin 内容仍必须是 JSON object。
  同时新增 fail-closed：catalog 声明 `sensitive: true` 的参数若出现在 `--args`，CLI 直接以退出码
  `64` 拒发，不再依赖 App 侧兜底，错误信息不回显值。
- CLI `--json` 时一切错误也输出到 stdout 的稳定 JSON 错误信封
  `{"error":{"code":...,"details":{...}}}`，字段与 rejection 信封同形；人读文本仍只走 stderr。
  无 `--json` 行为不变。
- CLI `navigation go|push|back` 省略 `--revision` 时自动先读 `navigation.current` 再派发，结果带
  `revisionSource`。revision 围栏本身不变，读到与派发之间导航动过仍被 App 拒绝；显式
  `--revision` 行为不变。
- CLI `patchbay help <topic>` 接受 catalog 协议名（`navigation.go`、`ui.semantics.tap`、`ui.wait`）
  与别名拼写（`navigate` / `nav` / `wait` / `tap` / `text` / `semantics`、`ui wait <condition>`）。
  别名只增加拼写，不新增命令，也不改任何既有命令名或 condition 名。
- `PatchbayArtifactDownloader.chunkBytes` 由静态常量改为实例字段（常量更名
  `defaultChunkBytes`）；CLI 按 catalog 中 `blob.read` 的 `limit` 默认值与之取小。

### Fixed

- CLI `--wait` 的终态结果在响应顶层回填 `jobId`，与受理信封口径一致；`payload.jobId` 保留为 App
  job snapshot 字段。人读摘要对终态 job 输出 `jobId=… terminal=true phase=…`，不再吞掉 outcome。
- CLI 下载 artifact 时不再写死 64 KiB 分块：host 把 `maxChunkBytes` 调小于该值时，原先每个
  `blob.read` 都会被 `blobInvalidChunkLimit` 拒绝，下载完全不可用。

- `schemaVersion` 改为 host 保留字段，consumer catalog / snapshot 回调不能覆盖。
- catalog 拒绝重复或缺少名称的 command，避免目录展示与实际 dispatch 产生歧义。
- host 严格验证 invocation wire、协议版本和 `requestId`；provider 返回非法信封时转换为
  `providerProtocolViolation`，不把不相关响应交给调用方。
- VM Service 与 direct 两条路径都拒绝空 `requestId`；invocation 同时校验 admission、rejection、payload
  与 jobId 的条件不变量。
- Flutter text / Semantics operator 沿用调用方 `requestId`，VM Service 与 direct client 同时验证响应相关性。
- `retainedJobs` 按已结束任务计数，并在任务进入终态时立即执行淘汰。

### Added

- `ui.semantics.tap`：按稳定 Semantics identifier 一步完成解析、代际校验与派发，取代
  `ui.semantics.tree` + `ui.semantics.action` 两跳；CLI 侧为 `patchbay ui tap <identifier>`，
  `--generation` 可选。解析出的 generation 在过门前 pin 住，门后二次解析必须命中同一 generation；
  未命中、多义与代际过期都是带 details 的稳定拒绝。与 `ui.semantics.action` 共用 action policy，
  没有 consumer policy 时不进 catalog、不可派发。
- `patchbay repl`：一次连接内从 stdin 逐行执行 typed 命令，语法与一次性调用相同。每行结果自带
  `exitCode`，会话退出码只描述会话本身。连接类参数、`--json` 与 `--stdin` 在会话内逐行 fail-closed；
  direct HTTP 传输不支持 repl（bearer token 会与命令流共用 stdin）。
- `runPatchbayCli` 增加 `connect` / `replInput` / `output` / `errorOutput` 测试接缝参数；新增公共
  `PatchbayReplSession`、`tokenizePatchbayReplLine` 与 `patchbayResponseSummary`。
- `PatchbayJobRegistry.maxRunningJobs`，默认 `32`；达到上限时同步抛出
  `PatchbayJobCapacityExceeded`，任务 body 不会启动。
- `PatchbayJobRegistry.cancellationTimeout`，默认 `5s`；取消回调超时会保留 running 状态，
  不谎报底层操作已经停止。
- 没有 cancellation callback 的 job 不再被标记为 cancelled；`cancel()` 返回 `false` 并保留 running。
- Job registry 提供 `runningJobs`、`settledJobs` 和 `totalJobs` 只读计数。
