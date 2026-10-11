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

  /// 上次 layout 约束（用于'只在尺寸变化时打日志'）。
  String? _lastLayout;

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
          // ★ 诊断（真机排查用）：打出 layout 约束与缓存命中
          //
          // ## 为什么必须打（排查"cue 到了但画面没有"的盲区）
          // 有四种可能，光看代码分不清：
          // ① LayoutBuilder 拿到 0 尺寸（父级没给约束）
          // ② Stack 塌成 0（缺 StackFit.expand）
          // ③ 位图解码未完成（`_cache` 未命中）
          // ④ 算出的 left/top 把字幕推出画面
          // ⚠️ 只在**尺寸变化时**打（否则每帧刷屏；真机排查时已确认约束正常 393x221，这行保留作为“将来又变 0”的信号）
          final sizeKey = '${c.maxWidth.toStringAsFixed(0)}x'
              '${c.maxHeight.toStringAsFixed(0)}';
          if (_lastLayout != sizeKey) {
            _lastLayout = sizeKey;
            debugPrint('[SubtitleOverlay] 约束变化 → '
                '$sizeKey cues=${cues.length} '
                'cache=${_cache.length}');
          }
          final vr = Rect.fromLTWH(0, 0, c.maxWidth, c.maxHeight);
          return Stack(
            // ★★ **必须 `expand`**（真机回归：字幕整体不显示）
            //
            // ## 为什么（Flutter 布局语义）
            // 只含 `Positioned` 子项的 `Stack` **没有非定位子项**，
            // 其尺寸会**塌成 0×0**（`StackFit.loose` 下按子项算，
            // 而 `Positioned` 不参与尺寸计算）。
            // ⇒ Stack 高宽为 0 ⇒ **所有子项被裁掉** ⇒ 字幕完全不可见
            //   （不报错、不崩溃，只是"什么都没有" —— 极难排查）。
            //
            // `StackFit.expand` 让 Stack 撑满 `LayoutBuilder` 给的约束
            //（那正是宿主 `SizedBox(picture)` 传下来的画面矩形）。
            fit: StackFit.expand,
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

  /// 图形字幕（PGS/VOBSUB）：按**官方公式**算尺寸与位置。
  ///
  /// ## ★★★ 公式来源（Media3 1.4.1 `SubtitlePainter.setupBitmapLayout`）
  /// ```java
  /// int width  = Math.round(parentWidth * cueSize);
  /// int height = cueBitmapHeight != DIMEN_UNSET
  ///     ? Math.round(parentHeight * cueBitmapHeight)
  ///     : Math.round(width * (bitmap.getHeight() / (float) bitmap.getWidth()));
  /// int x = positionAnchor==END ? anchorX - width
  ///       : positionAnchor==MIDDLE ? anchorX - width/2 : anchorX;   // anchorX = parentWidth * cuePosition
  /// int y = lineAnchor==END ? anchorY - height
  ///       : lineAnchor==MIDDLE ? anchorY - height/2 : anchorY;      // anchorY = parentHeight * cueLine
  /// ```
  ///
  /// ## ★★ 我第一版错在哪（真机截图取证）
  /// 我用 `scale = vr.width / img.width` ⇒ 把实测 **484px 宽**的 PGS 位图
  /// **拉伸 3.97 倍**到整屏宽 ⇒ 高度变成 449px ⇒ **超出画面底部被裁**
  ///（用户报"字幕的大小也有问题"，截图里英文行下缘被切）。
  ///
  /// 根因：PGS 位图**不是**整幅构图平面 —— Media3 已按 `PgsParser` 的
  /// 输出**裁掉透明边**（实测尺寸 `484x113` / `351x104` / `1281x113`）。
  /// ⇒ "该画多大"**不能从位图像素推**，必须用 cue 自带的比例字段。
  ///
  /// ## 降级链（三层，保证任何内核都能画）
  /// 1. `size` + `bitmapHeight` 都有效 ⇒ **完全按官方公式**
  /// 2. 只有 `size` ⇒ 宽度按官方，高度按位图宽高比等比（官方兜底分支）
  /// 3. 都没有（缺字段）⇒ 退回按位图像素等比缩放并**限制在画面内**
  Positioned _positionedBitmap(SubtitleCue c, Rect vr) {
    final img = _cache[_keyOf(c.pngBytes!)];
    if (img == null) {
      // 还在解码：这一帧先不画（下一帧 setState 会补上）
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }

    // ── 宽度：官方 `parentWidth * size` ──
    final sizeRatio = c.size;
    final width = (sizeRatio != null && sizeRatio > 0 && sizeRatio <= 1)
        ? vr.width * sizeRatio
        // 降级：按位图宽占比（位图可能已被裁切 ⇒ 只是近似）
        : vr.width;

    // ── 高度：官方 `parentHeight * bitmapHeight`，兜底按宽高比 ──
    final bh = c.bitmapHeight;
    double height;
    if (bh != null && bh > 0 && bh <= 1) {
      height = vr.height * bh;
    } else {
      // 官方兜底分支：`width * (bitmap.h / bitmap.w)`
      height = width * (img.height / img.width);
    }

    // ── 位置（官方 anchor 语义）──
    // 横向：`Cue.position`（视口宽度比例）+ `positionAnchor`
    // 纵向：`Cue.line`（视口高度比例）+ `lineAnchor`
    //
    // ⚠️ 缺字段时用"底部居中"这个 PGS 默认（绝大多数 PGS 都在底部）
    double left;
    final pos = c.position;
    if (pos != null && pos >= 0 && pos <= 1) {
      final anchorX = vr.left + vr.width * pos;
      left = switch (c.positionAnchor) {
        1 => anchorX, // ANCHOR_TYPE_START
        2 => anchorX - width / 2, // ANCHOR_TYPE_MIDDLE
        3 => anchorX - width, // ANCHOR_TYPE_END
        _ => anchorX - width / 2,
      };
    } else {
      left = vr.left + (vr.width - width) / 2;
    }

    double top;
    final line = c.line;
    // `lineType` 1=FRACTION 2=NUMBER（见 Media3 `Cue.LINE_TYPE_*`）
    if (c.lineType == 1 && line != null && line >= 0 && line <= 1) {
      final anchorY = vr.top + vr.height * line;
      top = switch (c.lineAnchor) {
        1 => anchorY, // START
        2 => anchorY - height / 2, // MIDDLE
        3 => anchorY - height, // END
        _ => anchorY - height / 2,
      };
    } else {
      // 缺位置信息 ⇒ 贴视频**底部**（PGS 默认位置）
      top = vr.bottom - height;
    }

    // ★★ **兜底：贴画面底部并水平居中**（用户要求："字幕应该放置底部的中间"）
    //
    // ## 为什么需要这个兜底（真机截图取证）
    // PGS 的 `line` 是 **`bitmapY / planeHeight`**（见 `PgsParser` 源码）——
    // 那是位图在**构图平面**里的位置。而 Media3 已把位图**裁掉透明边**，
    // 因此 `line` 反映的是"裁切前的位置"，与裁切后的位图高度**不匹配**
    // ⇒ 直接套用会把字幕推到画面外或偏上（实测：字幕整体不可见/偏移）。
    //
    // 用户明确要求"底部的中间"，且这也符合主流播放器行为。
    //
    // ⇒ 策略：**以官方公式为初值，但夹取到画面内，并保证水平居中**
    //   （水平居中覆盖 `position`/`positionAnchor` —— PGS 的 position
    //    同样有"裁切前坐标"问题）
    //
    // ⚠️ 若将来发现某些 PGS 确实需要非居中位置（极罕见），
    //    可加开关；当前以"看得见、位置正确"为优先。
    left = vr.left + (vr.width - width) / 2;
    // 贴底部（留一点边距，与主流播放器一致）
    final bottomPad = vr.height * 0.03;
    top = vr.bottom - height - bottomPad;

    // ★ 兜底夹取：任何情况下都**不能超出画面**
    //（否则就是用户看到的"字幕被裁"）
    if (top + height > vr.bottom) top = vr.bottom - height;
    if (top < vr.top) top = vr.top;
    if (left + width > vr.right) left = vr.right - width;
    if (left < vr.left) left = vr.left;

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
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
