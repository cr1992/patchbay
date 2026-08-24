# 0.5.0 Snapshot provider JSON 边界与冻结读视图

> 状态：提案中
>
> 关联：PB-050-01
>
> 设计闸门：无

## 问题

`HostSnapshotHandler.readSnapshot` 只捕获 `PatchbaySnapshotSource` Future 自己抛出的异常；随后执行的
`patchbayCanonicalJson(declared)` 在 `try` 外。source 返回 `DateTime`、自定义对象、非字符串 map key、
循环引用或极深结构时，canonical/JSON 编码可以直接抛出，循环或深结构还可能以 `StackOverflowError`
越过普通 RPC 失败边界。现有 canonical helper 的“不因 digest 打挂 host”承诺因此没有兑现。

有效路径也存在两个事实视图：revision 保存的是 canonical 后解码出的深副本，普通 snapshot 响应与 selector
读取的却是 consumer 返回的 `declared` 活对象。source 在返回后继续修改同一个 map 时，revision/diff 与
本次响应可能观察到不同内容。

## 目标与非目标

### 目标

- source 调用、JSON 结构验证、冻结和 canonical 化全部落在同一个 provider 边界内，任何 consumer 数据
  都不能以未捕获异常或栈溢出结束 host 请求。
- 有效 snapshot 使用一次冻结、保持对象插入顺序的 JSON 读视图驱动响应、selection、revision 与 diff，
  不再保留 consumer 活对象。
- 对 0.4.1 已经合法的 string-key JSON，字段顺序、值、revision/diff 与稳定元数据不变。
- VM Service 与 direct 对同一 provider 失败给出同一拒绝信封。

### 非目标

- 本提案不增加 snapshot 单份/总字节预算、retention 字节淘汰、single-flight 或 consumer revision；见
  [Snapshot 资源与 revision](snapshot-resources-revisions.md)。
- 不用现有 canonical 排序副本直接替换响应 body；这会改变对象 key 顺序。
- 不接受非字符串 map key 并以 `toString()` 猜测 wire key；Dart 对象可 stringify 不等于它是 JSON。
- 不改变 selector 路径、poll cadence、`snapshotRevisionUnavailable` 或 diff 预算。

## 契约

`PatchbaySnapshotSource` 的公开签名不变，仍返回 `Future<Map<String, Object?>>`。从 0.5.0 起，其返回图必须
是严格 JSON 值：`null`、bool、有限 JSON number、String、string-key map 与由这些值组成的 list。

host 先构造保持原始 map/list 迭代顺序的独立冻结副本，再从该副本生成 canonical 字符串。冻结副本同时
作为 response body、selector 输入和 `PatchbaySnapshotRevision.body`；canonical 只负责相等比较与字节
计量，不决定响应 key 顺序。共享但无环的容器允许出现两次，冻结后成为两个独立 JSON 子树。

provider 违规继续使用既有 `providerProtocolViolation` rejection，不新增顶层信封或 schema 版本：

```json
{
  "reason": "snapshotPayloadInvalid",
  "failure": "unsupportedType | nonStringKey | nonFiniteNumber | cycleDetected | nestingTooDeep",
  "path": "$.example[0]"
}
```

`path` 只含对象 key/数组 index，不含值；无法安全表示的 key 只报告其父路径。source Future 自己抛错仍用
既有 `reason: snapshotSourceFailed` 与异常类型，不回显异常 message 或 provider payload。

## 状态、失败与预算

一次采样只有三个内部阶段：`source pending -> validating/freezing -> committed | rejected`。只有 committed
结果可以比较 canonical、递增 revision 或进入 retention；rejected 结果不得改变 latest、revision 序号或
淘汰窗口。

验证必须是显式有界、不会依赖 Dart 调用栈深度的遍历。0.5.0 将最大容器嵌套深度冻结为 128：根 map
深度为 0，每进入一个 map/list 加 1，超过 128 拒绝 `nestingTooDeep`。这是避免 stack overflow 的安全边界，
不是 PB-050-02 的字节/retention 预算。实现可以使用 identity ancestry set 检测活动路径循环；节点离开
当前路径后必须移除，避免把共享无环子树误报为 cycle。

冻结或 canonical 编码的内部错误统一收敛成 `snapshotPayloadInvalid`；只有进程级不可恢复错误不在普通
provider failure 契约内。不得先修改 revision 再尝试编码。

## 兼容与降级

- 新 host + 老 CLI：rejection 仍是 0.4.1 已认识的 `providerProtocolViolation`；新增 details 值按自由字段
  松读，不要求新 capability。
- 老 host + 新 CLI：维持旧行为；CLI 不能从失败形态猜 host 是否有安全验证。
- 老 source + 新 host：严格 JSON 返回值逐字节兼容；过去依赖非字符串 key/stringify 的 source 被明确
  判为 provider 违规，因为它本来就不能可靠穿过 JSON transport。
- VM/direct 共用 `HostSnapshotHandler`，不得在 transport 层各自补 try/catch 形成不同 failure。

## 安全与隐私

拒绝 details 只报告 failure、结构 path 与运行时类型名，不包含标量值、对象 `toString()`、异常 message
或 canonical 片段。冻结副本切断 consumer 后续 mutation 对审计、diff 和响应序列化的竞态。

## 验证

- 单元/协议测试：合法 primitives/嵌套结构、插入顺序 golden、source 返回后 mutation、非字符串 key、
  `NaN`/infinity、自定义对象、直接/间接 cycle、共享无环子树、深度 128/129。
- VM/direct：同一失败的 code/details 一致；有效响应由复刻 0.4.1 reader 读取。
- 接入方/真机：不需要业务真机；example debug 主链补一个合法 snapshot 回归即可。
- 失败注入：canonical helper 与冻结器注入异常时不递增 revision、不淘汰 baseline、不泄漏 payload。

## 待裁决

无。评审只需确认本提案对“0.4.1 合法 JSON”的定义与 key 顺序兼容，没有产品策略选择。

## 被否决方案

- 只把 `patchbayCanonicalJson` 移进现有 `try`：能截住普通编码异常，截不住递归栈溢出，也不解决活对象
  与 revision body 两个事实视图。
- 直接返回当前 `revision.body`：该 body 来自 canonical JSON，key 已排序，会改变稳定输出。
- 对 map key 调 `toString()`：可能碰用户代码、产生碰撞，也把非 JSON 数据伪装成合法 JSON。
- 用 `jsonEncode/jsonDecode` 单独深拷贝后再 canonical：仍依赖递归 encoder，且错误路径无法稳定分类。
