# 验证证据索引

本目录保存可复核的调查、预检、基准和设备验收结论。文件存在不等于能力已经全绿：每份证据都必须同时
阅读“证明范围”和“未证明范围”，阻塞报告、仓内 example 预检、模拟器结果与 consumer 真机事实不得
互相替代。版本退出条件与两段验证顺序见 [规划与交付治理](../planning.md)和仓库工作约定。

| 版本锚点 | 证据 | 证明范围 | 未证明范围 / 当前边界 |
|---|---|---|---|
| 0.6.0 | [接入漏斗记录模板](0.6.0-onboarding-funnel.md) | 无先验 Agent 已量测两次：首次 997s 到首次 capture；按修复后 quickstart 复测 651s，五步（identity→catalog→snapshot→`ui perform`→`capture`）逐字照抄文档命令、一次成功、零 `error.code` | 10 分钟目标仍未达成（651s）；无先验用户一行仍待量测；两次量测暴露的两处 quickstart 文档缺口与一处会话脚本在 zsh 下自定位失败的缺陷均已随本 MR 修复，脚本修复后未第三次复测 |
| 0.6.0 | [reveal 预算门求值顺序](0.6.0-reveal-budget-order.md) | 有可驱动容器时 `_run` 可达且预算门逐项拒绝；两条 `_admit` 短路路径完全不评估 policy 预算，且吞掉的是整个预算门而非某一字段；DG-060-05 据此裁决保持两层预算并接受本对照替代设备会话 | `flutter_test` 合成滚动与语义树，不是设备事实；modal、懒加载与真实滚动现场仍待设备/consumer 验收 |
| 0.5.0 | [最低 Flutter / Dart SDK 组合](0.5.0-flutter-sdk-floor.md) | Flutter 3.44.0 / Dart 3.12.0 是首个已完整 resolve、analyze、test 且满足 identifier 安全语义的 stable 组合 | 不外推到更早 SDK、未来 SDK 或设备端业务验收 |
| 0.5.0 | [接入漏斗只读闭环](0.5.0-onboarding-skill-acceptance.md) | 干净检出按 INSTALL + Skill 在 iOS 模拟器完成 identity、catalog、describe 与 snapshot | 只读、单模拟器；不证明安全写操作、capture、Android 或真实无先验用户体验 |
| 0.5.0 | [Semantics probe 帧放大量测](0.5.0-semantics-probe-benchmark.md) | 固定 harness 与 Android 真机 profile 证明改动前 2 帧放大及改动后帧数口径 | 性能数不是跨设备 SLA，也不授权省略 generation、gate 或 tree identity 复核 |
| 0.5.0 | [目标面遮挡语义复现](0.5.0-target-plane-occlusion-repro.md) | Android 真机现象可在 example 复现，并定位 direct-target/semantics 差异与 reveal 合并拒绝 | 只提供裁决输入，不代表 DG-060-05 已接受或修复已经交付 |
| 0.4.0 | [Android 权限弹窗闭环预检](android-permission-exercise-precheck.md) | Android 16 真机完成 App 侧触发并证明 OEM matcher 会安全地 fail-closed | 真实弹窗 exercise 未闭环，不能宣称该设备或所有 OEM 可用 |
| 0.4.0 | [Android 权限矩阵](android-permission-matrix.md) | consumer 真机取得 status、normalize(granted)、reset 与会话恢复设备事实 | normalize(denied)、未声明权限区分、真实 exercise 与 capability 探测仍有边界 |
| 0.4.0 | [example 权限矩阵](example-permission-matrix.md) | 仓内 example 在 Android 真机完成 status、normalize(granted) 与 reset，是 consumer 验收前置证据 | 不是 consumer 业务验收；exercise、denied、iOS 路径未覆盖 |
| 0.4.0 | [HarmonyOS 兼容性](harmonyos-compatibility.md) | 协议能保守表达未知，fixture、构建前置和六步矩阵的阻塞条件已记录 | SDK、HAP、设备与 consumer 均未闭环，不能宣称 HarmonyOS 支持 |
| 0.4.0 | [iOS XCUITest 权限真机](ios-permission-xcuitest.md) | iPhone 真机完成 camera、microphone、locationWhenInUse 的弹窗处理与 Patchbay 恢复 | 不证明通用 status/normalize、notifications、其他语言或无感重启恢复 |

## 维护规则

- 新证据文件加入本目录时，同一个 MR 必须在上表登记版本锚点、证明范围与未证明范围。
- 数字、矩阵和设备事实锚定取得证据的固定提交；后续实现改变口径时保留旧事实，并另写实施后口径或新报告。
- 报告只写中性结论；接入方名称、应用或设备标识、签名材料和敏感 payload 留在被 gitignore 的本地证据目录。
- RC 交接从本索引反查证据；索引没有列出的口头验证、日志片段或未固定 SHA 不能替代版本退出条件。
