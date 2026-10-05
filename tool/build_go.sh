#!/usr/bin/env bash
# 把 Go 核心逻辑层交叉编译为 Android 各 ABI 的共享库（libcineflow_go.so）。
#
# 产物：android/app/src/main/jniLibs/<abi>/libcineflow_go.so
#   （放 jniLibs 下，Gradle 会自动打进 APK；不要放进 build/，那是产物目录）
#
# 用法：bash tool/build_go.sh [abi...]      默认 arm64-v8a
#   bash tool/build_go.sh                      # 只编 arm64（手机端，体积最小）
#   bash tool/build_go.sh arm64-v8a armeabi-v7a x86_64
#
# 为什么必须用 -buildmode=c-shared + NDK clang：
#   Go 自身不支持 Android 目标，交叉编译带 cgo 的共享库要靠 NDK 的
#   clang 作为 CC，并显式声明 android API level（与 Gradle 的 minSdk 对齐）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODIR="$ROOT/go"
OUTBASE="$ROOT/android/app/src/main/jniLibs"

# Go 的绝对路径：winget 装完当前会话 PATH 可能未刷新
GO="${GO:-/c/Program Files/Go/bin/go.exe}"
[ -x "$GO" ] || GO="$(command -v go)" || {
  echo "[失败] 找不到 go，可设置 GO=/path/to/go" >&2; exit 1
}

# NDK：优先 ANDROID_NDK_HOME，否则取 ANDROID_HOME/ndk 下版本号最大的
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [ -n "$SDK" ] || { echo "[失败] 未设置 ANDROID_HOME / ANDROID_NDK_HOME" >&2; exit 1; }
  ANDROID_NDK_HOME="$(ls -d "$SDK"/ndk/*/ 2>/dev/null | sort -V | tail -1)"
  ANDROID_NDK_HOME="${ANDROID_NDK_HOME%/}"
fi
[ -d "$ANDROID_NDK_HOME" ] || { echo "[失败] NDK 目录不存在: $ANDROID_NDK_HOME" >&2; exit 1; }

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt"
HOSTTAG="$(ls "$TOOLCHAIN" | head -1)"
BIN="$TOOLCHAIN/$HOSTTAG/bin"
[ -d "$BIN" ] || { echo "[失败] NDK 工具链 bin 不存在: $BIN" >&2; exit 1; }

# 与 android/app/build.gradle.kts 的 minSdk 对齐（Flutter 默认 24）
API="${CF_ANDROID_API:-24}"

# ABI → Go 的 GOARCH / NDK 的 clang 三元组
goarch_for() {
  case "$1" in
    arm64-v8a)   echo arm64   ;;
    armeabi-v7a) echo arm     ;;
    x86_64)      echo amd64   ;;
    x86)         echo 386     ;;
    *) return 1 ;;
  esac
}
triple_for() {
  case "$1" in
    arm64-v8a)   echo aarch64-linux-android   ;;
    armeabi-v7a) echo armv7a-linux-androideabi ;;
    x86_64)      echo x86_64-linux-android    ;;
    x86)         echo i686-linux-android      ;;
    *) return 1 ;;
  esac
}

ABIS=("$@")
[ ${#ABIS[@]} -gt 0 ] || ABIS=(arm64-v8a)

echo "== 构建 Go 核心层 =="
echo "  go:  $GO"
echo "  ndk: $ANDROID_NDK_HOME"
echo "  api: $API"

for abi in "${ABIS[@]}"; do
  goarch="$(goarch_for "$abi")" || { echo "[跳过] 不支持的 ABI: $abi" >&2; continue; }
  triple="$(triple_for "$abi")"
  cc="$BIN/${triple}${API}-clang"
  [ -x "$cc" ] || { echo "[失败] 找不到交叉编译器: $cc" >&2; exit 1; }

  outdir="$OUTBASE/$abi"
  mkdir -p "$outdir"

  echo "  -> $abi (GOARCH=$goarch, CC=$(basename "$cc"))"
  (
    cd "$GODIR"
    CGO_ENABLED=1 GOOS=android GOARCH="$goarch" CC="$cc" \
      "$GO" build -buildmode=c-shared -trimpath \
        -ldflags="-s -w" \
        -o "$outdir/libcineflow_go.so" .
  )
done

echo "== 完成 =="
ls -la "$OUTBASE"/*/libcineflow_go.so 2>/dev/null || true
