#!/usr/bin/env bash
# PB-050-12：在调用方提供的 Flutter/Dart 组合下验证全部五个 package。
#
# 本脚本不安装、切换或写入全局 Flutter SDK；调用方必须先把目标组合的 `flutter`
# 放进 PATH（例如解压一份 SHA-256 固定的 release archive 并 export PATH）。脚本
# 只做 pub get / analyze / test：证明「这份组合确实能解析全部五个 package 的
# 依赖并通过现有测试」。
#
# 不做原生平台构建（Android/iOS APK/IPA）：现有 flutter_package CI lane 本身也
# 不构建原生产物（只 analyze + test），这条 lane 与它对齐，不为此新增 CI 镜像或
# Android/iOS 工具链依赖。
#
# CI 用它守门的组合是 **pubspec 声明的下限：Flutter 3.44.0 / Dart 3.12.0**。这不是
# 探测性 lane——跑红即代表声明下限不再成立，必须阻断。下限为什么是 3.44.0：旧声明
# （Flutter `>=3.38.0` + Dart `>=3.11.0`）指向一个装不出来的组合（3.38.x 全系仅内置
# Dart 3.10.x）；最早可安装的 3.41.x 又缺 Flutter 上游提交 `af35e77c83d`，在那之前
# `Semantics(identifier:)` 不构成语义边界，`blockUserActions` 读不到目标节点上，导致
# `ui.reveal` 的遮挡判定 fail-open（PB-050-28，上游缺陷，不可能靠改仓内代码转绿）。
# 含该修复的第一个 stable 就是 3.44.0，实测五个包全绿。事实链与裁决见
# `docs/proposals/0.5.0/sdk-floor-raise.md`，完整调查数据见
# `docs/verification/0.5.0-flutter-sdk-floor.md`。
#
# 本脚本不清构建缓存。在同一棵工作树里切换 Flutter 版本跑它之前，必须先删掉每个
# 包的 `.dart_tool` 与 `build`——资产 manifest 的 runtime-stages 版本戳由生成它的
# 那个 SDK 决定、不随 SDK 切换失效，漏清会得到 `ink_sparkle.frag ... Expected 2,
# got 1` 这类假失败。CI 每次都是干净容器，不受影响。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 兼容原有本地入口；真实包清单与命令只维护在私有 repo task 中。
exec dart run tool/repo_tasks.dart sdk-floor
