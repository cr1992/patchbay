# 0.5.0 Invocation catalog policy 缓存与失效协议

> 状态：提案中
>
> 关联：PB-050-03
>
> 设计闸门：DG-050-02

## 问题

`HostInvokerHandler` 只要收到非空 arguments，就先 `readCatalog()` 再提取 sensitive 参数和
`plane == flutterUi` 等 policy。一次 catalog read 会枚举动态 UI target、序列化全部 descriptor、对全部
commands 做 canonical JSON 与 digest。高频带参数调用因此反复为整份能力面付费。

直接在 registry 命中时跳过 `readCatalog()` 看似最小，却会破坏已接受的 fail-closed 契约：任一非法命令名、
重名或无效 descriptor 都应使**整份**目录失效，而不是允许“恰好能从 registry 找到”的命令继续执行。
动态 consumer catalog 又可能在两次调用间变化，永久缓存一次成功结果同样会改变当前逐次观察语义。

## 目标与非目标

### 目标

- registry command 的 sensitive/plane/response/execution policy 从构造期 descriptor 读取，不再为字段投影
  重建完整 catalog。
- 目录有效性仍是 invocation 前置条件；任何来源的 invalid/duplicate/drift 不因 cache 命中被绕过。
- 为静态 registry 与动态 catalog 分别定义 revision/失效信号，使重复调用可以证明复用安全。
- catalog endpoint 的稳定 JSON 与 digest 算法不变。

### 非目标

- 不把 catalog 拆成三个对外 endpoint，也不新增 CLI 调用步骤。
- 不扩大 `catalogDigest.covers`；仍严格为 `["commands"]`。
- 不缓存当前挂载的 `uiTargets` 并把它冒充声明能力面。
- 不用固定 TTL 猜目录是否变化。

## 契约

host 内部把一次目录读取拆为两个概念，不改变现有 catalog response：

1. `CatalogValidity`：全部 command 来源合并后的合法性、重名与 contract 校验结果；
2. `CommandPolicyIndex`：按 command name 投影的 sensitive 参数、plane、retry、response schema 与 execution
   contract，来源仍是同一份已验证目录。

registry 自身在构造完成后不可变，内部 revision 固定。动态 catalog source 可选提供单调
`catalogRevision`；相同 revision 承诺 commands 的规范化内容不变。host 的 cache key 至少包含 registry
identity/revision 与动态 source revision；UI target 挂载变化不使 command policy cache 失效，因为
`uiTargets` 不属于 digest commands 覆盖面。

不提供 revision 的 legacy 动态 source 不允许跨 invocation 永久缓存 validity：每次调用仍读取并验证其
commands。它仍可与同一时刻的并发调用共享一个 in-flight read，但 Future settle 后清除。也就是说，
registry policy 的字段投影可以是 O(1)，但 whole-catalog validity 不能凭空省掉。

若动态 source 明确声明 commands 是构造期静态，也可使用一次性 revision 0；该声明是 provider 契约，
不能由 host 根据“最近没变化”推断。

## 状态、失败与预算

cache entry 状态为 `empty -> loading -> valid | invalid`；revision 改变后回到 empty。invalid 结果也只在同一
明确 revision 下缓存，避免坏目录在每次调用重复放大工作；revision 前进后必须重新验证。

in-flight catalog read 只允许一个 owner，等待者共享结果。host dispose 清除 entry；source throw 不生成
可跨 revision 的永久 negative cache。缓存最多保存当前一个 revision 的 validity/index，不做历史 retention。

所有现有失败保持不变：目录不可用仍返回 `providerProtocolViolation`，invocation reason 仍为
`catalogUnavailable`，violations 保持完整列表；unknown command、invalid retry/response/execution contract
的定向失败不降级。新增 revision 回退时使用 `providerProtocolViolation/catalogRevisionRegressed`。

## 兼容与降级

- 现有 catalog source/API 无修改继续工作，只得到 in-flight 合并与 registry policy 投影优化。
- 可选 revision 走 additive source wrapper/constructor，不改变既有 typedef；新 host 不声明时不要求接入方
  升级。
- catalog response、digest、CLI drift 复核和 0.4.1 reader 看到的字节保持不变。
- VM/direct 都通过同一 `HostCatalogHandler`/`HostInvokerHandler` cache；transport 不持有第二份 validity。

## 安全与隐私

cache key 不含参数值、stdin 内容或完整 catalog JSON；只持有内部 revision、结构化 validity 和已脱敏
descriptor policy。invalid details 沿用现有 violation 脱敏规则。

## 验证

- 单元/协议测试：registry-only、legacy dynamic、versioned dynamic、static revision 0、revision increase/
  regress、source throw、并发 read、invalid/duplicate/contract violation negative cache。
- 计数断言：命中 versioned cache 时 UI target 枚举、descriptor `toJson`、canonical 与 sha256 不重复；
  legacy source 仍逐 invocation 校验，但 policy 投影不扫描 catalog 第二遍。
- 兼容：catalog response/digest golden 与 0.4.1 reader 逐字节一致，`covers` 不变。
- VM/direct：同 revision、失效、回退与错误 details 一致。
- 失败注入：cache load 中 source 失败、revision 在并发间前进、invalid revision 后修复，不执行本应被整份
  目录拒绝的 registry 命令。

## 待裁决

- 动态 source revision 采用 additive wrapper，还是把静态/动态命令来源提升为新的 catalog provider 对象？
- legacy 动态 source 是否接受“只做 in-flight 合并、仍逐次读取”的保守收益（本稿建议接受）？
- revision 相同但 source 返回不同 commands 时，是否在 debug 验证模式抽样 canonical 并报 provider 违规，
  还是完全信任契约？

## 被否决方案

- registry 命中即完全不读 catalog：绕过整份目录 invalid/duplicate fail-closed。
- 首次成功后永久缓存 legacy source：动态 consumer catalog 没有失效事实。
- 固定 TTL：时间经过不是目录变化的事实来源，且会制造窗口内陈旧 policy。
- 把 `uiTargets` 纳入 command policy revision/digest：挂载态变化会让声明能力摘要持续抖动。
- 只缓存最终 digest：invocation 需要 sensitive、plane、schema 与 execution contract，digest 不能回答这些
  policy，也不能证明当前动态 source 仍在同一 revision。
