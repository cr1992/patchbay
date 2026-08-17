# 规划与交付治理

本文定义 backlog、版本计划、技术提案和 CHANGELOG 的权责边界。目标不是增加文档层级，而是让每个
事实只有一个维护位置，并让 CI 阻止编号、范围和状态漂移。

## 文档权责

| 文档 | 唯一负责 | 不得维护 |
|---|---|---|
| [backlog](backlog.md) | 条目编号、标题、动机、目标版本、实施状态、Proposal 指针 | 版本优先级、实施顺序、验收条件、技术方案正文 |
| [版本计划](releases/0.4.0.md) | 版本目标、P0/P1/P2、依赖与实施顺序、版本验收和退出条件 | 条目实施状态、重复的条目标题、方案裁决正文 |
| [Proposal](proposals/README.md) | API / wire、状态机、边界、兼容策略、资源预算、验证方案和设计裁决 | 排期优先级、实施进度、发布结果 |
| [design.md](design.md) | 已接受且跨版本长期有效的设计立场 | 尚未裁决的方案和单版本排期 |
| `changelog.d/` / `CHANGELOG.md` | 已实现的用户可见变化 | 待办、设计备选和实施过程 |

同一字段不得在两个文档中维护。为了可读性，版本计划可以多次引用 PB 编号，但范围表只写编号和
验收，不复制 backlog 标题；Proposal 的“状态”只表示设计是否被接受，不代表条目实施进度。

## 生命周期

```text
发现问题
  -> backlog 建号（待排期）
  -> 版本范围 MR（目标版本 + P0/P1/P2 + 验收）
  -> 必要时 Proposal（提案中）
  -> design-gate 裁决（Proposal 已接受 / 已否决）
  -> 实现 MR（实现中）
  -> 验证完成（已验证）
  -> 发布聚合到 CHANGELOG，并从 backlog 移除
```

范围、方案和实现允许在同一个 MR 中推进的前提是变更仍可独立评审且没有绕过裁决。存在未决
design-gate 时，实现代码不得先行合入。

## 什么时候必须写 Proposal

满足任一条件的条目，在进入实现 MR 前必须有 `docs/proposals/<version>/` 下的 Proposal：

- 新增或修改公共 API、wire 字段、命令 descriptor 或稳定 JSON 输出；
- 引入状态机、异步 job、超时、重试、取消、租约或资源上限；
- 横跨 `patchbay`、`patchbay_cli`、`patchbay_flutter` 或接入方适配层；
- 改变默认行为、安全边界、脱敏规则、兼容或降级语义；
- backlog 标记了 `design-gate`；
- 同一能力需要 VM Service、direct 或两个接入方共同验证。

纯文案、测试补强、明确的生成物修复和不改变外部行为的重构，可以在 MR 中直接写清契约和验收，
无需为了形式新增 Proposal。

Proposal 必须使用[模板](proposals/_template.md)，并至少冻结：目标/非目标、公共契约、状态与失败语义、
兼容策略、资源预算、测试矩阵、待裁决问题。Proposal 处于“提案中”时只能做原型验证；合入实现前
必须改为“已接受”，并把长期设计结论同步到 `design.md`。

## MR 规则

1. 范围 MR 同时更新 backlog 和对应版本计划；不改变运行时行为，无需 CHANGELOG 碎片。
2. Proposal MR 写 `Plan: PB-...` 和关联的 `DG-...`，不把“默认建议”当成已裁决事实。
3. 实现 MR 必须引用已接受 Proposal；实现若偏离，先更新 Proposal 并重新评审。
4. 范围延期先改版本计划，再清除 backlog 的目标版本；禁止只改其中一份。
5. 发布 MR 聚合 CHANGELOG、删除已完成 backlog 行并归档版本计划，不回写 Proposal 的实施状态。

## 自动检查

仓根运行：

```console
$ dart run tool/check_planning.dart
```

CI 会检查：

- backlog 的 PB / DG 编号唯一，实施状态属于封闭枚举；
- backlog 中目标为 `0.4.0` 的 PB 条目，在版本计划 P0/P1/P2 范围表中恰好出现一次；
- 版本范围表不引用不存在的 PB，也不复制 backlog 的标题列；
- backlog 中引用的 Proposal 和 design-gate 文件/编号存在；
- 标记 `待裁决` 的条目必须同时引用 Proposal 和 design-gate。

检查脚本只验证结构关系，不替代对方案内容和验收质量的评审。
