# 0.5.0 Snapshot 双预算、single-flight 与可选 source revision

> 状态：提案中
>
> 关联：PB-050-02
>
> 设计闸门：DG-050-01

## 问题

现有 snapshot revision 只限制保留 32 份，不限制单份或累计字节。大 body 可以长期占用大量内存；
`ui.wait`/snapshot wait 又会按 cadence 重复调用拉取式 source 并做全量 canonical JSON，即使内容没有变化。
内容去重已避免“无变化时重复 jsonDecode 深拷贝”，但没有避免 source 调用和 canonical 编码。

0.4.0 已接受 Proposal 明确把 revision 定义为 `hostObserved`，并把 consumer 上报 revision 留给未来版本。
0.5.0 若引入该能力，必须保持旧 typedef 可用，并明确它是内容事实还是仅供优化的提示。

## 目标与非目标

### 目标

- revision retention 同时受数量与 canonical UTF-8 字节约束，淘汰规则和失败可预测。
- 同一时刻的并发读共享一次 provider sampling；每个调用者仍独立执行 selection、diff、wait deadline 与
  响应组装。
- 提供 additive 的 versioned source API；旧 `PatchbaySnapshotSource` 无修改继续使用 `hostObserved`。
- consumer revision 相同的轮询可跳过 canonical；revision 前进时仍冻结/编码一次并进入同一 retention。

### 非目标

- 不承诺减少 `_snapshot()` 自身调用次数到零；没有 push 信号时，host 仍需采样才能知道 revision 是否变。
- 不用 sha256 替换 canonical equality。hash 仍要遍历字节，并引入碰撞与额外分配；可作为 benchmark 候选，
  不能作为契约。
- 不把多个 wait 调用的 deadline、path 或 condition 合成一个 Future。
- 不修改 0.4.0 的 `snapshotRevision` 作用域或 diff 结构。

## 契约

保留既有 typedef，并新增互斥的 additive 构造入口，语义形状为：

```dart
final class PatchbaySnapshotSample {
  const PatchbaySnapshotSample({required this.contentRevision, required this.body});
  final int contentRevision;
  final Map<String, Object?> body;
}

typedef PatchbayVersionedSnapshotSource =
    Future<PatchbaySnapshotSample> Function();
```

最终命名可以按仓内 API 风格调整，但以下语义不可变：`contentRevision` 为 appInstance 内非负、单调递增的
**内容 revision**；同值表示 body JSON 内容不变，内容变化必须递增，递增时 body 可以仍恰好相同但会被
视作一次新提交。host 不把 consumer 数值直接当 `snapshotRevision`，而是继续维护自己的连续序号。

legacy source 返回 `revisionSource: hostObserved`。versioned source 的有效采样返回
`revisionSource: consumerReported`；该字符串位于既有松读 snapshot map。source 模式由 host 构造期确定，
同一 appInstance 不允许运行中切换。

配置新增三个 host 内预算：保留份数、单份 canonical UTF-8 字节、累计 retained canonical UTF-8 字节。
返回 metadata 在既有松读面增加 `retainedByteLimit` 与 `snapshotBytes`；不向严格解码 request/wire 加字段。

## 状态、失败与预算

推荐默认候选如下，须由 DG-050-01 结合 example 与接入方 snapshot 分布裁决：

| 预算 | 推荐候选 | 可配置范围 |
|---|---:|---:|
| retained revisions | 32（保持现状） | 1..128 |
| single snapshot canonical bytes | 1 MiB | 64 KiB..4 MiB |
| total retained canonical bytes | 8 MiB | 不小于单份上限，最大 32 MiB |

新 revision 的处理顺序固定为：冻结/编码候选 → 检查单份上限 → 驱逐最老 revision 直到数量与累计字节
都能容纳 → 原子提交。单份超限返回既有 rejection 信封中的新稳定 code `snapshotPayloadTooLarge`，details
只含 `encodedBytes/maxSnapshotBytes`；失败不改变 latest 或 retention。因累计预算淘汰 baseline 后，diff
继续返回既有 `snapshotRevisionUnavailable`，并增加 `retainedByteLimit` 便于解释。

single-flight 只覆盖正在进行的 provider sampling。owner Future settle 后立即清除；失败对本批共享，下一次
调用可重试。等待循环中每一轮可以加入当时的 sampling flight，但自己的 stopwatch、poll count 与 timeout
独立，慢调用者不能延长其他调用者预算。

versioned source 还需校验：负数或倒退返回 `providerProtocolViolation/revisionRegressed`；同 revision 时
不得读取或保留 consumer 提供的新 body 引用，只复用上次冻结视图；revision 前进时按 PB-050-01 全量验证。
若 consumer 在同 revision 下偷偷修改 body，host 无法在不重做 canonical 的前提下检测，属于 provider
契约违约，文档必须直说。

## 兼容与降级

- legacy source API、默认 32 份计数和 `hostObserved` 路径保留；新增字节预算会带来新的拒绝，因此必须
  通过 0.5.0 Proposal 与 CHANGELOG 公告。
- 新 CLI 遇老 host：metadata 缺少字节字段时显示 `unknown`，不能猜默认值。
- 老 CLI 遇新 host：忽略松读 metadata 与 `consumerReported`，仍按数字 `snapshotRevision` 请求 diff。
- direct 自己的 response body 上限独立执行；snapshot 预算通过不代表 direct 一定能传输，失败必须保留
  transport code，不能伪装成 snapshot provider failure。
- VM/direct 共用 sampling、retention 与 source revision 状态。

## 安全与隐私

字节失败只输出计数和上限，不输出 body、path 或 canonical 摘要。consumer revision 不是安全令牌；不得
用于跨 appInstance 复用、授权或身份判断。

## 验证

- 单元/协议测试：单份边界 ±1、总字节双淘汰、计数/字节同时触发、超限不污染 latest、淘汰后的 diff、
  sampling failure 重试、并发 1/10/100 caller 只调用 source 一次。
- versioned source：same/increase/regress、appInstance 重建、同 revision 不触碰新 body、legacy adapter。
- VM/direct：相同 retention/revision metadata；direct response 上限另有正负用例。
- 接入方/真机：example 记录典型与最大 snapshot 分布；默认值接受前至少提供两类树规模的 profile 数据。
- 失败注入：source hang/throw、flight owner 取消等待、超限、revision 回退，不遗留未完成 flight 或负字节计数。

## 待裁决

- 接受推荐的 1 MiB 单份、8 MiB 总量、32 份默认，还是以基准调整？
- `revisionSource: consumerReported` 是否足以表达信任边界，还是需要另加 capability 供 CLI 分支？
- versioned source 的 revision 前进但 canonical 相同，是否递增 host snapshotRevision（本稿建议递增，忠实于
  provider 的内容提交事实）？

## 被否决方案

- 只按 revision 数保留：无法限制大 body 的 retained memory。
- 只存 sha256 不存 canonical/body：diff 仍需要冻结 body，hash 也不能免除首次遍历。
- 给既有 `PatchbaySnapshotSource` 增加参数或改变返回类型：这是破坏式公共 API。
- 把所有 wait 合成一个响应 Future：path、condition 与 deadline 不同，合并会串改调用方语义。
- 定时后台 polling：空闲 App 也会持续工作，且没有调用方预算承担成本。
