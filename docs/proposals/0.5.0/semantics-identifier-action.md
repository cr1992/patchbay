# 0.5.0 identifier 锚定的通用 Semantics action

> 状态：已接受
>
> 关联：PB-050-10
>
> 设计闸门：DG-050-06

## 问题

`ui.semantics.action` 只能接收最近一次 Semantics tree 返回的 `nodeId + generation`。高变动页面在读取树与
执行动作之间可能换代，调用方只能自行实现“重取树—找节点—重试”；若把 stale 后的重试写成无条件循环，
又可能把原本针对旧实例的写操作落到同 identifier 的新实例。

`ui.semantics.tap` 已有更安全的一步式路径：App 在同一次受理内按 identifier 解析唯一节点、pin generation，
过 policy/gate 后再按同一 generation 复核。问题只在于它固定为 `tap`，不能覆盖现有公开 action allowlist
中的 focus、scroll 与 setText。这里缺的是通用化已有安全原语，不是一个跳过 generation 的“latest”模式。

## 目标与非目标

### 目标

- 为现有公开 Semantics action allowlist 提供 identifier 锚定的一步式命令。
- `generation` 必填（2026-08-25 裁决改判）：调用方前置围栏 + App 内部 pin + 门后二次解析核对同一代际，三道围栏全开。
- 保持 identifier 未命中、歧义、换代、policy/gate、lifecycle 与敏感输入的 fail-closed 语义。
- 旧 nodeId action 与 `ui.semantics.tap` 无修改继续工作，三条路径共享同一 dispatch 安全原语。

### 非目标

- 不接受字符串 `"latest"`，不把 generation 从 integer 扩成联合类型。
- 不在 stale、not found 或 ambiguous 后自动重试，也不重放未确认的写操作。
- 不新增 label、Widget path、树顺序或坐标定位。
- 不借机开放 `PatchbaySemanticsAction` enum 中尚未进入公开 descriptor allowlist 的动作。
- 不改变 PB-050-07 负责的 owner 请帧、identifier index、遍历预算或 `ui.wait` cadence。

## 契约

新增 service command `ui.semantics.actionByIdentifier`。CLI 路径由 DG-050-06 在两个候选中裁决；本稿推荐与
既有 `ui tap` 同处顶层的短路径 `ui action`：

```console
$ patchbay ui action <identifier> <action> [text]
$ patchbay ui action <identifier> <generation> <action> [text]
$ patchbay --stdin ui action <identifier> setText
```

对照候选是 `ui semantics action-by-identifier`。两者只允许选一个 canonical path，不同时发布 alias；无论选择
哪一个，`generation` 都是紧随 `identifier` 的必填位置参数（与 gesture 家族一致），只有 `--stdin` 是全局 flag。

wire 参数：

- `identifier`：必填、非空 string，使用 Flutter Semantics identifier 命名空间；
- `action`：必填 enum，与 0.4.1 `ui.semantics.action` descriptor 的公开 allowlist 完全一致：`tap`、`focus`、
  `scrollUp`、`scrollDown`、`scrollLeft`、`scrollRight`、`setText`；
- `generation`：必填、非负 integer，调用方从先前观察取得的前置围栏（2026-08-25 裁决改判）；
- `text`：仅 `setText` 可带，其他 action 携带即稳定拒绝；
- `inputWasStdin`：沿用现有 CLI provenance marker，调用方不能用普通 JSON 值伪造 stdin 来源。

registration 必须与现有 `ui.semantics.tap` 一样设置 `strictKeys: true`。允许的 argument key 只有
`identifier`、`action`、`generation`、`text`、`inputWasStdin`；任何额外 key 在进入 bridge/policy 前按
现有 unknown-field 失败形状拒绝，不得静默忽略。nodeId `ui.semantics.action` 未启用 strictKeys 的历史行为
不扩散到这条新命令。

`PatchbaySemanticsBridge` 新增 `invokeIdentifier` 公共入口，参数与 wire 同构。`generation` 必填：
首次解析即与调用方值核对（与 PB-050-15 对齐），pin 后传入第二次解析。它先作为调用方前置围栏，
第一次解析不一致即拒绝；一致后仍按同一个值完成门后二次复核。

执行 payload 沿用 `ui.semantics.tap` 和 `ui.semantics.action` 现有的两种不同形状，不得合并字段：

| 字段 | `outcome: dispatched` | `outcome: failed` |
|---|---:|---:|
| `outcome`、`source`、`identifier`、`nodeId`、`generation`、`action` | 必有 | 必有 |
| `beforeTreeRevision`、`afterTreeRevision` | 必有 | 不得出现 |
| `failureType` | 不得出现 | 必有，仅 `runtimeType`，不含异常 message |
| `length` | 仅 setText 必有 | 不得出现 |
| `valueRedacted` | 仅 sensitive setText 为 `true`；普通 setText 不出现 | 不得出现 |

两种 payload 都不得回显 text。`ui.semantics.tap` 保留原 command name、CLI 语法和 JSON，内部可委托
`invokeIdentifier(action: tap)`，但兼容 golden 必须逐字节不变。

## 状态、失败与预算

单次调用状态固定为：

1. 校验 identifier/action/text/provenance；
2. 过基础 gate 与 lifecycle；
3. 按 identifier 解析唯一、可执行节点，并校验可选 caller generation；
4. pin 当前 generation，执行 consumer action policy；
5. 过声明 gate；
6. 按相同 identifier 与 pinned generation 二次解析，重新执行 policy 并核对 gate/sensitive 决策未漂移；
7. 派发 action，等待现有一帧观察并返回执行 payload。

第一次解析之前节点已经换代时，未显式提供 generation 的调用语义是“操作受理时唯一挂载的当前实例”；
一旦第一次解析完成，后续任何 identity/generation 变化都必须 `uiSemanticsGenerationStale`，不能把第二次
解析得到的新实例当成等价目标。

稳定失败沿用现有 code：`invalidUiArguments`、`uiSemanticsActionsDisabled`、`uiLifecycleNotResumed`、
`uiSemanticsUnavailable`、`uiSemanticsIdentifierNotFound`、`uiSemanticsIdentifierAmbiguous`、
`uiSemanticsGenerationStale`、`uiSemanticsActionBlocked`、`uiSemanticsActionUnavailable`、
`uiSemanticsActionDenied`、`uiSemanticsPolicyChanged`、`uiSemanticsTextRequired`、
`uiSemanticsUnexpectedText` 与 `sensitiveInputRequiresStdin`。不新增“重试成功”或“自动换代”结果。

本命令不增加内部 retry、timer 或独立 deadline；一次调用与现有 tap 一样最多执行两次 identifier resolve，
受 host invocation deadline 约束。PB-050-07 若接受统一的 identifier traversal/index 预算，tap 与本命令必须
同时切换，不能只让其中一条拥有不同的选择边界。

## 兼容与降级

- 老 CLI + 新 host：新增 descriptor 只扩展 catalog command 集；旧命令和旧 record 字段不变。
- 新 CLI + 老 host：catalog 无新 descriptor 时类型化报告 command unavailable，不降级为客户端读树后重试，
  也不改发 `ui.semantics.action`。
- `ui.semantics.tap`、nodeId `ui.semantics.action` 的 wire、CLI 与失败码保持原样；catalog digest 因新增命令
  正常变化，`covers: [commands]` 不变。
- VM Service 与 direct 共享同一个 generated decoder、registration 和 Flutter bridge；transport 不实现
  identifier 解析或 generation 策略。
- command 只有在 consumer 提供 semantics action policy 时进入目录；升级 package 不会替接入方默认放行。

## 安全与隐私

identifier 是声明式稳定身份，不得以 label/value 兜底。歧义一律拒绝，不按树顺序选择。consumer policy
在两次解析后都执行，gate IDs 与 sensitiveInput 决策漂移时拒绝；setText 对 obscured node 或 policy 标记的
敏感输入继续只接受 stdin provenance，响应、日志、audit 与 trace 均不保存 text。

release 构建继续由现有编译期裁除边界控制，不因新增 public method 保留 host 或 action policy。动作派发只
证明 Flutter SemanticsOwner 接收调用，不升级为业务状态已改变或设备已确认。

## 验证

- descriptor/codegen/CLI parity：新 command 的 service/CLI 参数、enum、stdin marker 与 help 一致；catalog
  digest 只因 commands 集变化；unknown key 在 bridge/policy 调用前稳定拒绝。
- widget test：七个公开 action 的唯一 identifier 路径；not found、20 条 mounted identifier 截断、重复
  identifier、blocked/unavailable、lifecycle 与 policy deny。
- generation 竞态：第一次解析前替换在无 caller fence 时可选中当前实例；第一次解析后、gate await 中替换
  必须 stale；显式 caller generation 在第一次解析时即可 stale；禁止任何自动重试。
- policy 竞态：二次 policy 的 gate IDs 或 sensitiveInput 漂移稳定 `uiSemanticsPolicyChanged`。
- setText：缺 text、意外 text、普通输入、obscured/policy-sensitive + stdin/non-stdin，所有输出均不含原文。
- 兼容 golden：0.4.1 reader 读取新 catalog；旧 tap/nodeId action 的 valid/rejection JSON 逐字节不变；新 CLI
  对老 host 不做 two-step 降级；新命令的 dispatched/failed 分别按字段表断言 presence 与 absence。
- VM/direct 运行同一矩阵；debug example 覆盖 identifier focus/scroll/setText，接入方真机至少覆盖一个在
  gate await 期间重挂载的目标并证明没有误击新实例。

## 待裁决

（四项均已裁决，见下节；原问题文本保留于版本历史。）

### 裁决结论（2026-08-25，仓主授权代理裁决）

1. **接受独立命令 `ui.semantics.actionByIdentifier`**：参数联合会破坏旧 descriptor 的 required 约束，
   与 anchored-tap 被否决方案同一判例。
2. **CLI canonical path 取 `ui action`**：与 `ui tap` 对称，单 path 无 alias，help 与 nodeId 版互相指路。
3. **`generation` 必填**（推翻本稿「可选」建议）：仓主在 PB-050-15 复核时确立的判例——内部 pin 防不了
   「调用方观察后、命令开始前 identifier 被新节点复用」的窗口；identifier 锚定的写派发一律用最强围栏。
   正文参数表、CLI 语法与 bridge 入口段已按此修订；实现须含「缺 generation 即 invalidParams / CLI
   usage 错误」用例。`ui.semantics.tap` 的既有可选契约不动（另行条目再议统一）。
4. **严格复用既有七项 public allowlist**：不借本条扩 policy 面，与「longPress 不进 allowlist」裁决同向。
## 被否决方案

- `generation: "latest"`：破坏 integer wire 类型，并把“选当前实例”误写成“无需代际围栏”。
- stale 后自动重取并重试：同 identifier 的新实例不是原目标，写操作可能误击或重复执行。
- CLI 先读 tree 再调用旧 action：保留原竞态，无法在一次 App 受理中 pin generation。
- 修改现有 `ui.semantics.action`，让 `nodeId/generation` 与 `identifier` 二选一：旧 descriptor 的 required
  约束会改变，decoder、help 与错误详情都要引入联合形状，兼容收益低于独立命令。
- 把全部 `PatchbaySemanticsAction.values` 直接放进 descriptor：会公开尚未验收的 action，并让既有 consumer
  policy 默认分支替新能力做决定。
