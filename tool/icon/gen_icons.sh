#!/usr/bin/env bash
# 生成 CineFlow 启动图标（S3 折带三角·一笔流光，去青色圆点）
# 产物：legacy 圆角方形 ic_launcher.png + 自适应图标 foreground/background 层
#
# 用法： bash tool/icon/gen_icons.sh          # 在仓库根执行
# 路径全部相对脚本自身推导——**不要把本机绝对路径写死进来**：
# 这类路径会把开发机的用户名带进公开仓库（本仓库曾因此泄漏过 Windows 用户名，
# 已改写 git 历史清除，见 docs/lessons/methodology.md）。
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EDGE="${CF_EDGE:-/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe}"
RES="$ROOT/android/app/src/main/res"
TMP="$ROOT/tool/icon/_gen"
TPL="$ROOT/tool/icon/icon_template.svg.frag"

if [ ! -x "$EDGE" ] && [ ! -f "$EDGE" ]; then
  echo "[未执行] 找不到 Edge：$EDGE" >&2
  echo "         用 CF_EDGE=/path/to/msedge.exe 指定，或装 Edge 后重跑。" >&2
  exit 1
fi
mkdir -p "$TMP"

RIBBON='<path d="M 39 76 L 39 33.5 C 39 30.5 42.5 28.8 45 30.5 L 74.5 50.2 C 77 51.9 77 55.6 74.5 57.3 L 47 75.6" fill="none" stroke="url(#wv)" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>'
BACK='<rect width="108" height="108" fill="url(#bg)"/><rect width="108" height="108" fill="url(#haze)"/>'

render() { # $1=html $2=png $3=size
  "$EDGE" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --user-data-dir="$TMP/profile" --force-device-scale-factor=1 \
    --window-size=$3,$3 --default-background-color=00000000 \
    --screenshot="$2" "file:///$(cygpath -m "$1")" >/dev/null 2>&1
}

gen_full() { # legacy：圆角 27% 方形，透明四角
  local size=$1 out=$2 html="$TMP/full_$1.html"
  local svg; svg=$(sed "s/__SIZE__/$size/g; s|__CONTENT__|$BACK$RIBBON|" "$TPL")
  cat > "$html" <<EOF
<!DOCTYPE html><html><head><style>*{margin:0;padding:0}html,body{background:transparent}#w{width:${size}px;height:${size}px;border-radius:27%;overflow:hidden}</style></head><body><div id="w">${svg}</div></body></html>
EOF
  render "$html" "$out" "$size"
}

gen_layer() { # 自适应层：$1=content $2=out $3=size
  local content=$1 out=$2 size=$3 html="$TMP/layer_${4}_$3.html"
  local svg; svg=$(sed "s/__SIZE__/$size/g; s|__CONTENT__|$content|" "$TPL")
  printf '<!DOCTYPE html><html><head><style>*{margin:0;padding:0}html,body{background:transparent}</style></head><body>%s</body></html>' "$svg" > "$html"
  render "$html" "$out" "$size"
}

# legacy 五档
declare -A LEG=([mdpi]=48 [hdpi]=72 [xhdpi]=96 [xxhdpi]=144 [xxxhdpi]=192)
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  gen_full "${LEG[$d]}" "$RES/mipmap-$d/ic_launcher.png"
done

# 自适应层五档（108dp：mdpi=108 ... xxxhdpi=432）
declare -A ADP=([mdpi]=108 [hdpi]=162 [xhdpi]=216 [xxhdpi]=324 [xxxhdpi]=432)
for d in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  gen_layer "$BACK" "$RES/mipmap-$d/ic_launcher_background.png" "${ADP[$d]}" bg
  gen_layer "$RIBBON" "$RES/mipmap-$d/ic_launcher_foreground.png" "${ADP[$d]}" fg
done

# anydpi-v26 自适应图标声明
mkdir -p "$RES/mipmap-anydpi-v26"
cat > "$RES/mipmap-anydpi-v26/ic_launcher.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
EOF
echo ICONS_DONE
