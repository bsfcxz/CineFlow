#!/usr/bin/env bash
# CineFlow release 构建脚本（Git Bash / 项目根目录运行）
# 按架构拆分 + 混淆精简：91.6MB（三架构合并）-> ~30MB（arm64 单架构）
# 产物: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
#       （同时复制为 app-release.apk 方便固定路径取用）
# 注意：media_kit 的 libmpv 三架构库必须靠 --split-per-abi 拆出，
#       --target-platform / ndk.abiFilters 对它不生效。
set -e
flutter build apk --release \
  --split-per-abi \
  --obfuscate --split-debug-info=build/symbols

cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
   build/app/outputs/flutter-apk/app-release.apk
