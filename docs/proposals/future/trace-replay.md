# 调试轨迹 scenario 与受控回放

> 状态：提案中
>
> 关联：PB-040-24
>
> 设计闸门：DG-040-06

## 排期结论

回放不进入 0.4.0。先稳定 PB-040-23 recorder、PB-040-25/26 权限与系统中断 driver，再根据真实轨迹
决定 scenario DSL。此前只允许导出和比较轨迹，不提供 `replay` 或把历史事件直接转成写命令的入口。

## 前置条件

- trace schema 至少经过两个接入方和一个版本演进验证；
- 响应 schema、执行证据和 permission interruption 已稳定；
- identifier/generation 重解析、capability/descriptor 漂移检查可复用；
- sensitive placeholder 与 write confirmation 的策略已裁决。

## 候选契约

未来 scenario 从可执行 command events 生成，但旧 requestId、jobId、sessionId 和 generation 只作历史
证据。每一步实时重新握手、过门、解析目标和读取事实；写命令默认阻断，失败默认停止。具体 DSL、回放
预算和权限策略在上述前置稳定后另行评审，本文件不提前冻结实现。

## 待裁决

- DG-040-06：允许自动执行的副作用等级、确认模型和失败恢复语义。
