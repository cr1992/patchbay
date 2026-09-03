# 技术提案（Proposal）

Proposal 用来冻结实现前必须一致理解的技术契约。它不是 backlog 的副本，也不记录实施进度或发布
优先级；这些分别由 `docs/backlog.md` 和版本计划维护。

## 状态

- `提案中`：允许讨论和原型验证，禁止合入正式实现；
- `已接受`：设计闸门已通过，可以按文档实现；
- `已否决`：保留被否决原因，不再实现；
- `已替代`：必须链接替代 Proposal。

## 目录和命名

版本内 Proposal 放在 `<version>/<topic>.md`。一个 Proposal 可以承接多个强耦合的 PB 条目，但必须解释
为什么不能独立裁决；一个 PB 若引用多个 Proposal，也要在 backlog 中给出主方案入口。

0.4.0 已接受提案：

- [命令契约与执行证据](0.4.0/command-contracts.md)
- [Launcher、Session 与唤醒租约](0.4.0/launcher-session.md)
- [锚定式手势](0.4.0/anchored-gestures.md)
- [Manifest 与逐屏巡检](0.4.0/manifest-navigation.md)
- [Capture、snapshot revision 与 diff](0.4.0/visual-evidence.md)
- [DevTools perf 与 net 画像](0.4.0/devtools-profiling.md)
- [调试轨迹持久化](0.4.0/debug-traces.md)
- [平台权限编排与系统弹窗恢复](0.4.0/platform-permissions.md)

0.5.0 已接受提案：

- [Snapshot provider JSON 边界与冻结读视图](0.5.0/snapshot-provider-boundary.md)
- [锚定式合成 tap（ui.gesture.tap）](0.5.0/anchored-tap.md)
- [点性 semantics 派发的遮挡准入](0.5.0/semantics-occlusion-admission.md)
- [identifier 锚定的 scroll-to-reveal](0.5.0/semantics-scroll-reveal.md)
- [Invocation catalog policy 缓存与失效协议](0.5.0/catalog-policy-cache.md)
- [Audit sink 顺序投递与有界背压](0.5.0/audit-delivery.md)
- [Invocation cooperative cancellation、deadline 与统一受理预算](0.5.0/invocation-cancellation.md)
- [树类大载荷落 artifact](0.5.0/tree-artifact-output.md)
- [--view brief 瘦 JSON 视图](0.5.0/brief-view.md)
- [identifier 锚定的通用 Semantics action](0.5.0/semantics-identifier-action.md)
- [domain 写命令 gate 强制执行](0.5.0/domain-gate-enforcement.md)
- [workspace / worktree 级会话亲和性](0.5.0/workspace-session-affinity.md)
- [Semantics probe 请帧策略与 identifier 索引](0.5.0/semantics-probe-scheduling.md)
- [Snapshot 双预算、single-flight 与可选 source revision](0.5.0/snapshot-resources-revisions.md)
- [CLI 公共 API surface 收口](0.5.0/cli-public-api-surface.md)
- [公开 SDK 下限提升至 Flutter 3.44.0 / Dart 3.12.0](0.5.0/sdk-floor-raise.md)
- [会话启动身份签名格式与三态比较](0.5.0/session-identity-signature.md)（实现后追溯补齐）

0.5.0 提案中：

（暂无）

0.6.0 已接受提案：

- [Core 公共 Dart API 分层](0.6.0/core-public-api-layers.md)
- [UI 可达性与遮挡语义](0.6.0/ui-reachability-semantics.md)
- [Gate 声明与执行真源](0.6.0/gate-execution-boundary.md)
- [任务导向 UI 命令入口](0.6.0/task-oriented-ui-entry.md)
- [Semantics 拒绝 details 对齐](0.6.0/semantics-rejection-details.md)
- [Descriptor 驱动的输出投影](0.6.0/descriptor-output-projection.md)

0.6.0 提案中：

（暂无）

已延期、尚未进入版本范围的候选方案：

- [调试轨迹 scenario 与受控回放](future/trace-replay.md)

新增提案从 [`_template.md`](_template.md) 复制。Proposal 被接受后，将跨版本仍有效的结论同步进
`docs/design.md`；版本特有的取舍继续留在 Proposal 中。
