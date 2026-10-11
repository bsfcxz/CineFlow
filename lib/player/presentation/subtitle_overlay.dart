/// **字幕叠加层**：把内核上报的 cue 画到视频上（Media3 内核专用通路）。
///
/// ## 为什么需要它（真机取证：Media3 的字幕"配好了但不显示"）
/// Media3 把内嵌字幕（尤其 **PGS 图形字幕**）解析成 cue 后，
/// 官方渲染靠 `media3-ui` 的 `SubtitleView`。而本项目**刻意不引
/// `media3-ui`** —— 视频走 `setVideoSurface(Flutter Texture)`，
/// **没有任何 View 层**。真机现象：
/// ```
/// CF-Media3: 选轨 3 index=1 → group=0 track=0
///            mime=application/x-media3-cues     ← 选轨成功、cue 也解析了
/// （画面里什么都没有）                          ← 但没有 View 去画它
/// ```
///
/// ## 为什么由 Flutter 画（而不是引 media3-ui）
/// 1. 引 `media3-ui` 会带进 `PlayerView`/`SubtitleView` —— 与
///    "Flutter 纹理输出"的架构冲突（多一层 View，且无法与弹幕层同叠）
/// 2. 我们的**弹幕层已是成熟的"在视频上叠加自绘内容"通路**
///    （`danmaku_overlay.dart`）⇒ 字幕复用同一坐标系与画布
/// 3. 图形字幕（PGS）在 Flutter 里画 `Image` 即可
///
/// ## mpv 内核**不用**它
/// mpv 把字幕画进视频帧（`vo=gpu` 的 OSD）—— 字幕已在纹理像素里。
/// ⇒ 若两个内核都叠这层会导致 mpv 侧**画两遍**。
/// 故宿主只在 `kernel.cuesStream` 有数据时才叠（mpv 返回空流）。
///
/// ## ⚠️ 图形字幕的**长宽比**陷阱（PGS 特有的坑）
/// PGS 的位图是**整幅字幕构图平面**（通常 1920×1080，含大量透明区）。
/// 若直接按"位图尺寸"等比缩放，在 2.39:1 宽银幕片源上会**竖直压扁字形**
/// —— 这正是 Media3 官方 `SubtitleView` 的已知缺陷（官方明确不修）。
/// ⇒ 必须按 **"构图平面 → 视频显示区"** 映射：
/// 位图整体缩放到视频区宽度，保持**平面自身**的宽高比。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../kernel.dart';

class SubtitleOverlay extends StatefulWidget {
  const SubtitleOverlay({super.key, required this.cues, this.textStyle});

  /// 当前要显示的 cue（空 = 清屏）。
  final List<SubtitleCue> cues;

  /// 文本字幕的样式（图形字幕不用）。为 null 用内置默认。
  final TextStyle? textStyle;

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  /// 已解码的位图缓存（key = PNG 字节的 hash）。
  ///
  /// ## 为什么必须缓存
  /// PGS 是**逐帧位图**，且 Media3 会在每次 cue 变化时重发。
  /// 每帧都 `decodeImageFromList` 会造成明显卡顿（解码在 UI 线程排队）。
  /// 用"内容 hash"做 key ⇒ 同一张图（PGS 常连续多帧相同）只解码一次。
  final _cache = <int, ui.Image>{};

  /// 缓存上限（防长片播放时内存膨胀）。
  ///
  /// PGS 一帧解成 RGBA 约 8 MB（1920×1080×4）⇒ 不能无限存。
  /// 32 张 ≈ 256 MB 上限过大；取 12 张（≈100 MB）仍偏大，
  /// 但 PGS 连续帧通常高度重复 ⇒ 实际命中率高、条目数少。
  static const _maxCache = 12;

  @override
  void didUpdateWidget(SubtitleOverlay old) {
    super.didUpdateWidget(old);
    _decodeAll();
  }

  @override
  void initState() {
    super.initState();
    _decodeAll();
  }

  void _decodeAll() {
    for (final c in widget.cues) {
      final b = c.pngBytes;
      if (b == null || b.isEmpty) continue;
      final key = _keyOf(b);
      if (_cache.containsKey(key)) continue;
      _decode(b, key);
    }
  }

  static int _keyOf(Uint8List b) {
    // 用长度 + 首尾若干字节做轻量指纹（避免整段 hash 的开销）。
    // ⚠️ PGS 帧间常只差几个像素 ⇒ 指纹要覆盖足够多位置。
    var h = b.length;
    for (var i = 0; i < b.length; i += 97) {
      h = h * 31 + b[i];
    }
    return h & 0x7FFFFFFF;
  }

  Future<void> _decode(Uint8List bytes, int key) async {
    try {
      final img = await decodeImageFromList(bytes);
      if (!mounted) return;
      setState(() {
        if (_cache.length >= _maxCache) {
          // 淘汰最早的一个（简单 FIFO；PGS 的复用是短时的）
          _cache.remove(_cache.keys.first);
        }
        _cache[key] = img;
      });
    } catch (e) {
      debugPrint('[SubtitleOverlay] 位图解码失败: $e');
    }
  }

  @override
  void dispose() {
    for (final img in _cache.values) {
      img.dispose();
    }
    _cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cues = widget.cues.where((c) => !c.isEmpty).toList();
    if (cues.isEmpty) return const SizedBox.shrink();

    // ⚠️ **本 widget 的外框 = 视频显示区**（由宿主用
    //    `Center + SizedBox(picture)` 定位，与弹幕层同一套）。
    //    故这里直接用 `LayoutBuilder` 取自身尺寸作为"画面矩形"——
    //    若改用父级尺寸，字幕会贴到**屏幕**底部（上下黑边时明显错位）。
    return IgnorePointer(
      // 字幕层**不能吃手势** —— 与弹幕层同理（否则挡掉控制层的点击）
      child: LayoutBuilder(
        builder: (context, c) {
          final vr = Rect.fromLTWH(0, 0, c.maxWidth, c.maxHeight);
          return Stack(
            children: [
              for (final cue in cues)
                if (cue.pngBytes != null)
                  _positionedBitmap(cue, vr)
                else if (cue.text != null)
                  _positionedText(cue, vr),
            ],
          );
        },
      ),
    );
  }

  /// 图形字幕（PGS/VOBSUB）：位图按**构图平面 → 视频区**等比映射。
  Positioned _positionedBitmap(SubtitleCue c, Rect vr) {
    final img = _cache[_keyOf(c.pngBytes!)];
    if (img == null) {
      // 还在解码：这一帧先不画（下一帧 setState 会补上）
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }
    // ★ 关键：按**视频区宽度**缩放，并保持**位图自身**的宽高比
    //   （不能按"位图铺满视频区"拉伸 —— 那会在宽银幕片源上压扁字形）
    final scale = vr.width / img.width;
    final w = vr.width;
    final h = img.height * scale;
    // 贴视频区**底部**（PGS 构图平面本身就是"整幅画面"，
    // 底部对齐即与 mpv/其他播放器的行为一致）
    return Positioned(
      left: vr.left,
      top: vr.bottom - h,
      width: w,
      height: h,
      child: RawImage(image: img, fit: BoxFit.fill),
    );
  }

  /// 文本字幕（SRT/ASS）：底部居中 + 描边（保证亮画面上可读）。
  Positioned _positionedText(SubtitleCue c, Rect vr) {
    final base = widget.textStyle ??
        const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          height: 1.25,
        );
    return Positioned(
      left: vr.left + 24,
      right: vr.left + 24,
      bottom: 24,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Text(
          c.text!,
          textAlign: TextAlign.center,
          style: base.copyWith(
            // 双层阴影（与 `panelTextShadows` 同款思路）：
            // 字幕必须压在任意亮度的画面上都可读
            shadows: const [
              Shadow(blurRadius: 3, color: Colors.black),
              Shadow(blurRadius: 8, color: Colors.black87),
            ],
          ),
        ),
      ),
    );
  }
}
