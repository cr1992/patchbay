# 问题与特性台账

> 本仓已确认缺陷与待实现特性的**唯一真源**。新条目随发现进表，带一句动机与证据指针；
> 完成后随发版移入 CHANGELOG 对应版本段并从此处删行。`design-gate` 条目未经仓主裁决
> 不得进入实现 MR。只记结论与指针，不写过程叙事；裁决理由在对应 MR / note。
> 已裁决不做的方向见 [design.md 的非目标台账](design.md)，此处不重复、不重提。

## 缺陷

| 条目 | 动机 / 证据 | 状态 |
|---|---|---|
| （暂无已知未修缺陷） | | |

## 特性（待排期）

| 条目 | 动机 / 出处 | 备注 |
|---|---|---|
| 锚定式手势 `ui.gesture.*`：press-hold / drag 路径 / fling，identifier 锚定 + 相对比例坐标 + 代际围栏 | 接入方真机验证分工：方向盘按压态、小窗拖动只能 adb 坐标打 | **design-gate** |
| 定时 capture + golden diff：第 N 帧截取、两帧差异率 | 接入方：首帧变形取证只能 screencap 关键帧对比（Flutter 自绘部分可收编；OS 合成层不做，见非目标） | |
| 屏幕唤醒三件套：① CLI 会话建立时 lifecycle 预检横幅（非 resumed 即打显眼警告 + 分平台解法命令）② `patchbay doctor` 体检命令（连接/lifecycle/catalog/会话逐项查、红项给解法）③ 会话活跃期间 app 自动 keep-screen-on（Android `FLAG_KEEP_SCREEN_ON` + iOS `isIdleTimerDisabled`，会话静默自动释放，debug-only） | 真机调试息屏即 UI 面全拒（实测），iOS 无系统级 stay-awake；③ 默认自动还是手动为 **design-gate**（自动会使息屏行为本身的测试失真，需留关闭出口） | ③ design-gate |
| 领域条件等待与字段选择：`snapshot --path`、`wait --until` | 客户端轮询应变服务端长轮询 | |
| 统一 CommandRegistry：descriptor+decoder+gate+handler+validator 过同一 dispatcher | 第二 consumer 手写 adapter 的元键坑已实证核心不机检 descriptor 语义的风险 | |
| 协议演进套件：serverVersion / feature capabilities / catalog digest / 兼容 golden | 多 consumer 生态前的地基 | |
| 幂等 retryPolicy（external 命令按 requestId 去重）；审计 sink（可注入、记脱敏参数形状）；CLI `describe`/`doctor` | dogfood | |
| DevTools 借用三批：inspect 开关 → perf VM RPC → net 画像 | 规划稿已交仓主 | net 画像 **design-gate**（脱敏评审） |
| snapshot revision / diff | dogfood（低优先级） | |
| launcher 监督循环收编：把首个接入方项目级的重连监督（退避策略 + machine-frame 生命周期 + 断连判读）抽为 patchbay_cli 通用 `launch` 能力；会话记录 schema 增显式 pending 状态位（现依赖 consumer 侧以自身 PID 通过探活的巧劲，跨仓契约应显式化） | 首个接入方已落项目级实现并真机验证；第二接入方已集成 session store，其启动器必复踩「断连即退」 | 等首个实现合入烤几天 + 第二试点确认形态 |
| UI 目标声明对账 `ui verify-manifest <file>`：consumer 交 expected-targets manifest（id/kind/sensitive/所在屏），CLI 对比 catalog uiTargets + semantics 树，报「声明未挂载 / 挂载未声明 / 属性漂移」三类偏差；可选按 destination 逐屏巡检覆盖非常驻控件 | 第二接入方提案（由「标注能否契约生成」review 引出：正向生成不成立，反向机械对账成立）；纯 CLI 侧、wire 零改动；该接入方自荐首个试点（已有 ID 台账） | |

## 文档债（快赢，可随任意批次走）

| 条目 | 动机 / 出处 |
|---|---|
| （暂无） | |

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
