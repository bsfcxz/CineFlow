@echo off
REM ============================================================
REM CineFlow release 构建脚本（Windows / 项目根目录运行）
REM 按架构拆分 + 混淆精简：91.6MB（三架构合并）-> ~30MB（arm64 单架构）
REM 产物: build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
REM       （同时复制为 app-release.apk 方便固定路径取用）
REM 注意：media_kit 的 libmpv 三架构库必须靠 --split-per-abi 拆出，
REM       --target-platform / ndk.abiFilters 对它不生效。
REM ============================================================
flutter build apk --release ^
  --split-per-abi ^
  --obfuscate --split-debug-info=build\symbols

copy /Y build\app\outputs\flutter-apk\app-arm64-v8a-release.apk ^
        build\app\outputs\flutter-apk\app-release.apk
