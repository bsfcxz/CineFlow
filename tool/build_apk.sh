#!/usr/bin/env bash
# CineFlow release 构建脚本（Git Bash / 项目根目录运行）
# 按架构拆分 + 混淆精简
# 产物: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
#       （同时复制为 app-release.apk 方便固定路径取用）
#
# 为什么必须 --split-per-abi：
#   自持的 libmpv.so（arm64-v8a，11.8MB）与 libcineflow_go.so 都只提供 arm64，
#   拆包后 arm64 单包约 38MB；不拆则会把三架构的空壳一起带上。
#
# 为什么加 --target-platform android-arm64（2026-10-07 用户策略）：
#   后续产物**只生成 arm64-v8a**。不指定时 split-per-abi 会把 armeabi-v7a /
#   x86_64 两个空壳包也构建出来（多花约一半时间，产物直接进垃圾桶）；
#   该 flag 让 Gradle 只编译 arm64 一个目标，与 splits 配置不冲突
#   （注意：gradle 里 ndk.abiFilters 才与 split-per-abi 互斥，勿混用）。
#
# ⚠️ 发版前必读 docs/AI-DISTRIBUTION.md：
#   本脚本只**构建**，不上传。上传必须经用户审批，走 release.yml（唯一通道）。
set -e
flutter build apk --release \
  --target-platform android-arm64 \
  --split-per-abi \
  --obfuscate --split-debug-info=build/symbols

cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk \
   build/app/outputs/flutter-apk/app-release.apk

echo ""
echo "产物："
ls -lh build/app/outputs/flutter-apk/*.apk
echo ""
echo "下一步（需用户审批，见 docs/AI-DISTRIBUTION.md §3）："
echo "  1) docs/changelog/v\$(cat VERSION).md 写好"
echo "  2) scripts/check-dev.ps1 退出码 0"
echo "  3) git tag v\$(cat VERSION) && git push origin v\$(cat VERSION)"
