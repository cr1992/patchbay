# 0.4.0 Capture、snapshot revision 与 diff

> 状态：已接受
>
> 关联：PB-040-02；snapshot revision/diff 已随 0.4.0 发布，见
> [CHANGELOG.md 0.4.0 段](../../../CHANGELOG.md#040---2026-08-20)
>
> 设计闸门：无

## 问题

首帧变形和状态切换只能手工截关键帧比较；snapshot 没有稳定 revision，调用方无法判断两次读取是否
来自同一状态，也缺少有资源边界的差异表达。

## 目标与非目标

- capture 支持等待第 N 个 Flutter 帧后截取，并计算两张同规格图的差异率。
- snapshot 带会话内单调 revision，可按已知基线请求结构化 diff。
- 每份结果标明 `factSource`、采集时刻、规格和资源上限。
- 不声称覆盖 OS 合成层、系统弹窗、硬件画面或肉眼产品验收。这条边界已经有封闭词表承载——capture
  结果的 `flutterSubtreeOnly`、`platformViewsMayBeMissing`、`systemUiNotIncluded` 三个 warning 就是
  它的机读形式；本提案引用它们，不在散文里另立承诺。

## 契约

- `capture` 参数使用 `afterFrames`，从命令受理后第一帧计数；超预算返回类型化失败。计数的是
  **Patchbay 观测到的帧**——帧观察器会主动请帧，所以这个数字不等于 App 自然渲染的帧序号。取证脚本
  依赖的是"受理后第 N 次观测"，不是"App 的第 N 帧"，文档必须直说。
- diff 只接受相同宽高/像素格式；返回 `changedPixels/totalPixels/differenceRatio`，不默认判定 pass/fail。
  这些数值放在 diff 命令自己的 payload 里，**不挂到 blob metadata 上**——该 wire 类型被已发布客户端
  严格解码，加字段会让它们当场 `FormatException`；确需附着到 artifact 时只能用既有 `properties`。
- `snapshot diff --from <revision>` 返回 added/changed/removed 的封闭结构；基线被淘汰返回
  `snapshotRevisionUnavailable`，不偷偷退回全量。该请求**另起 wire 类型**，不向既有 snapshot 请求
  类型加字段（同样在严格解码名单内）。

### revision 的来源：本版只做 `hostObserved`

snapshot 的数据源是接入方提供的**拉取式回调**，host 没有变更信号可订阅——这也是既有实现要在一次
请求内轮询的原因。所以"每次已提交状态变化递增"在当前架构下无法成立：host 只能在**被读时**比较
相邻两次结果。

本版据此定义：

- revision 是 **Patchbay 在读取时观察到内容变化后递增**的序号，带显式 `revisionSource: hostObserved`；
- 作用域为 appInstance，hot restart 后重新起算；
- 无变化的读取不递增；
- 字段名与文档必须诚实表达"它只在有人读时前进"，否则调用方会把它当成 App 的真实状态提交序号。

**不新增接入方 revision 契约。** 由 consumer 上报真实提交序号在语义上更强，但那会把这个已随 0.4.0
发布的低优先级条目扩成一次接入方 API 改造。留作未来版本的可选增强。

### 与既有 revision 家族的关系

已有 `treeRevision`、`navigationRevision`、`frameRevision`，其中两个还是 `ui.wait` 的条件。新增的叫
`snapshotRevision`，命名与语义都进同一家族，避免出现第五个各说各话的"版本号"。

### 老 host 的降级走 capability，不猜错误形态

老 host 收到不认识的 snapshot 参数会答 `invalidParams`，与 selectors 当年那次是同一类问题。本条目
**必须复用已随 0.4.0 发布的 `snapshotSelectors` capability 声明路线**判定支持情况，不得再从错误形态
反推。

## 预算与安全

每个 appInstance 默认保留最近 32 个 snapshot revision；淘汰后稳定返回 `snapshotRevisionUnavailable`。
capture/diff 沿用现有 capture 桥的上限：单图最多 16,777,216 像素、编码后最多 8 MiB；diff 两侧都必须
满足同一像素上限，不新造一套更大的预算。`afterFrames` 最大 120，等待默认 5 s、最大 30 s。

图片默认作为 artifact 引用传输，不内嵌进普通 JSON。capture 可能包含敏感 UI，沿用 artifact 授权与
清理策略，日志只记录尺寸和摘要。

## 兼容与验证

- capability 缺失时类型化降级为既有即时 capture / 全量 snapshot，输出明确 legacy 模式，判定依据是
  声明而非错误形态。
- golden 覆盖无变化、单像素变化、尺寸不匹配、revision 淘汰和预算耗尽。
- 断言无变化的重复读取不递增 revision，且结果始终带 `revisionSource: hostObserved`。
- 断言 hot restart 后 revision 作用域重新起算，调用方能从 appInstance 变化看出来。
- widget 测试证明 `afterFrames=N` 的计数起点；真机验证首帧和动画中间帧取证。
- VM/direct 对元数据与 diff 数值一致，artifact 传输方式可不同但摘要必须一致。

## 已裁决预算

- revision、像素、编码字节、帧数和等待预算已经在“预算与安全”冻结。

## 被否决方案

- 用 wall-clock 时间戳代替 revision：无法稳定排序同毫秒更新，也不能表达基线淘汰。
- Patchbay 直接给视觉差异判产品 pass/fail：阈值属于接入方验收策略。
- 把 revision 说成 App 的状态提交序号：snapshot 源是拉取式回调，host 没有变更信号，这个承诺兑现
  不了。
- 本版新增接入方 revision 上报契约：把一个低优先级条目扩成接入方 API 改造。
- revision 按 selector 空间分别递增：会让 diff 基线不可比。
- 把 diff 数值挂在 blob metadata 上：该类型被已发布客户端严格解码。
