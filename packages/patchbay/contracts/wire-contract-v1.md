# Patchbay wire contract v1

Patchbay 的稳定 wire DTO 由 JSON contract 生成，不手写 `toJson` / `fromJson`。contract 支持两种类型：

- `enum`：`name` + 封闭 `values`；
- `object`：`name` + `fields`，字段类型可为 `String` / `bool` / `int` / `num` / `Json` /
  `JsonObject` 或同 contract 内类型，另可声明 `nullable`、`list`；
- `wireName` 允许 Dart 字段名与既有 wire key 不同；`emitNull` 固定保留显式 `null`；
  `omitIfEmpty` 对 list / `JsonObject` 省略空值，并在解码时恢复为空集合。

生成器同时产出双向 codec、未知字段拒绝和逐字段类型校验。生成物进仓，`--check` 必须零漂移。

contract 只声明 wire 形状。consumer 仍需显式完成领域对象到 wire DTO 的投影，以裁决脱敏、事实来源和
完成性；禁止把领域对象反射或整对象 dump 到协议面。投影层不得再拼 JSON map；它只能构造生成 DTO，
由生成 codec 校验并输出。

```text
dart run packages/patchbay/tool/wire_codegen.dart \
  --contract <contract.json> --output <generated.g.dart> --write
dart run packages/patchbay/tool/wire_codegen.dart \
  --contract <contract.json> --output <generated.g.dart> --check
```

仓库内两份真源（通用协议与 Moii 配网投影）统一执行：

```text
just gen patchbay-wire write
just gen patchbay-wire check
```

两份 `--check` 已进入 commit / push / CI registry，contract 或 generator 变化但未更新生成物时直接失败。
