# 0.5.0 锚定式合成 tap

> 状态：提案中
>
> 关联：PB-050-15
>
> 设计闸门：DG-050-08

## 问题

0.4.0 的锚定式手势家族只落了 `ui.gesture.pressHold|drag|fling` 三条，最常用的点按反而缺位。
调用方想要“真的按一下”时只有两个选择，两个都不对：

- 用 `ui.semantics.tap`。它走 `SemanticsOwner.performAction`，只证明**框架派发了一次无障碍动作**。
  目标被非模态层盖住时它照样派发成功——因为 Semantics 树上那个节点还在，遮挡它的东西不在这条
  通道上。这正是 PB-050-16 要单独修的那个失败面；在它落地之前，`ui.semantics.tap` 的“成功”和
  “用户真能点到”之间没有关系。
- 用 `ui.gesture.pressHold` 把 `durationMs` 调小冒充点按。这会得到一个语义不确定的调用：
  `durationMs` 合法范围是 `1..30000`，跨过 Flutter 的 `kLongPressTimeout` 之后同一条命令就变成长按，
  而调用方从命令名上看不出自己踩在哪一侧。用“把参数调小”表达“换一种手势”，是把语义藏进数值里。

缺的不是一个便利方法，是**指针通道上的点按**：它经过真实 hit-test，因此“派发成功”与“用户能点到”
是同一件事；它经过 `GestureBinding`，因此 `GestureDetector`、`InkWell`、手势竞技场和按压态都按
真实路径生效。

## 目标与非目标

### 目标

- 在 gesture 家族内新增 `ui.gesture.tap`：identifier 锚定，可选目标内相对比例偏移，注入真
  `PointerDownEvent` / `PointerUpEvent`，异常路径补 `PointerCancelEvent`。
- 完整复用既有 gesture 准入管线：解析 → 基础门 → policy → 声明门 → 门后二次 resolve/policy 比对 →
  逐点 clip/hit-test 准入 → 注入。不为 tap 开任何旁路。
- 冻结 tap 与 `pressHold` 的语义边界：tap 的按压时长上限严格低于长按识别阈值，越界如实拒绝，而不是
  静默滑向长按。
- `ui.semantics.tap` 的 wire、CLI、payload 与失败码逐字节不变；两条路径并存，选择指引进 help 与文档。
- 零新增稳定错误码。

### 非目标

- 不实现双击、多点、hover、右键或任何组合手势。它们各自有独立的识别预算和竞技场语义，不搭本条便车。
- 不弃用、不改写、不在本条内收紧 `ui.semantics.tap`。点性 Semantics action 的遮挡复核属于
  PB-050-16，两者独立回退。
- 不引入绝对屏幕坐标入口。比例偏移只在锚定目标边界内合法，换算后的全局坐标仍不进 payload、日志、
  审计与轨迹（DG-040-01 红线）。
- 不做 tap 后的自动等待、自动重试或“点了没反应就再点一次”。等待仍由 `ui.wait` 表达。
- 不改动既有三条 gesture 命令的参数形状、默认值与 payload。

## 契约

新增 service command `ui.gesture.tap`，plane `flutterUi`，mode `immediate`，sideEffect `appState`，
factSources `{uiObserved}`——四项与既有三条 gesture 命令完全一致。

wire 参数：

| 参数 | 类型 | 必填 | 默认 | 说明 |
|---|---|---:|---|---|
| `identifier` | string | 是 | — | 非空 Flutter Semantics identifier，与既有 gesture 家族同一身份域 |
| `start` | json | 否 | `{"x":0.5,"y":0.5}` | 目标边界内归一化点，各轴 `[0,1]`，只允许 `x`/`y` 两个 key |
| `durationMs` | integer | 否 | `50` | down→up 间隔，合法范围 `1..200` |
| `generation` | integer | 否 | — | 非负；调用方从先前观察取得的前置围栏 |

registration 与既有三条一样设置 `strictKeys: true` 与 `includeReason: true`；允许的 key 只有上表四个，
任何额外 key 在进入 bridge 与 policy 之前按现有 unknown-field 形状拒绝。

三处形状选择需要说明理由，因为它们各自都有一个看起来更“对称”的替代：

**`start` 沿用既有 key 名并可选。** 它在既有三条里是必填的路径起点；在 tap 里没有路径，它就是唯一
那个点。仍叫 `start` 换来两件事：CLI 不需要新增第五个手势 option（`--start` 已在 parser 与 friendly
option allowlist 中），decoder 的 key 集合与既有 `_decodeGesture` 同构。默认值是**目标中心**，并写进
descriptor 的 `default` 字段而不是只写在文档里——catalog 是调用方唯一读得到的声明面，默认值藏在
实现里等于没有声明。canonical JSON 对 map 递归排序，object 默认值不会让 digest 不稳定。

**`durationMs` 沿用既有 key 名，但上限是另一个数。** 家族里三条命令的 `durationMs` 已经各有默认值
（500 / 300 / 100），再加一条默认 50 不制造新的不一致。真正的新东西是上限：**`200`，严格低于 Flutter
`kLongPressTimeout`（500 ms），并留出约 300 ms 的调度抖动余量**。`LongPressGestureRecognizer` 用真实
时钟的 timer 判定长按，不是用合成事件的 `timeStamp`，所以余量必须按真实调度留，不能按名义值卡在
499。这条上限是**语义边界**：tap 不是“时长更短的 pressHold”，而是“保证不会被长按识别器认走的那一
档”。要长按就用 `ui.gesture.pressHold`，那是它存在的理由。

**`generation` 可选。** 这一条与 [0.4.0 锚定式手势](../0.4.0/anchored-gestures.md) 判例不同，那里三条
写手势的 `generation` 是必填的，理由是“fling 甩出后没有第二次确认的机会”。tap 不在那个风险档：它
没有惯性、没有路径、没有跨帧位移，错点一次的后果与 `ui.semantics.tap` 错点一次同级。而
`ui.semantics.tap` 的 `generation` 本来就是可选的——如果 tap 的指针版反而必填，就等于告诉调用方
“想要防误击的那条路径，请先多做一次全树 dump”，而防误击恰恰是裁决记录里指定它为首选的原因。
省略不等于不检查：第一次唯一解析得到的 generation 会被 pin，随后传入门后第二次解析，围栏一格不少。
这一条列入待裁决。

### CLI 面

canonical path 只有一条，不发布 alias：

```console
$ patchbay ui gesture tap <identifier>
$ patchbay ui gesture tap <identifier> --start '{"x":0.5,"y":0.5}'
$ patchbay ui gesture tap <identifier> --duration-ms 50 --generation 12
```

`identifier` 是唯一位置参数；`start` / `durationMs` / `generation` 都是 per-command option，分别映射到
已存在的 `--start`、`--duration-ms`、`--generation`。**不新增任何 CLI option**，
`command_parser.dart` 与 friendly option allowlist 不变。

既有三条 gesture 命令的位置参数是 `<identifier> <generation>`；tap 因为 `generation` 可选而把它移到
option 位，与 `ui tap <identifier> --generation <n>` 的形状对齐。这是家族内的一处不齐，代价换来
的是与它真正的对照物（`ui.semantics.tap`）齐。

help 必须承载选择指引，因为 `ui tap` 与 `ui gesture tap` 在命令行上只差两个词，而它们是两条通道：

- `ui gesture tap` 的 summary：`Tap an anchored target through the real pointer pipeline.`
- `ui tap` 的现有 summary 不变，help 正文补一句指向 `ui gesture tap`，说明它经过 hit-test；
- 两条 help 都写明：**默认用 `ui gesture tap`；只有目标不接收指针（自定义无障碍 action、
  平台视图代理、测试专用 Semantics 节点）时才用 `ui tap`。**

### 与 `ui.semantics.tap` 的并存语义

| 维度 | `ui.gesture.tap`（本条） | `ui.semantics.tap`（不变） |
|---|---|---|
| 通道 | `GestureBinding.handlePointerEvent`，合成 PointerEvent | `SemanticsOwner.performAction` |
| 证明什么 | 框架收到了落在目标上的完整指针序列 | 框架派发了一次无障碍 action |
| 目标要求 | 目标在当前 hit-test 中可达 | 目标声明了 `tap` action |
| 遮挡 | 逐点 clip + hit-test 复核，被盖住即 `uiGestureTargetObscured` | 本版由 PB-050-16 单独收紧，本条不动 |
| 生效对象 | `GestureDetector` / `InkWell` / 竞技场 / 按压态 | 已声明 `onTap` 语义的 widget（含无指针命中的） |
| policy | `PatchbayGesturePolicy` | `PatchbaySemanticsActionPolicy` |
| generation | 可选，内部 pin + 门后复核 | 可选，内部 pin + 门后复核 |
| 定位精度 | 目标框内可选比例偏移 | 整个节点，无点位概念 |
| 缺 policy 时 | 不进 catalog | 不进 catalog |

**两条路径都不证明业务成功。** 差别在“它证明的那一点”是否包含“用户真能点到”：指针路径包含，
Semantics 路径不包含。所以指针路径是防误击首选，Semantics 路径是它打不到时的补集，而不是它的
简写。两个 policy 独立也意味着：只注入了 action policy 的接入方升级 package 之后不会凭空获得合成
指针能力，反之亦然。

### codegen 与注册表影响面（只声明，不在本提案执行）

实现 MR 需要触及、且必须一次改齐的面：

1. `packages/patchbay/lib/src/ui_protocol_commands.dart`：新增 `patchbayUiGestureTapCommandDescriptor`。
   现有 `_gesture(...)` 辅助函数把 `identifier`/`generation` 硬编码成必填位置参数，tap 用不了它原样；
   实现应给 `_gesture` 加一个显式的 generation 形状开关，或让 tap 走独立声明——**不允许**为了复用
   helper 而把 generation 改回必填，也不允许把 helper 改成会连带改变既有三条 descriptor 字节的形状。
2. `packages/patchbay_cli/tool/protocol_cli_codegen.dart` 重新生成
   `packages/patchbay_cli/lib/src/generated/protocol_cli_commands.g.dart`：新增
   `_uiGestureTapProtocolCommand` 及注册表条目。生成文件不手改。
3. `packages/patchbay_flutter/lib/src/flutter_service_host.dart`：`_uiCommandDescriptors` 列表加一项、
   新增一条 `_uiRegistration`（`strictKeys: true`、`includeReason: true`、`available: bridge.gesture.enabled`）、
   `_decodeGesture` 的 key 集合按 kind 放行 tap 的四个 key，并把 `start` 从必填改为按 kind 可选。
4. `packages/patchbay_flutter/lib/src/gesture/gesture_models.dart`：`PatchbayGestureKind` **追加**
   `tap`（追加到枚举末尾，不插队，保既有值的 index 不变）；`_dispatchedPoints` 增加
   `PatchbayGestureKind.tap => <GesturePoint>[start]` 分支。
5. `packages/patchbay_flutter/lib/src/gesture/gesture_bridge.dart`：新增公共入口 `tap(...)`，`_run` 的
   `generation` 参数放宽为可空并引入 pin，`_inject` 增加 tap 分支。
6. `tool/api_surface.json`：新增 descriptor 符号与枚举值，按 golden 更新。
7. 文档：`packages/patchbay_flutter/doc/ui-inspection-and-actions.md` 的“CLI 面”与选择指引、四包
   README 中英双语的手势段落、`changelog.d/0.5.0/` 下本 MR 独占的碎片。
8. **wire contract 不动。** gesture 家族的参数全部走 descriptor 的 `json` 参数类型，
   `packages/patchbay/contracts/core_wire.json` 里从来没有 gesture 专属类型；tap 按同形状声明，即
   **不新增 wire type、不给 `PatchbayUiTargetDescriptorWire` 加字段**，`test/golden/wire_surface.json`
   保持不变。catalog digest 只因 command 集合变化而变化，`covers: [commands]` 不变。

## 状态、失败与预算

### 准入管线

一次 `ui.gesture.tap` 的状态固定为下列顺序，任何一步失败都在注入开始前返回 `admission: rejected`：

1. **参数校验**：`identifier` 非空、`generation` 缺省或非负、`start` 只含数值 `x`/`y`；形状不合法即
   `invalidUiArguments`。
2. **边界校验**：`start` 两轴落在 `[0,1]` 之外即 `uiGesturePointOutOfBounds`；`durationMs` 不在
   `1..200` 即 `uiGestureBudgetExceeded`。
3. **能力与生命周期**：未注入 `PatchbayGesturePolicy` 即 `uiGesturesDisabled`（catalog 层面该命令根本
   不出现，这条兜住直调）；App 非 `resumed` 即 `uiLifecycleNotResumed`，details 带既有 lifecycle 快照。
4. **第一次 resolve**：按 identifier 遍历当前 Semantics 树，零命中 `uiTargetNotFound`，多命中
   `uiTargetAmbiguous`（不按树顺序选）。**若调用方给了 `generation`，在这一步就核对**，不一致即
   `uiGenerationStale`；随后把本次观察到的 generation **pin** 下来。
5. **基础门** → 再查 lifecycle。
6. **policy 第一次求值**：`policy(target, PatchbayGestureKind.tap)`；拒绝即返回 policy 自带的
   `rejectionCode`（默认 `uiGestureDenied`）与 notice；预算不合法或被收紧到低于本次调用即
   `uiGestureBudgetExceeded`。
7. **声明门**（policy 返回的 `gateIds`）→ 再查 lifecycle。
8. **门后二次 resolve**：按同一 identifier 重新解析，并核对 **pinned generation**；换代/歧义/消失即
   按第 4 步同一套码拒绝。
9. **policy 第二次求值并逐字段比对**：allowed、rejectionCode、rejectionNotice、gateIds、三项预算中
   任一项漂移即 `uiGesturePolicyChanged`。
10. **几何解析**：节点 invisible / user actions blocked / 找不到对应 view 或 render anchor / 边界为空或
    非有限，均 `uiGestureTargetObscured`，details 带既有 `reason` 值。
11. **逐点准入**：tap 只有一个点。把 `start` 换算成当前 view 的全局点，同时校验
    **paint clip 包含**与 **`hitTestInView` 命中链上溯到目标 render anchor**；不通过即
    `uiGestureTargetObscured`，`details.reason = 'hitTestOrClip'`。这与既有三条是同一段代码，tap 只是
    点数为 1 的退化情形。
12. **注入**（下节）。

第 4 步 pin、第 8 步复核这一对，是本条与 `ui.semantics.tap`、PB-050-10 共享的同一个安全原语：
**省略 caller generation 只省调用方的前置围栏，不省 App 内部的围栏。**

### 注入与取消补偿

注入序列固定为：`PointerDownEvent(position: p)` → 等待 `durationMs` → `PointerUpEvent(position: p)`。

**不发 `PointerMoveEvent`，up 的位置与 down 严格相同。** 这不是省事：任何位移都会进 touch slop 判定
并把这次调用推进拖动/竞技场竞争，那时“它是不是一次 tap”就不再由本命令决定。

注入过程中任何异常：若 down 已经发出，先补一条 `PointerCancelEvent(position: p)`，再把原异常向上抛。
补偿本身失败被吞掉，不覆盖原异常——留一个更准的诊断比留一个更“干净”的堆栈重要。终态因此是
**已受理**：payload `outcome: failed` + `failureType`（只有 `runtimeType`，不含 message），不改写成未受理。
这条与家族既有行为一致：一旦第一个指针事件出门，App 侧就可能已经有状态变化，把它报成“没受理”
是撒谎。

### 终态 payload

与既有三条同形，key 集合完全一致：

| 字段 | `outcome: dispatched` | `outcome: failed` |
|---|---:|---:|
| `outcome`、`source`、`identifier`、`generation`、`gesture` | 必有 | 必有 |
| `layoutChangedDuringGesture` | 必有 | 必有 |
| `failureType` | 不得出现 | 必有 |

`gesture` 固定为 `"tap"`；`source` 固定为 `uiObserved`；`generation` 报**实际使用的 pinned 值**（不是
调用方传的那个可空值），因此该字段在两种 outcome 下都是确定整数。`layoutChangedDuringGesture` 沿用
既有判定：注入后按 identifier + pinned generation 重解析，解析失败或全局矩形变化即 `true`。tap 时长短，
这一位通常为 `false`；保留它是为了让家族的 payload 可以被同一个 reader 处理。

**换算后的全局坐标不出现在 payload、日志、审计事件与 Debug Trace 中。** 轨迹里 `ui.gesture.tap` 只留
identifier、generation 与归一化 `start`。

### 稳定失败码

全部复用，**零新增**：

| code | 触发 |
|---|---|
| `commandNotRegistered` | 接入方未注入 gesture policy，命令不在 catalog |
| `invalidUiArguments` | identifier 空、generation 负、`start` 形状非法、未知 key |
| `uiGesturePointOutOfBounds` | `start` 越出 `[0,1]` |
| `uiGestureBudgetExceeded` | `durationMs` 越出 `1..200`，或 policy 预算不合法/被收紧到低于本次调用 |
| `uiGesturesDisabled` | release 构建或 policy 缺席时的直调兜底 |
| `uiLifecycleNotResumed` | App 非 resumed（三个检查点任一） |
| `uiTargetNotFound` / `uiTargetAmbiguous` | identifier 零命中 / 多命中（两次 resolve 共用） |
| `uiGenerationStale` | 显式 generation 与首解析不符，或 pinned generation 在门后换代 |
| `uiGesturePolicyChanged` | 门后 policy 决定与首次不一致 |
| `uiGestureTargetObscured` | 几何不可解析，或 clip/hit-test 逐点准入不通过 |
| policy / gate 自带 code | `uiGestureDenied` 默认值，或接入方 gate 返回的 code |

`uiGestureTargetObscured` 与 PB-050-16 的点性 Semantics 遮挡拒绝**不是同一个码**，也不合并：一个说
“指针打不到”，一个说“无障碍动作被非模态层覆盖”，混成一个码会让调用方分不清该换通道还是该
先 reveal。两条命令可以在同一次巡检里先后出现，轨迹要能看出先后。

### 执行证据分类映射

`ui.gesture.tap` 是 protocol-owned 即时 UI 命令，**不产出 `execution` 对象**——那套
`notSent/sentUnconfirmed/unchanged/deviceConfirmed` 分类属于需要表达设备执行结果的领域命令
（`mode: job`），本条既不发往设备也不承诺确认预算。

映射到 [0.4.0 命令契约](../0.4.0/command-contracts.md) 的词表，供脚本对齐口径：

- `outcome: dispatched` 的证据强度对应 **`sentUnconfirmed`**，factSource `uiObserved`：指针序列确实
  进入了 `GestureBinding`，但没有任何设备或业务事实被确认；
- `outcome: failed` **不映射到 `notSent`**：down 已经出门，序列只是没走完，App 侧可能已有状态变化。
  它是一次“已发出但未完成”的注入，既不能报成功也不能报“没发生”——这正是它留在“已受理 + failed”
  而不是“未受理”的原因；
- 0.4.0 的既有约束继续成立：**`uiObserved` 不能把执行分类升级为 `deviceConfirmed`。** 业务完成仍需
  `snapshot`、`navigation`、`ui.wait` 或 `capture` 另行取证。

### 预算

本命令不引入新的 timer、retry 或独立 deadline。一次调用最多两次 identifier 遍历（与
`ui.semantics.tap` 同）、一次 hit-test、一个 `durationMs ≤ 200 ms` 的延时，整体受 host invocation
deadline 约束。若 PB-050-07 接受统一的 identifier traversal/index 预算，本命令与 `ui.semantics.tap`、
PB-050-10 必须同时切换，不能只让其中一条拥有不同的选择边界。

## 兼容与降级

- **老 CLI + 新 host**：catalog 只多一条 command 条目，`PatchbayCommandDescriptorWire` 字段集不变，
  0.4.1 复刻 reader 严格解码仍通过。老 CLI 没有 `ui gesture tap` 的 friendly path，但可经 raw
  `invoke ui.gesture.tap` 调用。
- **新 CLI + 老 host**：catalog 无该 descriptor 时类型化报告 command unavailable。**不降级**：不改发
  `ui.semantics.tap`，不改发 `ui.gesture.pressHold --duration-ms 50`，不退回坐标。降级会把“这台 host
  没有指针 tap”悄悄换成“这次点击没经过 hit-test”，而两者的证据强度不同。
- **VM Service ↔ direct**：共享同一 registration、decoder 与 Flutter bridge，transport 不参与 identifier
  解析、generation 策略或 hit-test。同一请求返回相同 schemaMode、稳定 code、requestId 与 payload。
- **既有命令不变**：`ui.semantics.tap` 与 `ui.gesture.pressHold|drag|fling` 的 wire、CLI、默认值、payload
  与失败码逐字节不变。catalog digest 因 command 集合变化而变化，`covers: [commands]` 不变。
- **Dart source 层面有一处可见变化**：`PatchbayGestureKind` 新增 `tap`。写了穷尽 `switch` 的接入方会拿到
  分析器错误——这是 fail-closed 的正确形态，编译期就逼他们对新 kind 做决定。写了 `default` 分支的接入方
  则会由既有默认分支替 tap 做决定。这条风险**比给 Semantics action 枚举加值小一档**，因为整个 gesture
  家族在没有 gesture policy 时根本不进 catalog：受影响的只可能是**已经**允许合成 pressHold/drag/fling
  的接入方，而 tap 严格弱于这三者。即便如此，发布说明必须显式列出这条枚举变化与建议的复核动作，
  不能让它混在“新增命令”里过去。
- 枚举值**追加在末尾**，不插队，既有值的 `index` 不变；payload 用 `kind.name` 而非 index。

### 实施顺序与回退边界

- 按 [0.5.0 版本计划](../../releases/0.5.0.md) M6：在 PB-050-10 合入后实现本条，复用其受理形状与
  gesture 逐点 hit-test 管线；本条不阻塞 M2→M4 的 P0 收口。
- 与 PB-050-16 共享遮挡判定基建但**不共享 code、不共享 MR**。两条都改 UI 写路径，实现上先后串行，
  不并行拼两套 resolve。
- 回退边界：本条整体独立回退，回退后 `ui.semantics.tap` 与既有 gesture 三命令**一行不动**——这与版本
  计划的回退边界一致。回退 `ui.gesture.tap` 不得连带回退 PB-050-16 的 repro 测试。
- 若实现阶段发现 `PatchbayGestureKind` 追加值对已知接入方造成不可接受的 source break，正确处置是
  **停下来重新裁决 DG-050-08**，不是把 tap 挪出 gesture 家族或私自加一个 `unknown` 兜底值。

## 安全与隐私

- identifier 是声明式稳定身份，不得以 label、value、树路径或节点顺序兜底；歧义一律拒绝。
- 比例偏移只在**已锚定目标的边界内**合法，且必须落在 `[0,1]`。换算后的全局坐标是单次调用内的瞬时
  实现细节，不进 payload、目录、日志、审计与轨迹。这是「不做坐标定位」红线在本版唯一会被侵蚀的地方
  ——一旦全局坐标被持久化，任何回放能力都天然有了一个绝对坐标入口。
- 本命令**不接收任何文本**，因此不涉及 stdin provenance、sensitive input 与脱敏；`start` 与 `durationMs`
  都是无隐私含义的数值，可以原样进 details。
- 未注入 gesture policy 即命令不进 catalog，与 action policy 缺席时 Semantics 动作不进目录同构；升级
  package 不会替接入方默认放行。
- release 构建继续由既有编译期裁除边界控制（`enabled` 已含 `!kReleaseMode`），不因新增 public method
  在 release 里保留 host 或 policy。
- 遮挡拒绝的 details 沿用既有封闭 `reason` 值，不得泄露被遮挡层的 label 或内容，也不得成为绕过快照
  节点上限的第二个观察面。

## 验证

- **单元/协议测试**：
  - descriptor 冻结：name、plane、mode、sideEffect、factSources、四个参数的 required/type/默认值、
    CLI path `['ui','gesture','tap']`、恰好一条 cliSyntax；
  - `start` 默认值以 object 形式出现在 catalog，且 canonical/digest 稳定可复现；
  - unknown key、`start` 多余 key、非数值 `x`/`y`、负 generation 在进入 bridge/policy 前稳定拒绝；
  - `durationMs` 边界：`0`、`1`、`200`、`201` 四点，其中 `201` 必须 `uiGestureBudgetExceeded` 而不是
    被 clamp；
  - CLI 注册表对拍：`ui gesture tap` 可解析、help 含选择指引、未新增 CLI option；
  - 公共 API golden 与 `wire_surface.json` 按预期分别“变”和“不变”。
- **widget 测试矩阵**：
  - *可达*：普通按钮 → `outcome: dispatched`，`GestureDetector.onTap` 实际触发；默认 `start` 命中中心；
    显式 `start` 命中偏移点（用两个相邻子按钮区分左右半边）；
  - *遮挡*：非模态 overlay 覆盖目标 → `uiGestureTargetObscured` + `reason: hitTestOrClip`，且
    `onTap` **未**触发；滚动裁剪出视口的目标同样拒绝；
  - *误拒回归*：custom paint、`HitTestBehavior.translucent`、不拦截指针的 `IgnorePointer` 装饰层三种
    合法用法不得被误拒（沿用 0.4.0 遮挡可行性结论的同一组用例）；
  - *gate 漂移*：声明门 await 期间 policy 改变 `gateIds`/预算/决定 → `uiGesturePolicyChanged`，
    且没有任何指针事件发出；
  - *generation 换代*：首解析后、门 await 中目标重挂载 → `uiGenerationStale`；显式 generation 与首解析
    不符 → 在第一次 resolve 即 stale；省略 generation 时可选中受理时唯一挂载的实例，但换代后必须拒绝；
    禁止任何自动重试；
  - *歧义*：同 identifier 两个 mounted 节点 → `uiTargetAmbiguous`，不按树顺序选；
  - *长按边界*：`durationMs` 取上限时，同时挂 `onTap` 与 `onLongPress` 的目标只触发 `onTap`；
  - *与 `ui.semantics.tap` 对照*：同一个被非模态层覆盖的目标，`ui.gesture.tap` 拒绝而
    `ui.semantics.tap` 在本条实现后行为不变（其收紧属 PB-050-16）——这条对照是“指针路径为防误击
    首选”的证据，必须写成断言而不是文档口径；
  - *坐标不外泄*：断言全局坐标不出现在响应 payload、日志与 trace 事件中。
- **VM/direct**：同一矩阵在 VM Service 与 direct 两端各跑一遍，断言 schemaMode、code、requestId 与
  payload 一致；transport 侧无 identifier/hit-test 逻辑。
- **兼容 golden**：0.4.1 复刻 reader 读取含新命令的 catalog；`ui.semantics.tap` 与既有三条 gesture 命令的
  valid/rejection JSON 逐字节不变；新 CLI 对老 host 不做任何降级调用（断言实际发出的 service name）。
- **失败注入**：
  - 注入中途抛错 → 断言先发 `PointerCancelEvent`、再返回已受理 `outcome: failed` + `failureType`，
    且 `failureType` 不含异常 message；
  - `PointerCancelEvent` 派发本身抛错 → 原异常仍是终态依据；
  - 目标在 down 与 up 之间被卸载 → 序列仍完整发出，`layoutChangedDuringGesture: true`，不中途取消；
  - App 在三个 lifecycle 检查点分别转入非 resumed → 各自 `uiLifecycleNotResumed`。
- **接入方/真机**：`tool/example_precheck.sh` 的 debug 主链新增一条锚定 tap（可达 + 遮挡两例），
  `tool/example_profile_smoke.sh` 只验答复形态；Android/iOS 各出一次真机证据，至少覆盖一个真实业务
  控件的按压态生效与一个被固定层覆盖的目标被如实拒绝。example 预检通过不等于业务验收。

## 待裁决

- **`generation` 是否可选？** 本稿建议可选（内部 pin + 门后复核不变），理由见契约小节；代价是 gesture
  家族内部出现两种 generation 形状。反方案是与既有三条一致必填，代价是把防误击首选路径变成两跳。
- **显式 `generation` 是否在第一次 resolve 就核对？** 本稿建议是，与 PB-050-10 对齐。这比既有三条
  （只在门后第二次 resolve 核对）更严，属收紧；但会让家族内部两种核对时机并存。若裁决要求家族
  一致，应把既有三条一并前移，而不是把 tap 放宽——但那会改动既有命令的拒绝时机，需单独裁决。
- **`start` 沿用 key 名，还是改叫 `at`/`offset`？** 本稿建议沿用 `start`：零新增 CLI option、decoder 同构。
  反方是 tap 没有“起点”概念，`start` 读起来别扭。
- **`durationMs` 上限取 200 ms 还是更小？** 本稿建议 200（`kLongPressTimeout` 的 40%）。更小更安全但
  会挡掉某些需要可见按压态的控件；更大则抖动余量不足。
- **是否给 `ui tap` 的 help 加一句反向指引？** 本稿建议加（互相指路，不改 JSON、不改语法）。这会动
  既有命令的 help 文本，虽不属 wire 变更，仍需确认不与 PB-050-09 的 help 治理撞车。

## 被否决方案

- **用 `ui.gesture.pressHold --duration-ms 50` 冒充点按**：语义藏在数值里，跨过 `kLongPressTimeout`
  后同一条命令变成长按而调用方无从察觉；也无法在 descriptor 上声明“这是一次点按”。
- **把 tap 做成 `ui.semantics.tap` 的一个 `mode` 参数**：会给既有 descriptor 加参数并引入联合形状，
  老 reader 的 required 约束与 help 都要改；两条路径的 policy 也不同源，塞进一条命令等于让一个
  policy 决定另一个 policy 的事。
- **弃用 `ui.semantics.tap`**：辅助功能路径能打到指针打不到的目标（自定义 action、平台视图代理、
  测试专用节点）。弃用它等于用“更真实”换掉“更可达”，两者不是同一维度。裁决已明确并存。
- **进 semantics 家族（`ui.semantics.tapPointer` 一类）**：命名会暗示它走 `performAction`，而它恰恰
  不走；policy 归属也会错位。裁决已明确进 gesture 家族。
- **本条顺手给 `ui.semantics.tap` 加遮挡复核**：那是 PB-050-16 的收紧型行为变更，需要先落 repro 失败
  测试并单独冻结可达目标的回归矩阵；夹带进来会让两条的回退互相咬住。
- **在 tap 里支持双击/多点**：双击涉及 `kDoubleTapTimeout` 与竞技场的跨调用状态，多点涉及指针 id
  分配与并发注入预算，都不是“再发一组事件”那么简单。裁决已明确不进本条。
- **tap 失败后自动重试或自动 reveal**：写操作不重放；目标不可达时应由调用方决定是 `ui.reveal`
  （PB-050-17）还是换通道，而不是由命令替它选。
- **在 payload 里回报换算后的全局坐标以便“调试”**：一旦持久化就等于开了绝对坐标入口，红线只剩字面。
- **给 `PatchbayGestureKind` 加 `unknown` 兜底值以规避 source break**：会让接入方的 `switch` 永远
  编译得过，把编译期的 fail-closed 换成运行期的静默放行，方向反了。
