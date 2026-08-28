# 0.6.0 Descriptor 驱动的输出投影

> 状态：提案中
>
> 关联：PB-050-40
>
> 设计闸门：DG-060-03

## 问题

`--view brief`、树类大载荷落 artifact 与完整输出已经证明同一事实需要多层投影，但字段选择分散在 CLI 的
brief rule、artifact disposition、friendly command、help 与 golden。新增一种大响应必须在多处重复登记，
descriptor 不知道自己的稳定机器投影，声明真源与呈现真源分离。

## 目标与非目标

### 目标

- 由 descriptor/schema 声明 full、brief 与 artifact-safe 机器投影。
- 新命令只登记一次投影事实，CLI/REPL/one-shot 使用同一解释器。
- 保持 0.5.0 有效 brief 输出逐字节不变，并给老 host 稳定 fallback。

### 非目标

- 不把人读文案冻结成稳定协议，不改变 consumer payload 的事实值。
- 不让 descriptor 指定任意本机输出路径、模板代码或可执行 formatter。
- 不移除现有大小、SHA-256、分块和覆盖写保护。

## 契约

推荐在 command descriptor wire 增加可选 `outputProjection`，只允许封闭声明：brief 保留的 JSON pointer、
可落 artifact 的 payload member、inline 字节阈值适用性与 artifact 媒体类型。字段缺失表示 legacy；CLI 使用
0.5.0 冻结 fallback 表，仅覆盖旧协议命令，且不得为新命令继续扩表。投影结果继续使用现有稳定 envelope，
不允许声明重命名事实字段或合成 consumer 未返回的成功值。

## 状态、失败与预算

投影在 host response 已通过 schema 校验之后、stdout 渲染之前执行。无效声明使整份 catalog 按 provider
违规失效；投影过程受现有 inline/artifact 字节上限约束，不新增隐式网络读取。artifact 写入失败沿用本地
typed error，不改 host admission。

## 兼容与降级

新 CLI 连接老 host 时使用冻结 legacy fallback；老 CLI 忽略 additive descriptor 字段。VM/direct 传递同一
catalog。0.6.0 完成后 fallback 进入只读兼容区，1.0 前评估是否保留；不能一边声明化一边继续为新命令加
手工规则。

## 安全与隐私

descriptor 只能选择已经过脱敏/schema 校验的响应成员，不能把 sensitive、credential、绝对路径或未校验
consumer 文本提升到 brief。artifact 路径仍由本地 writer 决定，声明不携带文件系统位置。

## 验证

- 单元/协议测试：声明验证、JSON pointer、brief/full/artifact 三投影、legacy fallback 与无效目录。
- VM/direct：catalog 与输出逐字节对账。
- 接入方/真机：大树、capture、logs/export 与普通小响应的渐进式披露链。
- 失败注入：超限、缺字段、错类型、artifact 写失败、老 host 与目录漂移。

## 待裁决

- `outputProjection` 是否进入 wire；推荐进入，才能覆盖 live consumer command 并形成单一真源。
- brief 使用保留清单还是删除清单；推荐保留清单 fail-closed。
- artifact 声明覆盖 payload member 还是完整 response；是否允许多 artifact。
- 人读 summary 是否继续由 CLI 自由渲染；推荐不进入稳定声明。

## 被否决方案

- 继续在 CLI 为每个命令加 rule：重复事实和漂移问题不变。
- 让 descriptor 携带 formatter/template：扩大执行与注入面。
- 新 CLI 遇到老 host 禁用 brief/artifact：会破坏 0.5.0 已有能力。
