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

作为 Git / path 依赖使用时，通过 package executable 调用：

```console
$ dart run patchbay:wire_codegen \
    --contract <contract.json> --output <generated.g.dart> --write
$ dart run patchbay:wire_codegen \
    --contract <contract.json> --output <generated.g.dart> --check
```

在本仓库根目录更新 core 生成物：

```console
$ dart run packages/patchbay/bin/wire_codegen.dart \
    --contract packages/patchbay/contracts/core_wire.json \
    --output packages/patchbay/lib/src/generated/core_wire.g.dart --write
$ dart run packages/patchbay/bin/wire_codegen.dart \
    --contract packages/patchbay/contracts/core_wire.json \
    --output packages/patchbay/lib/src/generated/core_wire.g.dart --check
```

`--check` 已进入仓库 CI；contract 或 generator 变化但未同步生成物时会失败。
