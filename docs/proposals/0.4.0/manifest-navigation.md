# 0.4.0 Manifest 与逐屏巡检

> 状态：已接受
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

## Manifest v1 与 v2

**v1 无条件保留。** 已发布的格式本身就是兼容资产，是否有接入方正在使用不作为前提——本仓也无法
证明外部没有。现行解析器对未知键直接拒绝，所以“把根键换掉”不是扩展而是让所有现存清单当场失效。

| 版本 | 根结构 | 说明 |
|---|---|---|
| `version: 1` | `version` + 平铺 `targets` | 等价于单一隐式 destination；`destination` 字段继续只作过滤 |
| `version: 2` | `version` + `destinations` | 每个 destination 含稳定 `id`、可选 navigation 参数和 `targets` |

两种版本都能读入同一内部模型。`--emit-manifest` 默认输出 v2。

命名空间用**新字段** `namespace: catalogTarget | semanticsIdentifier`，**不复用 `kind`**：`kind` 现在
的取值来自协议枚举（`text` / `capture`），而该枚举被已发布客户端严格解码——往它加值会让老 CLI 读
catalog 时当场 `FormatException`。`kind` 保持原义，且只在 `namespace: catalogTarget` 下有意义。

未知 namespace、重复 id 或跨命名空间冲突均 fail-closed。

`semanticsIdentifier` 条目只允许 `namespace` + `id`，不得携带 `kind` / `sensitive`；CLI 只在该条目
属于当前 settled destination 时读取既有 `ui.semantics.tree`。挂载事实就是完整、未截断快照中出现同名
identifier；唯一命中时回报 `nodeId` / `generation`、`treeRevision`、命令来源与 App 回报的事实来源，零命中以
`uiSemanticsIdentifierNotFound` 进入
`declaredNotMounted`，多命中进入 `identifierAmbiguous` 并以 `uiSemanticsIdentifierAmbiguous` 结束为
偏差。App 未声明 Semantics tree capability 时稳定失败 `manifestSemanticsUnavailable`；快照截断或形状
不完整时分别失败 `manifestSemanticsTreeTruncated` / `manifestSemanticsContractViolated`，不得把局部树当
完整事实。

`--emit-manifest` 默认只输出当前 destination，并写 `coverage: mountedOnly`；该字段与既有报告里
`destination` / `destinationSource` 的三态区分（读到了、读了但 App 没有、根本没读）保持同构，不另造
第三种表达。只有 consumer 注册了 destination provider 后才可输出多屏骨架；生成结果不得暗示未访问
屏幕已经验证。活体 tree capability 存在时，emit 把当前完整快照中的唯一、非空 identifier 一并写成
`semanticsIdentifier`；重复 identifier 或与 catalogTarget 同 id 时拒绝生成，不挑一个代表。

## 巡检协议

`--navigate` 明示副作用。consumer descriptor 提供 destination id 到既有导航 controller 的映射，
Patchbay 不接收任意 route string。每屏顺序为：导航受理 → 等待可配置稳定条件 → 读取 catalog 与
Semantics tree → 校验 → 记录 generation/事实来源。失败后默认停止，可用 `--continue-on-error` 收集
剩余屏幕，但最终仍返回失败。

输出包含 `visited/passed/failed/skipped` 和每个 destination 的稳定 reasonCode。是否恢复起始屏由
显式 `--restore` 控制；恢复失败独立报告，不能覆盖原始巡检失败。

退出码分工必须明确落到这里，沿用既有语义不新造：清单偏差走 `verificationDeviation`（App 正常回答
了，只是和带来的文件对不上）；导航被拒是受理拒绝；**恢复失败不改写退出码**，只加 notice 与机读
字段，并输出 App 最终停在哪个 destination——否则操作者拿不到"现在设备在哪一屏"这个继续调试所需的
事实。

稳定条件只接受 descriptor 声明门与既有 `ui.wait` 的封闭条件，不接受 consumer 提供的任意 readiness
probe。理由与 snapshot 不做表达式语言完全同构：一个 host 要解释的谓词会在操作者与 App 之间插入
第二个未经测试的求值器，它产出的每个调试答案都会多一件需要怀疑的事。

## 兼容、安全与预算

- 没有 destination capability 时，保留当前挂载态验证并标记 `navigationMode: unavailable`。
- v1 清单在 0.4 CLI 上继续被接受；升级 CLI 不要求同时改清单文件。
- YAML 只是输入格式，不改变 manifest schema；解析后立即转同一模型，两种版本各自适用。
- 格式只按小写扩展名选择：`.json`、`.yaml`、`.yml`；未知扩展名直接拒绝，不嗅探内容，也不在一种
  解析失败后尝试另一种。YAML 使用 CLI 独占的 `package:yaml ^3.1.3`、关闭 recover；显式 tag 与 alias
  一律拒绝，解析结果只允许 JSON 数据域，不加载类型、不执行构造器。该依赖不进入另外四个 package。
- manifest 输入最大 1 MiB、destination 最多 100 个、每屏 target 最多 1000 个且全文件累计最多 10000 个；
  解析树最大深度 64、最多 200000 个节点（含 mapping key）；Semantics 读取沿用既有 `maxDepth: 64`、`maxNodes: 10000`
  上限。
- JSON/YAML 语法错误继续使用 `manifestInvalid`，并给出不含输入片段的一基 `line/column`；格式不支持
  为 `manifestFormatUnsupported`，预算越界为 `manifestResourceLimit`，都沿用本地输入错误退出码 64。
- 每屏稳定等待默认 5 s、最大 120 s；一次巡检默认总预算 120 s、最大 10 min。单屏与总预算同时生效，
  任一耗尽都保留已经完成的 `visited` 证据并返回类型化失败。
- sensitive 参数必须走 stdin；巡检输出不包含输入框值或未脱敏语义文本。

## 验证

- JSON/YAML 等价 golden；重复、未知 namespace、错误位置、资源上限分别有失败测试。
- **v1 回归**：现存 v1 清单在 0.4 CLI 上仍能解析并给出与 0.3 相同的判定。
- `namespace` × `kind` 的非法组合各有一条失败用例。
- widget 测试覆盖 identifier 未挂载、歧义、generation 变化和两类命名空间同名。
- 恢复失败不覆盖原始巡检失败的退出码断言。
- 两个接入方各验证至少三屏及一个非常驻控件；失败注入覆盖导航拒绝和恢复失败。
- VM/direct 对 visited 顺序、reasonCode 和部分完成结构一致。

## 被否决方案

- 继续把 destination 当普通过滤字符串：无法证明非常驻控件。
- 自动从 Semantics 文案生成 identifier：不稳定且可能泄露用户内容。
- 直接把根键换成 `schemaVersion` + `destinations`：让所有现存 v1 清单当场失效。
- 复用 `kind` 承载命名空间：与协议枚举同名不同义，且往该枚举加值会打断已发布客户端。
- 允许 consumer 提供任意 readiness probe：在操作者与 App 之间插入第二个未经测试的求值器。
