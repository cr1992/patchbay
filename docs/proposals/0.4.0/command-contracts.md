# 0.4.0 命令契约与执行证据

> 状态：提案中
>
> 关联：PB-040-05、PB-040-06、PB-040-07、PB-040-08、PB-040-21、PB-040-22
>
> 设计闸门：DG-040-05

## 问题

命令目录、host 分发、CLI 注册和文档目前由多处手写；请求已有 descriptor 约束，但受理 payload 和
job 终态 payload 仍是自由 `Map`。接入方可以漏掉 `session` 等字段，CLI 的 `--json` 只能保证外层
信封，不能让脚本判断字段缺失究竟是“不适用”“未知”还是 provider 违规。同值写入不产生设备回报
时，超时又会把“已经发送”与“根本没发送”压成同一种失败。

## 目标与非目标

### 目标

- 一份 CommandRegistry 同时驱动目录、解码、门、handler、响应校验和 CLI/help/docs 生成。
- descriptor 明示受理 payload 与终态 payload 的必填、可空、变体和未知字段策略。
- 脚本能区分 `notSent`、`sentUnconfirmed`、`unchanged`、`deviceConfirmed`，并知道事实来源。
- provider 违规在 host 边界被替换成稳定拒绝，不把坏 payload 继续传给 CLI。

### 非目标

- 不把领域 payload 收编成 Patchbay 统一业务模型。
- 不把“命令已发送”升级成“设备已完成”。
- 不新增含义模糊的 job phase；job 仍使用 `running/completed/failed/cancelled`。
- 不在 0.4.0 移除老 host 的自由 payload 兼容路径。

## Registry 与 schema 契约

每条 descriptor 形成一个不可分割的注册单元：

```text
name + sideEffects + gates + requestSchema + responseSchema
  -> request decoder
  -> gate runner
  -> handler
  -> accepted/terminal response validator
  -> catalog + CLI/help/docs
```

`responseSchema` 分两面：

- `accepted`：即时受理返回；声明字段、类型、是否必填/可空和允许的变体 discriminator；
- `terminal`：job 终态返回；按 `completed/failed/cancelled` 分别声明 payload；
- 未声明字段默认拒绝。确需开放扩展时必须显式声明 `additionalProperties`，不能靠 validator 漏检；
- “字段不适用”用变体表达，“值未知”用显式可空表达，禁止二者都退化成缺字段；
- schema 本身进入 catalog digest，调用前目录复核继续覆盖请求和响应两面。

host 在 adapter 回程、写入 job ledger 前校验；CLI 在收到信封后按同一 descriptor 表面复核。任一层
发现必填字段缺失、类型错误、未知变体或额外字段，返回 `providerProtocolViolation`，`details.reason`
使用封闭值：`missingField`、`unexpectedNull`、`wrongType`、`unknownVariant`、`unknownField`。

## 执行证据

需要表达设备执行结果的命令，在受理或终态 payload 中使用统一对象：

```json
{
  "execution": {
    "classification": "notSent | sentUnconfirmed | unchanged | deviceConfirmed",
    "factSource": "appRecorded | commandEcho | deviceReported | uiObserved | unknown",
    "observedAtMs": null,
    "reasonCode": null
  }
}
```

- `notSent`：有证据表明发送动作未发生；终态必须为 `failed`。
- `sentUnconfirmed`：发送动作已发生，但确认预算内未观察到设备事实；要求确认的命令必须 `failed`，
  允许弱确认的命令可 `completed`，但 descriptor 必须显式声明该策略。
- `unchanged`：发送前已有可信的同值证据，且发送后没有相反设备事实；可以 `completed`。
- `deviceConfirmed`：存在 `deviceReported` 或 descriptor 明示可接受的更强观测；可以 `completed`。

`observedAtMs` 只在确有观测时间时出现，否则为 `null`。`reasonCode` 是命令 schema 声明的封闭值，
不得塞自由文本。CLI 退出码由 job 终态决定，不能只看 `classification` 猜成功。

## 兼容与降级

- 新 host 只有在真正执行响应校验后才声明 `responseSchemas` capability。
- 新 CLI 遇老 host：保留 payload 原样，输出 `schemaMode: legacyUnvalidated`，不得补造缺失字段。
- 老 CLI 遇新 host：忽略 catalog 新字段，继续读取既有信封；新增响应字段必须处在松读面。
- VM Service 与 direct 使用同一个 registry/validator，不允许各自实现 schema 分支。

## 安全与资源

- validator 错误只返回字段路径、reason 和期望类型，不回显 sensitive 值。
- retry 仅适用于 descriptor 标记幂等的 external 命令，并按 requestId 去重。
- audit sink 只记录命令名、requestId、参数形状、门结果和执行分类；默认不记录原值。
- schema 深度、字段数和错误条数必须有固定上限，避免恶意 payload 放大内存与输出。

## 验证

- registry 单测证明目录、dispatcher、CLI/help/docs 来自同一注册单元。
- 对必填缺失、可空、未知字段、未知变体、敏感值和资源上限逐项失败注入。
- 0.3.x fixture 覆盖新 CLI 的 `legacyUnvalidated`；0.4 host fixture 覆盖老 CLI 松读。
- VM/direct 对同一请求返回相同 schemaMode、稳定 code、requestId 和执行证据。
- 两个接入方各验证 `notSent/unchanged/sentUnconfirmed/deviceConfirmed`，至少一个覆盖 DP 同值写入。

## 待裁决

- descriptor 如何声明“允许弱确认完成”，默认必须为否。
- `uiObserved` 是否允许某些命令归类为 `deviceConfirmed`，还是只能作为领域成功证据。
- schema 资源上限的具体数值。

## 被否决方案

- 把 `sentUnconfirmed` 新增为 job phase：phase 与事实强度混在一起，旧客户端也无法解释。
- 等 TTL 到期一律报普通 timeout：丢失“已经发送”的关键事实。
- 让 CLI 用字段是否存在推断 provider 版本：继续制造不可区分的缺失语义。
