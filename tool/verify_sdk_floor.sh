#!/usr/bin/env bash
# PB-050-12：在调用方提供的最低可安装 Flutter/Dart 组合下验证全部五个 package。
#
# 本脚本不安装、切换或写入全局 Flutter SDK；调用方必须先把目标组合的 `flutter`
# 放进 PATH（例如解压一份 SHA-256 固定的 release archive 并 export PATH）。脚本
# 只做 pub get / analyze / test：证明「这份组合确实能解析全部五个 package 的
# 依赖并通过现有测试」——这正是 PB-050-12 要求证明的「真实可安装交集」。
#
# 不做原生平台构建（Android/iOS APK/IPA）：现有 flutter_package CI lane 本身也
# 不构建原生产物（只 analyze + test），这条最低 lane 与它对齐，不为此新增 CI
# 镜像或 Android/iOS 工具链依赖。
#
# 当前已知：仓库声明的 Flutter 下限（`>=3.38.0`）与 Dart 下限（`>=3.11.0`）无法
# 在同一个真实 Flutter release 上同时成立——Flutter 3.38.x 全系仅内置 Dart
# 3.10.x。两个约束共同要求的最早可安装 Flutter release 是 3.41.0（内置 Dart
# 3.11.0）。截至本次调查，3.41.0（及其全部 3.41.x 补丁版本）在 macOS arm64 本地
# 复现下未能通过 `packages/patchbay_flutter/test/reveal/reveal_matrix_test.dart`
# 的一条既有断言（`ModalBarrier 盖住已挂载目标`）；详情、根因分析与在 Linux 上
# 复核的必要性见 `docs/verification/0.5.0-flutter-sdk-floor.md`。这正是本脚本
# 现阶段只挂成非阻断 CI lane 的原因：跑通证明真相，不代表已经证明全绿。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo '== SDK floor =='
flutter --version

for package in patchbay patchbay_cli patchbay_transport; do
  echo "== packages/$package =="
  (
    cd "packages/$package"
    dart pub get
    dart analyze --fatal-infos
    dart test --reporter failures-only
  )
done

echo '== packages/patchbay_flutter =='
(
  cd packages/patchbay_flutter
  flutter pub get
  flutter analyze
  flutter test --reporter failures-only
)

echo '== packages/patchbay_flutter/example =='
(
  cd packages/patchbay_flutter/example
  flutter pub get
  flutter analyze
  flutter test --reporter failures-only
)
