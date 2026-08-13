# Changelog

本文件记录尚未发布和已发布版本中会影响接入方、协议行为或安全边界的变化。

## Unreleased

### Fixed

- `schemaVersion` 改为 host 保留字段，consumer catalog / snapshot 回调不能覆盖。
- catalog 拒绝重复或缺少名称的 command，避免目录展示与实际 dispatch 产生歧义。
- host 严格验证 invocation wire、协议版本和 `requestId`；provider 返回非法信封时转换为
  `providerProtocolViolation`，不把不相关响应交给调用方。
- VM Service 与 direct 两条路径都拒绝空 `requestId`；invocation 同时校验 admission、rejection、payload
  与 jobId 的条件不变量。
- Flutter text / Semantics operator 沿用调用方 `requestId`，VM Service 与 direct client 同时验证响应相关性。
- `retainedJobs` 按已结束任务计数，并在任务进入终态时立即执行淘汰。
- `cancelAll()` 并行发起全部运行中 job 的取消：每个回调各自受 `cancellationTimeout` 约束，一个卡死或
  抛错的回调不再阻塞后续 job，也不再中断整批取消。

### Added

- `PatchbayJobRegistry.maxRunningJobs`，默认 `32`；达到上限时同步抛出
  `PatchbayJobCapacityExceeded`，任务 body 不会启动。
- `PatchbayJobRegistry.cancellationTimeout`，默认 `5s`；取消回调超时会保留 running 状态，
  不谎报底层操作已经停止。
- 没有 cancellation callback 的 job 不再被标记为 cancelled；`cancel()` 返回 `false` 并保留 running。
- Job registry 提供 `runningJobs`、`settledJobs` 和 `totalJobs` 只读计数。
- `PatchbayJobCancelOutcome`；`cancelAll()` 改为返回逐 job 结果（`cancelled` / `notCancellable` /
  `timedOut` / `callbackFailed` / `alreadySettled`），不用单个结论概括全批，超时、抛错和无回调的 job
  仍如实保持 running。
