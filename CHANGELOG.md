# Changelog

本文件记录尚未发布和已发布版本中会影响接入方、协议行为或安全边界的变化。

## Unreleased

### Changed

- `inputWasStdin` 由框架层收编。host 在把 arguments 交给 consumer 之前按 descriptor 的
  `sensitive` 声明完成校验（任一 sensitive 参数带非空值却缺少该标记时，以
  `sensitiveInputRequiresStdin` 拒绝，`details.parameters` 列出违规参数名），随后把这个元键剥掉：
  `domainInvoke` 收到的 arguments 永远不含它。`plane: flutterUi` 的命令例外——其敏感性是目标级
  而非参数级，元键仍交给 `patchbay_flutter` 的 bridge。command codegen 同步不再豁免、也不再校验
  该键。catalog 是这条策略的唯一真源，读不到时带参调用 fail-closed
  （`providerProtocolViolation` / `catalogUnavailable`）。

  **迁移：手写 adapter 升级 pin 后必做两步。**① 删掉 arguments 白名单里对 `inputWasStdin` 的
  豁免（**不删无害**，只是死代码）；② 删掉 adapter 自实现的 stdin 强制检查（**不删必炸**——host
  剥键后该判断恒为假，所有合法的敏感调用都会被 App 侧误拒）。规范表述：host 已接管
  sensitivePolicy 校验，手写 invoke 不得再依赖 `inputWasStdin` 键。用 codegen 的接入方升级 pin
  后重新生成即可；停留在旧 pin 的接入方不受影响，旧 host 与旧生成代码在旧语义下自洽。

### Fixed

- `blob.read` 的 `limit` 与 descriptor 对齐：wire 允许缺省，host 补上 catalog 声明的同一个默认值
  （`PatchbayMemoryBlobStore.maxChunkBytes`）。此前 descriptor 标了默认值但 wire 必填，声明与实际
  不符。
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
