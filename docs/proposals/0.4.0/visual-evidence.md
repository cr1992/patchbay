# 0.4.0 Capture、snapshot revision 与 diff

> 状态：提案中
>
> 关联：PB-040-02、PB-040-10
>
> 设计闸门：无

## 问题

首帧变形和状态切换只能手工截关键帧比较；snapshot 没有稳定 revision，调用方无法判断两次读取是否
来自同一状态，也缺少有资源边界的差异表达。

## 目标与非目标

- capture 支持等待第 N 个 Flutter 帧后截取，并计算两张同规格图的差异率。
- snapshot 带会话内单调 revision，可按已知基线请求结构化 diff。
- 每份结果标明 `factSource`、采集时刻、规格和资源上限。
- 不声称覆盖 OS 合成层、系统弹窗、硬件画面或肉眼产品验收。

## 契约

- `capture` 参数使用 `afterFrames`，从命令受理后第一帧计数；超预算返回类型化失败。
- diff 只接受相同宽高/像素格式；返回 `changedPixels/totalPixels/differenceRatio`，不默认判定 pass/fail。
- snapshot 每次已提交状态变化递增 revision；无变化读取不得为了请求本身递增。
- `snapshot diff --from <revision>` 返回 added/changed/removed 的封闭结构；基线被淘汰返回
  `snapshotRevisionUnavailable`，不偷偷退回全量。

## 预算与安全

保留 revision 数、单张图片字节数、afterFrames、diff 像素总量和等待时间均有硬上限。图片默认作为
artifact 引用传输，不内嵌进普通 JSON。capture 可能包含敏感 UI，沿用 artifact 授权与清理策略，日志
只记录尺寸和摘要。

## 兼容与验证

- capability 缺失时类型化降级为既有即时 capture / 全量 snapshot，输出明确 legacy 模式。
- golden 覆盖无变化、单像素变化、尺寸不匹配、revision 淘汰和预算耗尽。
- widget 测试证明 `afterFrames=N` 的计数起点；真机验证首帧和动画中间帧取证。
- VM/direct 对元数据与 diff 数值一致，artifact 传输方式可不同但摘要必须一致。

## 待裁决

- revision 由全局 snapshot 递增还是按 selector 空间分别递增。
- 默认保留 revision 数和最大像素预算。

## 被否决方案

- 用 wall-clock 时间戳代替 revision：无法稳定排序同毫秒更新，也不能表达基线淘汰。
- Patchbay 直接给视觉差异判产品 pass/fail：阈值属于接入方验收策略。
