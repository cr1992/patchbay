# 发版检查清单

> 只由 maintainer 执行：GitHub 合并 → 回推 GitLab → 打 tag → 下游按 pin 升级。
> 本清单是发版动作的核对表，不改变 [CONTRIBUTING.md](../CONTRIBUTING.md) 定义的权责边界。

## 1. 门禁全绿

GitLab CI（`.gitlab-ci.yml`，`stages: [check]`）三个 job：

- [ ] `dart_packages` —— `patchbay` / `patchbay_cli` / `patchbay_transport` 三包
      `dart analyze --fatal-infos` + `dart test` 全过
- [ ] `flutter_package` —— `patchbay_flutter` 本体与 `example` 均 `flutter analyze` +
      `flutter test` 通过
- [ ] `codegen_drift` —— `wire_codegen.dart --check` 无生成物漂移
- [ ] GitHub Actions 门禁绿（[`.github/workflows/ci.yml`](../.github/workflows/ci.yml)，
      三个 job 与上面一一对应）

验证命令（需从仓根调用，`codegen_drift` 尤其如此——生成物 header 记录的是仓根相对路径，
进包目录跑会假漂移）：

```console
$ for p in patchbay patchbay_cli patchbay_transport; do
    (cd "packages/$p" && dart pub get && dart analyze --fatal-infos && dart test)
  done
$ (cd packages/patchbay_flutter && flutter pub get && flutter analyze && flutter test)
$ (cd packages/patchbay_flutter/example && flutter pub get && flutter test)
$ dart run packages/patchbay/bin/wire_codegen.dart \
    --contract packages/patchbay/contracts/core_wire.json \
    --output packages/patchbay/lib/src/generated/core_wire.g.dart --check
```

## 2. 版本与 CHANGELOG 对账

- [ ] 四包 `pubspec.yaml` 的 `version` 字段一致，且与拟打的 tag 号（去掉 `patchbay-v` 前缀）一致
- [ ] README 的项目状态、Flutter Git ref 与 CLI `--git-ref` 均与四包版本一致
- [ ] [CHANGELOG.md](../CHANGELOG.md) 的 `Unreleased` 内容已归入拟发布的版本段落

验证命令：

```console
$ grep -m1 '^version:' \
    packages/patchbay/pubspec.yaml \
    packages/patchbay_cli/pubspec.yaml \
    packages/patchbay_flutter/pubspec.yaml \
    packages/patchbay_transport/pubspec.yaml
$ (cd packages/patchbay && dart test test/release_version_parity_test.dart)
```

## 3. 打 tag（`patchbay-vX.Y.Z`）

- [ ] 顺序遵循 CONTRIBUTING.md「发版」一节：GitHub 合并 → 回推 GitLab → 打 tag → 下游按 pin 升级
- [ ] tag 名格式 `patchbay-vX.Y.Z`（例：`patchbay-v0.1.0`），与第 2 步核对过的版本号一致

验证命令：

```console
$ git tag -l 'patchbay-v*'
$ git rev-parse patchbay-vX.Y.Z
```

## 4. 双端推送核对

GitHub 与内网主仓两个远端必须在同一 tag 上指向同一 commit：

- [ ] `git remote -v` 列出的两个 remote（`github` 与 `origin`）在该 tag 上的 commit SHA 一致

验证命令：

```console
$ git remote -v
$ git ls-remote --tags github patchbay-vX.Y.Z
$ git ls-remote --tags origin patchbay-vX.Y.Z
```

## 5. consumer 换 pin

- [ ] consumer 仓按新 tag 更新引用

接入方侧口径（**未在本仓验证，以该仓自身文档为准**）：pubspec SHA 四包同步改、`PATCHBAY_PINS`
同步更新、双 lock（`pubspec.lock` 等）一并提交。具体命令与文件位置本仓不持有真源，执行前查
接入方仓当前的构建脚本与相关文档确认。

## 6. 真机验收

- [ ] 真机跑通新 tag 下的接入路径（identity / catalog / 至少一条业务命令），桌面 / CI 门禁全绿
      **不代表**验收通过
- [ ] 参考 [使用指南「边界」](guide.md#边界)：CLI 结果是调试证据，不是产品验收证据——不证明像素
      正确或设备物理行为，真机验收需另行确认
