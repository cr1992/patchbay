# 0.5.0 Semantics probe 请帧策略与 identifier 索引

> 状态：已接受
>
> 关联：PB-050-07
>
> 设计闸门：DG-050-05

## 问题

`PatchbaySemanticsBridge.ensureOwner()` 当前每次调用都会 `scheduleFrame()` 并等待 `endOfFrame`；只有 owner
仍不可用时才继续到最多三轮。`snapshot`、identifier observe/resolve、find node 与 action probe 都经过它。
`ui.wait` 每轮 probe 后还会通过 frame observer 等下一帧，因此一次条件检查可能主动驱动两帧。

减少主动请帧不是纯内部性能改动：它会改变 semantics 变化被观察到的时机，以及 `ui.wait` 返回的
`elapsedMs`、`frameRevision` 和 timeout 边界。按 `_treeRevision` 建 identifier index 也会触及 node identity
与 generation fence。PB-050-04 只能提供量测；运行时策略必须由本 Proposal 裁决。

## 目标与非目标

### 目标

- owner/root 已可用且调用方已经承担帧推进时，不再为同一次 probe 额外主动请帧。
- owner 首次建立、替换或 root 尚不可用时，仍有有界的主动请帧恢复路径。
- 若 PB-050-04 证明 identifier 遍历是显著成本，可按 `_treeRevision` 缓存 identifier → node 引用索引；
  action 前继续执行 identity、generation、mounted/blocked 与 action availability 复核。
- 冻结 one-shot 与 `ui.wait` 各自的帧 cadence、timeout 和兼容输出。

### 非目标

- 不改变 semantics identifier 的稳定身份规则，不按树顺序解决歧义。
- 不缓存 `PatchbaySemanticsIdentifierObservation`、entry snapshot 或 action 决策。
- 不让 timer polling 替代 Flutter frame/semantics listener 事实。
- 不保证减少树遍历；只有 PB-050-04 数据达到接受阈值才实现 index。

## 契约

owner 获取分成两个内部操作：

1. `refreshOwnerNow`：同步读取当前 render views / root pipeline owner，处理 listener 的摘挂与 owner 变更；
2. `awaitOwner`：仅当当前没有带 root 的 owner 时，主动请帧并等待 `endOfFrame`，最多三轮，沿用现有单轮
   timeout。

one-shot semantics 命令先 `refreshOwnerNow`；已有 root 时直接 probe，不主动请帧。首次启用 semantics、
owner 被替换或 root 缺失时才进入 `awaitOwner`。这意味着 one-shot 读取的是调用开始时 engine 已提交的
semantics tree，不承诺额外刷新一帧；文档与响应不把它说成“命令后下一帧”。

`ui.wait` 的 cadence 固定为：立即 probe 一次；条件未满足时由 frame observer 请求/等待**恰好一个**下一帧，
随后在该帧结束后 probe；probe 自身在 owner 有效时不再请求第二帧。owner 丢失时恢复所需帧计入同一个
总 timeout 与 frame 计数，不延长调用方预算。

若启用 identifier index，cache key 为 `(owner identity, _treeRevision)`，value 只保存 identifier 对应的
`SemanticsNode` 引用列表。tree listener 或 owner 替换使整份 cache 失效；同一 revision 内重复 observe 可以
复用 node 列表，但每次都重新读取 `SemanticsData`。resolve/action 还必须把 node 与 generation ledger 当前
entry 做 `identical` 比较；cache 永远不能替 generation 做决定。

## 状态、失败与预算

owner 状态为 `unknown | ready | awaitingFrame | disposed`。同一时刻最多一个 `awaitOwner` flight；等待者共享
owner 建立结果，但各自 deadline 仍取剩余预算，短调用方 timeout 不取消 owner flight。

主动恢复仍最多三帧、单帧 timeout 默认 2 秒；本提案不放宽现有上限。identifier index 最多保留当前
owner/revision 一份，tree 变化整份丢弃，不跨 revision 做增量修补。snapshot 的 `maxNodes <= 10000` 保持；
identifier index 构建也受 10,000 节点遍历上限约束，超过稳定拒绝
`uiSemanticsTraversalLimitExceeded`，details 只含 `maxNodes/visitedNodes`，不留下半份 cache。

现有 lifecycle、owner unavailable、target ambiguous、node not observed、generation stale 与 action blocked/
unavailable code 不变。策略变化只允许影响 timing metadata；具体兼容口径由 DG-050-05 接受本文后冻结。

## 兼容与降级

- 公共 API、wire 与 descriptor 不加字段，`schemaVersion` 不变。
- 老 CLI + 新 host：命令形状相同；可能观察到较少 frameRevision 增量和更短 elapsedMs，这是待裁决的默认
  行为变化，不能在 Proposal 接受前实现。
- 新 CLI + 老 host：无 capability 分支；CLI 不应假设一次 probe 驱动几帧。
- VM/direct 都调用同一个 Flutter bridge；transport deadline 只夹总预算，不各自实现 cadence。
- debug/profile 都保留相同拒绝形状；非 debug 下 inspector 不可用的其他命令不因本提案扩张支持面。

## 安全与隐私

index 只持有 App 内 `SemanticsNode` 引用，不进入响应、日志或 audit，不持久化 label/value/text。owner/tree
失效必须释放引用，避免延长旧 UI 子树生命周期。release 构建继续不可达。

## 验证

- PB-050-04 benchmark 先给出基线：主动帧数、owner wait、扫描节点、总 probe 延迟与 App 原本是否空闲。
- fake scheduler/widget test：ready owner 的 one-shot 为零额外帧；首次 owner 建立最多三帧；`ui.wait` 每轮
  恰好一帧；owner 恢复不突破总 timeout。
- owner 替换、tree revision 变化、identifier 新增/删除/歧义、node identity 复用与 generation stale 全矩阵。
- index 开/关对有效 payload、稳定 code 与选择结果逐字节一致，允许变化的 timing 字段单独断言。
- debug example 验证空闲 App 不被 wait 以外的连续 probe 按显示帧率驱动；profile 只采性能，不替代
  semantics/inspector 覆盖。
- VM/direct 交错调用共享 owner flight/cache，任一 transport timeout 不破坏另一调用者。

## 待裁决

- 接受 ready owner 的 one-shot 零额外帧，还是保留 one-shot 一帧、只消除 `ui.wait` 的重复帧？
- `ui.wait.frameRevision` 表示 frame observer 看到的帧，还是所有 owner 恢复帧；本稿建议全部计入并在测试
  冻结，避免实际已驱帧却隐瞒。
- PB-050-04 达到什么阈值才实现 identifier index？建议至少证明树扫描占 probe 总耗时 20% 或单次 P95
  超过 2 ms，否则只改请帧策略。

### 裁决结论（DG-050-05，2026-08-26，仓主授权代理裁决）

仓主在会话中授权代理裁决（授权与过程记录于本 MR）。裁决输入为
[PB-050-04 量测报告](../../verification/0.5.0-semantics-probe-benchmark.md)：Android 真机 profile 下
`ensureOwner` 主动请帧占一次 probe 中位耗时的 8.465/8.598 ms（98.5%），扫描独占仅 0.133 ms；
未命中的 semantics wait 每轮稳定 2 帧。三条待裁决结论：

1. **ready owner 的 one-shot 采用零额外帧。** owner/root 已可用时直接 probe，不主动请帧——这是
   每次必付且占比最大的成本，量测已证明其收益上界远高于任何扫描优化。首次启用、owner 替换或
   root 缺失时保留本稿的有界恢复路径（最多三轮、单帧 timeout 2 秒不放宽）。连带口径：响应与
   文档不得把 one-shot 说成「命令后下一帧的树」；观察语义即当前已 flush 的树。
2. **`ui.wait.frameRevision` 计入所有实际驱动的帧**（含 owner 恢复帧），并以测试冻结。实际驱了
   帧却不报告是隐瞒；调用方按 frameRevision 推断成本时必须拿到真值。
3. **identifier index 本版不实现，接受阈值口径**：只有更大树规模的 profile 曲线（至少补 1k/10k
   节点）证明树扫描占 probe 总耗时 ≥ 20% 或单次 P95 > 2 ms 时，才允许引入 index 及其缓存失效
   与 node identity 风险。当前数据（35 节点 0.133 ms / 1.5%）远低于阈值，本版只改请帧策略。

安全围栏不变：无论采用何种调度，owner/tree identity、node identity、generation 与门后二次复核
一律保留（量测报告第 4 条决策输入原样生效）。

## 被否决方案

- 把 PB-050-04 的“透明降载”直接当实现授权：请帧变化会改变稳定 timing/timeout 行为，违反规划门禁。
- 只按 `_treeRevision` 缓存 observation/entry snapshot：数据与 generation ledger 会在使用时失真。
- 永久缓存 identifier → node、不监听 owner/tree：会对已卸载或同名新节点执行动作。
- 完全删除主动请帧：首次启用 semantics 或 owner/root 尚未建立时，命令会从可恢复退化成稳定不可用。
- `ui.wait` 同时保留 probe 请帧和 frame observer 请帧：继续为一次检查驱动两帧，无法解决量测中的大头。
