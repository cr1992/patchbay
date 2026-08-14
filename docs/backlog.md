# 问题与特性台账

> 本仓已确认缺陷与待实现特性的**唯一真源**。新条目随发现进表，带一句动机与证据指针；
> 完成后随发版移入 CHANGELOG 对应版本段并从此处删行。`design-gate` 条目未经仓主裁决
> 不得进入实现 MR。只记结论与指针，不写过程叙事；裁决理由在对应 MR / note。
> 已裁决不做的方向见 [design.md 的非目标台账](design.md)，此处不重复、不重提。

## 缺陷

| 条目 | 动机 / 证据 | 状态 |
|---|---|---|
| CLI 对无应答对端的失败总时长偏离单次超时量级（Android SIGSTOP 实测 178s，期望 ~30s 量级） | 诊断批真机验收发现，评审追问中 | 在途 |

## 特性（待排期）

| 条目 | 动机 / 出处 | 备注 |
|---|---|---|
| 锚定式手势 `ui.gesture.*`：press-hold / drag 路径 / fling，identifier 锚定 + 相对比例坐标 + 代际围栏 | 呼叫线真机验证分工：方向盘按压态、小窗拖动只能 adb 坐标打 | **design-gate** |
| 定时 capture + golden diff：第 N 帧截取、两帧差异率 | 呼叫线：首帧变形取证只能 screencap 关键帧对比（Flutter 自绘部分可收编；OS 合成层不做，见非目标） | |
| 调试台「保持亮屏」开关（Android `FLAG_KEEP_SCREEN_ON` + iOS `isIdleTimerDisabled`，opt-in） | iOS 真机无系统级 stay-awake 命令，app 侧是唯一自动化手段；Android 可 `adb shell svc power stayon usb` 兜底 | |
| 会话粘性：`sessions list/prune`、`session use` | 双设备并连时每条命令显式敲长 `--session` | |
| 领域条件等待与字段选择：`snapshot --path`、`wait --until` | 客户端轮询应变服务端长轮询 | |
| 统一 CommandRegistry：descriptor+decoder+gate+handler+validator 过同一 dispatcher | 第二 consumer 手写 adapter 的元键坑已实证核心不机检 descriptor 语义的风险 | |
| 协议演进套件：serverVersion / feature capabilities / catalog digest / 兼容 golden | 多 consumer 生态前的地基 | |
| 幂等 retryPolicy（external 命令按 requestId 去重）；审计 sink（可注入、记脱敏参数形状）；CLI `describe`/`doctor` | dogfood | |
| DevTools 借用三批：inspect 开关 → perf VM RPC → net 画像 | 规划稿已交仓主 | net 画像 **design-gate**（脱敏评审） |
| snapshot revision / diff | dogfood（低优先级） | |
| UI 目标声明对账 `ui verify-manifest <file>`：consumer 交 expected-targets manifest（id/kind/sensitive/所在屏），CLI 对比 catalog uiTargets + semantics 树，报「声明未挂载 / 挂载未声明 / 属性漂移」三类偏差；可选按 destination 逐屏巡检覆盖非常驻控件 | hirobot 提案（由「标注能否契约生成」review 引出：正向生成不成立，反向机械对账成立）；纯 CLI 侧、wire 零改动；hirobot 自荐首个试点 consumer（已有 ID 台账） | |

## 文档债（快赢，可随任意批次走）

| 条目 | 动机 / 出处 |
|---|---|
| guide「UI 目标标注」节补**标注收敛最佳实践**：有组件库的接入方应把 PatchbayKey/Semantics 收口进自家组件层（组件加 semanticsId 参数 + ID 常量台账），call site 直贴是无组件库时的姿势 | 蔡锐 review hirobot 接入指出散落扩散性差；hirobot MR !35 有参考实现（8 行→1 参数）可引用 |
| 架构总览一页：四包关系图 + 一条请求的完整生命周期（CLI→transport→host→bridge→consumer→回程），新 feature 阶段开工前画 | 新接入方现靠 guide+源码拼；hirobot 全程接入是现成素材 |
| `PatchbayKey` 语义进 patchbay_flutter README/docs：**构造即注册、弱引用出册、仅同时挂载判歧义**；显式写明 **build() 内裸构造会重挂载丢状态**（应在 State 缓存实例）——接入方靠逆向源码才发现的陷阱 | hirobot consumer 实践反馈 |

## design-gate（需仓主裁决后动工）

| 条目 | 裁决点 |
|---|---|
| macOS 桌面 lifecycle 闸判定 | 「失焦但在渲」是否放行：桌面端改帧活性判定、移动端维持 `resumed`（方案 A）；第二 consumer 有复现环境可验证 |
| 锚定式手势 | 相对比例坐标手势与「不做坐标定位」立场的边界划法 |
| DevTools net 画像 | 请求画像的脱敏口径 |

## 维护规则

- 一条一行，动机一句话，证据给指针；不粘贴过程。
- 完成 = 移入 CHANGELOG 对应版本段并删行；放弃 = 移入 design.md 非目标台账并写理由。
- 每次发版前过一遍本表，与 CHANGELOG、兼容矩阵同批核对。
