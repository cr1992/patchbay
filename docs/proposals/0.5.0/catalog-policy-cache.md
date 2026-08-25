# 0.5.0 Invocation catalog policy 缓存与失效协议

> 状态：已接受
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

所有 registry/external invocation、无论 arguments 是否为空，都必须先取得有效 `CatalogValidity`；只有参数
字段投影可以在 arguments 为空时跳过。unknown command、registry dispatch 与 external dispatch 都发生在
整份目录通过验证之后，不能保留一条“空参数 registry 命中就不读目录”的旁路。

registry 自身在构造完成后不可变，内部 revision 固定。动态 catalog 可选改用 additive provider 对象，
语义形状为：

```dart
final class PatchbayCatalogSample {
  const PatchbayCatalogSample({
    required this.commandsRevision,
    required this.catalog,
  });

  final int commandsRevision;
  final Map<String, Object?> catalog;
}

abstract interface class PatchbayCatalogProvider {
  int get commandsRevision;
  Future<PatchbayCatalogSample> readCatalog();
}
```

最终命名可按仓内 API 风格微调，但语义不可变：同步 getter 是不枚举 descriptor/UI target、不构造 catalog
JSON 的廉价失效信号；`readCatalog()` 返回的 sample 把该次完整 catalog 与其 commands revision 原子绑定。
revision 在 appInstance 内非负、单调；相同 revision 承诺规范化 `commands` 内容不变。host 以 additive
命名构造入口接收 provider；既有 `PatchbayCatalogSource` 构造入口和 typedef 不变，两种模式在构造期互斥。
Flutter host 对 domain catalog 暴露对应的 additive 入口，动态 `uiTargets` 仍由 Flutter bridge 在显式 catalog
读取时按次枚举，不进入 commands revision。

host 的 cache key 至少包含 registry identity/revision 与动态 provider commands revision。UI target 挂载变化
不使 command policy cache 失效，因为 `uiTargets` 不属于 digest commands 覆盖面。显式 catalog endpoint
仍读取完整 provider sample、拼装当时的动态 UI targets 并生成既有 response；invocation 在 revision 命中时
只复用 commands validity/index，不把缓存的 UI targets 冒充当前挂载态。

不提供 revision 的 legacy 动态 source 不允许跨 invocation 永久缓存 validity：每次调用仍读取并验证其
commands。它仍可与同一时刻的并发调用共享一个 in-flight read，但 Future settle 后清除。也就是说，
registry policy 的字段投影可以是 O(1)，但 whole-catalog validity 不能凭空省掉。

若动态 provider 明确声明 commands 是构造期静态，可固定 revision 0；该声明是 provider 契约，不能由
host 根据“最近没变化”推断。getter 在读取 flight 期间前进不使已返回 sample 失真：host 只提交 sample 自带
的 revision，下一次 invocation 观察到更新 getter 后再加载新 sample；不得把 getter 与另一份 body 自行拼成
一个事实。

## 状态、失败与预算

cache entry 状态为 `empty -> loading -> valid | invalid`；revision 改变后回到 empty。invalid 结果也只在同一
明确 revision 下缓存，避免坏目录在每次调用重复放大工作；revision 前进后必须重新验证。host 记录所有
getter/sample 已观察到的最高 revision；负数使用 `catalogRevisionInvalid`，后续任何更小值使用
`catalogRevisionRegressed`，两者都不替换上一份有效 entry。

in-flight catalog read 只允许一个 owner。观察到相同 revision 的等待者共享结果；在旧 revision flight 尚未
settle 时观察到更高 revision 的调用者先等待该 flight，随后重新读取 getter，不能拿旧结果继续执行，也不
并行启动第二次 provider read。host dispose 清除 entry；getter/read 抛错沿用 `catalogSourceFailed` 与异常类型，
不生成可跨 revision 的永久 negative cache，也不替换已提交 entry。缓存最多保存当前一个 revision 的
validity/index，不做历史 retention，不保留 provider 的可变 catalog map。

所有现有失败保持不变：目录不可用仍返回 `providerProtocolViolation`，invocation reason 仍为
`catalogUnavailable`，violations 保持完整列表；unknown command、invalid retry/response/execution contract
的定向失败不降级。新增非法 revision 使用 `providerProtocolViolation/catalogRevisionInvalid`，回退使用
`providerProtocolViolation/catalogRevisionRegressed`。当 host 在本来就会发生的两次完整读取中观察到相同
revision 的规范化 commands 不同，使用
`providerProtocolViolation/catalogRevisionContentChanged`，并把该 revision 整体转为 invalid，不能继续
使用先前同 revision 的 valid entry 执行命令；不得为了抽样检测而额外调用 provider。

## 兼容与降级

- 现有 catalog source/API 无修改继续工作，只得到 in-flight 合并与 registry policy 投影优化。
- 可选 revision 走 additive provider 对象与命名构造入口，不改变既有 typedef；新 host 不声明时不要求
  接入方升级。
- catalog response、digest、CLI drift 复核和 0.4.1 reader 看到的字节保持不变。
- VM/direct 都通过同一 `HostCatalogHandler`/`HostInvokerHandler` cache；transport 不持有第二份 validity。

## 安全与隐私

cache key 不含参数值、stdin 内容或完整 catalog JSON；只持有内部 revision、结构化 validity 和已脱敏
descriptor policy。invalid details 沿用现有 violation 脱敏规则。

## 验证

- 单元/协议测试：registry-only、legacy dynamic、versioned dynamic、static revision 0、revision negative/
  increase/regress、getter/read throw、并发 read、invalid/duplicate/contract violation negative cache；空参数与
  非空参数的 registry/external invocation 都不得绕过 whole-catalog validity。
- 计数断言：命中 versioned cache 时 UI target 枚举、descriptor `toJson`、canonical 与 sha256 不重复；
  legacy source 仍逐 invocation 校验，但 policy 投影不扫描 catalog 第二遍。
- 兼容：catalog response/digest golden 与 0.4.1 reader 逐字节一致，`covers` 不变。
- VM/direct：同 revision、失效、回退与错误 details 一致。
- 失败注入：cache load 中 source 失败、revision 在并发间前进、invalid revision 后修复、同 revision 内容
  漂移使旧 valid entry 失效，不执行本应被整份目录拒绝的 registry 命令。

## 裁决结果

已接受。动态 commands revision 使用 additive provider 对象，由廉价 getter 提供失效信号、完整 sample 原子
绑定 revision 与 catalog；既有 source 只做 in-flight 合并，settle 后继续逐 invocation 读取。相同 revision
默认信任 provider 契约，不增加 debug 抽样或额外调用；只有显式 catalog 等既有完整读取自然观察到内容漂移
时才返回 `catalogRevisionContentChanged`。commands policy cache 与动态 `uiTargets` 分离，VM/direct 共用同一
份 validity/index 和失效状态。

## 被否决方案

- registry 命中即完全不读 catalog：绕过整份目录 invalid/duplicate fail-closed。
- 首次成功后永久缓存 legacy source：动态 consumer catalog 没有失效事实。
- 固定 TTL：时间经过不是目录变化的事实来源，且会制造窗口内陈旧 policy。
- 把 `uiTargets` 纳入 command policy revision/digest：挂载态变化会让声明能力摘要持续抖动。
- 只缓存最终 digest：invocation 需要 sensitive、plane、schema 与 execution contract，digest 不能回答这些
  policy，也不能证明当前动态 source 仍在同一 revision。
