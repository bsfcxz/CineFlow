# -*- coding: utf-8 -*-
"""检查自持 libmpv.so 是否含所需解码器（**收工/发版前必跑**）。

## 为什么需要这个脚本（本轮事故的根因 + 开源项目对照）

我们的 `jniLibs/arm64-v8a/libmpv.so` 是**带解码器白名单编译**的（150 个），
实测缺 4 个关键解码器：

| 缺的解码器 | 现象 | 用户报障原文 |
|---|---|---|
| `ff_truehd_decoder` | `Failed to initialize a decoder for codec 'truehd'` → **播放无声** | "我切换音轨（truehd等）时也没有声音" |
| `ff_mlp_decoder` | 同上（TRUEHD 的无损内核） | — |
| `ff_pgssub_decoder` | `Could not find subtitle decoder for format 'hdmv_pgs_subtitle'` → **一条字幕都不显示** | "播放画面中没有字幕" |
| `ff_mov_text_decoder` | MP4 内嵌字幕不显示 | — |

**关键**：蓝光原盘的字幕 **100% 是 PGS 图形字幕** ⇒ 缺 `pgssub` 时
"字幕功能看起来完全坏了"，而 UI 里列表是正常的（选了没反应）。

## 对照开源项目（子代理调研，已核实源码）
· `mpv-android` 官方 `buildscripts/scripts/ffmpeg.sh`：
  只 `--disable-{muxers,encoders,devices}`，**没有 `--disable-decoders`**
  ⇒ 官方成品是**全量解码器**，不会有这些问题。
· `xyoye/DanDanPlayForAndroid` 有 `ffmpegHasDecoder()` 自检（我们参考它）

⇒ 本脚本把"播一次才知道"变成"跑一次就知道"。

## ⚠️ 改本文件的符号表之前必读（2026-10-14 我在这里犯过错）

**符号名必须查 ffmpeg 源码的 `FFCodec` 声明，不能按编码名拼**：
```
ffmpeg 里： const FFCodec ff_movtext_decoder = { ... }   ← 符号名
                        ↑ 无下划线
编码名（服务端给的）： mov_text / tx3g / tmcd
```
我按直觉写成 `ff_mov_text_decoder` ⇒ 脚本**恒报"缺 mov_text"**，
而两个变体其实都有它 —— 典型的"验证手段本身错了"（§8.4 第二类假象）。

⇒ 新增条目前，先去 <https://github.com/FFmpeg/FFmpeg> 对应
   `libavcodec/*dec.c` 里搜 `FFCodec ff_` 确认。

## 用法
    python tool/check_mpv_decoders.py            # 检查全部 ABI
    python tool/check_mpv_decoders.py --abi arm64-v8a
退出码 0 = 全都有；1 = 有缺失（会列出缺哪些 + 影响 + 修法）。
"""
import argparse
import io
import os
import re
import sys

# 必需（缺了会直接导致用户可见故障）
REQUIRED = {
    'ff_truehd_decoder': 'TRUEHD 无损音轨（蓝光主流）',
    'ff_mlp_decoder': 'MLP（TRUEHD 的无损内核）',
    'ff_dca_decoder': 'DTS（dca 是 DTS 的解码器名）',
    'ff_ac3_decoder': 'AC3（DVD/蓝光常见）',
    'ff_eac3_decoder': 'E-AC3（杜比数字+）',
    'ff_aac_decoder': 'AAC（最普遍）',
    'ff_flac_decoder': 'FLAC 无损',
    'ff_opus_decoder': 'Opus',
    'ff_pgssub_decoder': 'PGS 图形字幕（蓝光 100% 用这个）',
    'ff_dvdsub_decoder': 'DVD VOBSUB 图形字幕',
    'ff_subrip_decoder': 'SRT（最常见的外挂字幕）',
    'ff_ass_decoder': 'ASS/SSA（特效字幕）',
    'ff_webvtt_decoder': 'WebVTT',
    # ⚠️ 符号名**没有下划线**（ffmpeg 源码 `libavcodec/movtextdec.c`：
    #    `const FFCodec ff_movtext_decoder = {`）。
    #    2026-10-14 我写成 `ff_mov_text_decoder` ⇒ **恒报缺失的假警报**
    #    （default 与 full 两个变体其实都有它）。
    #    ⇒ 改这张表前**先查 ffmpeg 源码里的 FFCodec 名**，别按直觉拼。
    'ff_movtext_decoder': 'MP4 内嵌字幕（mov_text）',
    'ff_h264_decoder': 'H.264 视频',
    'ff_hevc_decoder': 'H.265/HEVC 视频',
    'ff_vp9_decoder': 'VP9 视频',
    'ff_av1_decoder': 'AV1 视频',
}

# 缺了"影响体验但不致命"（缺失只提示，不算失败）
NICE_TO_HAVE = {
    'ff_vorbis_decoder': 'Vorbis 音频',
    'ff_wmav2_decoder': 'WMA 音频',
    'ff_dvbsub_decoder': 'DVB 图形字幕',
    'ff_stl_decoder': 'STL 字幕',
}

JNI_LIBS = os.path.join('android', 'app', 'src', 'main', 'jniLibs')


def read_so(path):
    with io.open(path, 'rb') as f:
        return f.read()


def check(abi, root):
    p = os.path.join(root, JNI_LIBS, abi, 'libmpv.so')
    if not os.path.exists(p):
        return None, '缺少文件: %s' % p
    data = read_so(p)
    missing = [k for k in REQUIRED if k.encode() not in data]
    missing_opt = [k for k in NICE_TO_HAVE if k.encode() not in data]
    found = [k for k in REQUIRED if k.encode() in data]
    # 该 .so **总共**含多少个解码器符号（用于判断"白名单版"还是"全量版"）
    # 实测基线：default 变体 = 150；full 变体 = 513（2026-10-14）
    total = len(set(re.findall(rb'ff_[a-z0-9_]+_decoder', data)))
    return {
        'path': p,
        'size': len(data),
        'missing': missing,
        'missing_opt': missing_opt,
        'found': found,
        'total': total,
    }, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--abi', default=None,
                    help='只查某个 ABI（默认查 jniLibs 下全部）')
    ap.add_argument('--root', default=None,
                    help='仓库根（默认脚本所在目录的上一级）')
    args = ap.parse_args()

    root = args.root or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    base = os.path.join(root, JNI_LIBS)
    if not os.path.isdir(base):
        print('✗ 找不到 %s' % base)
        return 1

    abis = [args.abi] if args.abi else sorted(
        d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d)))

    print('=== 检查 libmpv.so 的解码器完整性 ===')
    print('（自持 .so 若是"白名单编译"，缺解码器的现象是'
          '"播放无声/字幕不显示"，且**不报错**）\n')

    bad = 0
    for abi in abis:
        r, err = check(abi, root)
        if err:
            print('[%s] %s' % (abi, err))
            bad += 1
            continue
        print('[%s] %s（%.1f MB）'
              % (abi, r['path'].replace(root + os.sep, ''), r['size'] / 1048576))
        print('  必需解码器: %d/%d 齐备（该 .so 共含 %d 个解码器符号）'
              % (len(r['found']), len(REQUIRED), r['total']))
        # 判断是哪种构建（便于辨认"换没换成 full"）
        if r['total'] < 200:
            print('  · 这是**白名单裁剪版**（实测 default 变体 = 150 个）'
                  ' ⇒ 蓝光常见格式会缺')
        else:
            print('  · 这是**接近全量**的构建（实测 full 变体 = 513 个）')
        if r['missing']:
            bad += 1
            print('  ✗ **缺少 %d 个必需解码器**：' % len(r['missing']))
            for k in r['missing']:
                print('      · %-22s → %s' % (k, REQUIRED[k]))
            print('    ⚠️ 先排除"符号名写错"：本文件曾把 ff_movtext_decoder'
                  ' 写成 ff_mov_text_decoder ⇒ 恒报缺失。')
            print('       确认方式：去 FFmpeg 源码 libavcodec/*dec.c 搜 '
                  '`FFCodec ff_`。')
            print('    修法（三选一）：')
            print('      ① 重新编译 libmpv.so，**去掉 --disable-decoders 白名单**'
                  '（mpv-android 官方做法）')
            print('      ② 或在白名单里补上：%s'
                  % ','.join(k[len('ff_'):-len('_decoder')] for k in r['missing']))
            print('      ③ 或换用 mpv-android 官方预编译的 libmpv.so（全量解码器）')
        else:
            print('  ✓ 全部必需解码器都在')
        if r['missing_opt']:
            print('  · 可选（缺失不致命）：%s'
                  % ', '.join(r['missing_opt']))
        print()

    if bad:
        print('结论：**有 %d 个 ABI 不通过** —— 某些音轨/字幕会静默播不出来' % bad)
        return 1
    print('结论：全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
