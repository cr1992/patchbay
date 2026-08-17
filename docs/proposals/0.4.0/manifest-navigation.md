# 0.4.0 Manifest 与逐屏巡检

> 状态：提案中
>
> 关联：PB-040-12、PB-040-13、PB-040-14、PB-040-15
>
> 设计闸门：无

## 问题

现有 `ui verify-manifest` 只核对当前挂载的 `PatchbayKey` catalog，无法覆盖 Semantics identifier，也不
会驱动 destination 导航。接入方需要手抄清单，并误以为 destination 已经代表逐屏验证。

## 目标与非目标

- manifest 显式区分 `catalogTarget` 与 `semanticsIdentifier` 两个命名空间。
- `ui targets --emit-manifest` 从当前活体状态生成可编辑初稿，不冒充全 App 清单。
- `ui verify-manifest --navigate` 逐 destination 驱动导航并输出每屏证据和部分完成状态。
- JSON/YAML 解析到同一内部模型，错误位置稳定。
- 不从路由源码静态猜屏幕，不把导航巡检描述为只读操作，不替接入方定义业务路由字符串。

## Manifest v1

顶层字段：`schemaVersion`、`destinations`。每个 destination 包含稳定 `id`、可选 navigation 参数和
`targets`；每个 target 必须带 `kind: catalogTarget|semanticsIdentifier` 与 `id`，可选约束只使用其
命名空间真实可观测的字段。未知 kind、重复 id 或跨命名空间冲突均 fail-closed。

`--emit-manifest` 默认只输出当前 destination，并写 `coverage: mountedOnly`。只有 consumer 注册了
destination provider 后才可输出多屏骨架；生成结果不得暗示未访问屏幕已经验证。

## 巡检协议

`--navigate` 明示副作用。consumer descriptor 提供 destination id 到既有导航 controller 的映射，
Patchbay 不接收任意 route string。每屏顺序为：导航受理 → 等待可配置稳定条件 → 读取 catalog 与
Semantics tree → 校验 → 记录 generation/事实来源。失败后默认停止，可用 `--continue-on-error` 收集
剩余屏幕，但最终仍返回失败。

输出包含 `visited/passed/failed/skipped` 和每个 destination 的稳定 reasonCode。是否恢复起始屏由
显式 `--restore` 控制；恢复失败独立报告，不能覆盖原始巡检失败。

## 兼容、安全与预算

- 没有 destination capability 时，保留当前挂载态验证并标记 `navigationMode: unavailable`。
- YAML 只是输入格式，不改变 manifest schema；解析后立即转同一模型。
- destination 数、每屏 target 数、Semantics tree 大小和总巡检时间均有上限。
- sensitive 参数必须走 stdin；巡检输出不包含输入框值或未脱敏语义文本。

## 验证

- JSON/YAML 等价 golden；重复、未知 kind、错误位置、资源上限分别有失败测试。
- widget 测试覆盖 identifier 未挂载、歧义、generation 变化和两类命名空间同名。
- 两个接入方各验证至少三屏及一个非常驻控件；失败注入覆盖导航拒绝和恢复失败。
- VM/direct 对 visited 顺序、reasonCode 和部分完成结构一致。

## 待裁决

- 默认停止还是默认继续；提案默认停止。
- 稳定条件只支持 descriptor 声明门，还是允许 consumer 提供额外 readiness probe。

## 被否决方案

- 继续把 destination 当普通过滤字符串：无法证明非常驻控件。
- 自动从 Semantics 文案生成 identifier：不稳定且可能泄露用户内容。
