# 兼容性矩阵

> 维度：patchbay tag × wire `schemaVersion` × Flutter 版本 × 已知 consumer。
> 用于发版前后核对——升级 `schemaVersion` 或提高 Flutter 最低版本时，consumer 侧能否安全换 pin
> 应先查本表，而不是逐包翻源码。

## 当前记录

| patchbay tag | commit SHA | wire schemaVersion | Flutter（CI 验证） | Flutter（文档最低支持） | 已知 consumer |
|---|---|---|---|---|---|
| `patchbay-v0.4.0` | `fc3cf06dc8e12b36332a2c37d38d4fd69cdd2c27` | 1 | 3.44.9 | `>=3.38.0` | 内部接入方 ×1（0.4.0 pin MR 已提交，L0 全绿，真机待验） |
| `patchbay-v0.3.0` | `89574d2a5d28a33caf57b3505100b56dd5276d0a` | 1 | 3.44.9 | `>=3.38.0` | 未上报（本仓不持有该口径，待 consumer 仓核实后补记） |
| `patchbay-v0.2.1` | `d32f45e9d652920902e51f9c3dc25c189d804e46` | 1 | 3.44.9 | `>=3.38.0` | 内部接入方 ×2（1 已切至 / 1 在 0.2.0） |
| `patchbay-v0.2.0` | `4d92ea9d7b0bd19f6ba81880cd411af6659eedd6` | 1 | 3.44.9 | `>=3.38.0` | 内部接入方 ×2（1 已收口 / 1 在途） |
| `patchbay-v0.1.0` | `7c82c68d9dfed4b2a546e81de68b9e0101be4878` | 1 | 3.44.9 | `>=3.38.0` | 内部接入方 ×1（已升级在途） |

字段来源：

- **commit SHA**：`git rev-parse <tag>^{}`（annotated tag 必须取 peeled commit）。
- **wire schemaVersion**：`packages/patchbay/lib/src/service_host.dart:34` 与
  `packages/patchbay/lib/src/invocation.dart:58` 的 `static const int schemaVersion = 1;`。
  两处需保持同值，drift 会被 `packages/patchbay_transport` 与 `packages/patchbay_cli` 的握手校验
  在运行时拒绝（如 `packages/patchbay_cli/lib/src/client.dart:250` 的
  `schemaVersionMismatch`），不是仅文档层面的约定。
- **Flutter（CI 验证）**：`.github/workflows/ci.yml` 的 `FLUTTER_VERSION`；GitLab 侧 CI 镜像
  与之对齐。
- **Flutter（文档最低支持）**：`docs/guide.md` 第 9 行「使用 UI 能力时需要 Flutter `>=3.38.0`」，
  与根 `README.md` 第 26–27 行项目状态声明一致。两个 Flutter 数字不是同一件事：CI 验证版本是
  当前门禁实际跑过的版本，最低支持版本是文档承诺的下限，二者之间未逐版本回归，出现兼容问题以
  CI 验证版本为准。
- **已知 consumer**：patchbay 仓不持有 consumer 侧 pin 配置，无法在本仓验证；新增或变更
  consumer 记录前先向对应 consumer 仓核实。记「未上报」表示 tag 已发布但尚无 consumer 仓回报
  切版结果，与未打 tag 时的占位符 `待确认` 不是一回事——前者是已定状态，后者会被
  `release_prep --check` 的 `compat-matrix-backfill` 判红。

## 维护规则

- 每次打 `patchbay-vX.Y.Z` tag 前，在「当前记录」新增一行，不覆盖旧行——本表是历史矩阵，
  保留每个已发布 tag 对应的兼容组合，供排查「某个旧 consumer 卡在哪个 tag / schema」时回查。
- `schemaVersion` 变更（即使 tag 只是 patch 号）必须在新增行中体现，因为它是运行时强校验的
  兼容边界，不是版本号语义能替代的信息。
- consumer 列如果同一 consumer 在同一 tag 下有多条 pin 记录（例如同仓多个 flavor），拆成多行，
  不要在同一格塞多个 pin 值。
- 本表由 patchbay 仓维护 tag / schemaVersion / Flutter 三列；consumer 列的准确性依赖 consumer
  仓自己上报或人工核对，patchbay 仓不主动扫描外部仓库。
