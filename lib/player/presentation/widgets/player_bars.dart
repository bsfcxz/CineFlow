/// 顶栏（规格 §7.2）。
///
/// 左：返回按钮；中：文件名（单行、省略号）；**右：不放锁按钮**
/// （锁按钮已浮动到中部右侧，见 §7.5 —— 放两处会让用户困惑哪个是真的）。
library;

import 'package:flutter/material.dart';
import 'player_gesture_layer.dart';

import '../player_ui_tokens.dart';
import 'glass.dart';

class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({
    super.key,
    required this.title,
    required this.onBack,
    this.subtitle,
    this.onBackKey,
  });

  final String title;
  final VoidCallback onBack;

  /// 可选副标题（如"第 3 集 · 1080p"）。
  final String? subtitle;
  final Key? onBackKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 4),
        // ---- 返回按钮：半透明圆底 + ≥48dp 命中区（用户要求，2026-10-09）----
        //
        // ## 为什么加圆底
        // 顶栏压在视频上，纯白箭头压亮画面会看不清（"白字压白墙"）。
        // 圆底给图标一个**稳定的衬底**，比只靠阴影更可靠。
        //
        // ## ⚠️ 刻意**不加** `BackdropFilter`（与第 31/33 轮的决定一致）
        // 用户曾三轮反馈"模糊本身就是遮挡视频的根源"：
        //   `BackdropFilter(blur)` 会**修改其区域的视频像素**（哪怕填充全透明）
        //   ⇒ 用户看到"这块是糊的" = 被遮挡。
        // 故这里只用 **`Colors.black26` 半透明填充**（不模糊任何像素）——
        // 观感上仍是"圆形背景"，但**不处理背后画面**。
        //
        // ## 命中区
        // `IconButton` 默认即 `kMinInteractiveDimension = 48×48`；
        // 这里**显式**写出，避免将来有人改主题时静默变小（`visualDensity` 会改它）。
        IconButton(
          key: onBackKey,
          onPressed: onBack,
          icon: Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: Colors.black26,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.arrow_back, size: 20),
          ),
          color: Colors.white,
          iconSize: 20,
          tooltip: '返回',
          // 显式 48dp（视觉 36dp，命中 48dp —— U5/U8 已确立的纪律）
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          padding: EdgeInsets.zero,
        ),
        Expanded(
          // ★ 用户要求：顶部标题**合并为单行**
          //
          // ## 为什么改（原先两行）
          // 原实现是 `Column(title, subtitle)` —— 竖屏下占两行高度，
          // 而顶栏压在视频上，两行会把画面挤得更小、也更挡视线。
          //
          // ## 怎么合并
          // `title` 与 `subtitle` 用 ` · ` 拼成一行；subtitle 为空时
          // **不留下多余的间隔符**（否则末尾会出现一个孤立的 `·`）。
          //
          // ⚠️ 两者**不是同一个值**（第 46 轮修过"顶栏集数重复显示"）：
          //    title    = `第 N 集 · 本集名`
          //    subtitle = 剧名
          //    合并后 = `第 N 集 · 本集名 · 剧名`
          //    若两者相同（异常数据），只显示一次 —— 防重复。
          child: Text(
            _mergedTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
            ),
          ),
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  /// 合并后的单行标题。
  ///
  /// 抽成 getter 是**为了可测**：单行合并的边界（无 subtitle / 两者相同 /
  /// subtitle 为空串）在这里可精确断言，不必起 UI。
  String get _mergedTitle {
    final s = subtitle;
    if (s == null || s.isEmpty) return title;
    // 两者相同 ⇒ 只显示一次（否则会出现 `X · X`）
    if (s == title) return title;
    return '$title · $s';
  }
}

/// 中部三键（规格 §7.3）：快退 10s / 播放暂停(72) / 快进 10s。
class PlayerCenterControls extends StatelessWidget {
  const PlayerCenterControls({
    super.key,
    required this.isPlaying,
    required this.onTogglePlay,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.hitTest,
    this.stepSeconds = 10,
    this.playKey,
    this.backKey,
    this.forwardKey,
  });

  final bool isPlaying;
  final VoidCallback onTogglePlay;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final int stepSeconds;
  final Key? playKey;
  final Key? backKey;
  final Key? forwardKey;

  /// 命中标记（见 UiElementDetector 注释）。
  ///
  /// ⚠️ 探测必须包在**每个按钮**上，而不是整行：若包整行（更不能包
  /// Positioned.fill），opaque Listener 会吃掉全屏的按下事件，
  /// 底层手势层收不到任何指针 → "点视频区隐藏/滑动 seek/长按倍速"
  /// 全部失效（2026-10-07 真机实测抓到，按钮却一切正常，极难排查）。
  final UiElementHitTest hitTest;

  @override
  Widget build(BuildContext context) {
    Widget detect(Widget child) => UiElementDetector(
          hitTest: hitTest,
          child: child,
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        detect(GlassButton(
          key: backKey,
          icon: Icons.replay_10,
          onTap: onSeekBack,
          semanticLabel: '快退 $stepSeconds 秒',
        )),
        const SizedBox(width: 28),
        // 中央播放/暂停更大（72 vs 56）—— 它是最高频的操作
        detect(GlassButton(
          key: playKey,
          icon: isPlaying ? Icons.pause : Icons.play_arrow,
          onTap: onTogglePlay,
          size: PlayerUi.playButtonSize,
          iconSize: 36,
          semanticLabel: isPlaying ? '暂停' : '播放',
        )),
        const SizedBox(width: 28),
        detect(GlassButton(
          key: forwardKey,
          icon: Icons.forward_10,
          onTap: onSeekForward,
          semanticLabel: '快进 $stepSeconds 秒',
        )),
      ],
    );
  }
}

/// 底部栏（规格 §7.4）：两行 —— 进度条 + 操作按钮。
class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
    required this.progress,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.actions,
    this.buffered,
    this.showRemaining = false,
    this.onToggleTimeDisplay,
    this.progressKey,
    this.chapters = const [],
  });

  /// 0.0–1.0。
  final double progress;
  final Duration position;
  final Duration duration;

  /// 章节起点（秒）—— 直接透传给 [PlayerProgressBar]。
  ///
  /// 默认空列表：本组件在"无章节"场景（绝大多数电影）下行为不变，
  /// 不会因为新增参数而画出多余的东西。
  final List<double> chapters;

  /// 缓冲进度 0.0–1.0（可选）。
  final double? buffered;

  final ValueChanged<double> onSeek;

  /// 第二行的按钮组（由 PlayerPage 组装，避免本组件依赖各 Controller）。
  final Widget actions;

  /// 时间显示是否切到"剩余"（原型：点时间可切换）。
  final bool showRemaining;
  final VoidCallback? onToggleTimeDisplay;
  final Key? progressKey;

  /// `mm:ss` / `h:mm:ss`。
  static String format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final remaining = duration - position;
    final remainText = remaining.isNegative ? Duration.zero : remaining;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlayerProgressBar(
          key: progressKey,
          progress: progress,
          buffered: buffered,
          onSeek: onSeek,
          chapters: chapters,
          duration: duration,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // 等宽数字：否则秒数变化时整行会左右抖动
              GestureDetector(
                onTap: onToggleTimeDisplay,
                child: Text(
                  showRemaining
                      ? '-${format(remainText)}'
                      : format(position),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                    shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                  ),
                ),
              ),
              const Spacer(),
              Text(
                format(duration),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        actions,
        const SizedBox(height: 6),
      ],
    );
  }
}

/// 自绘进度条（规格 §7.4：拖动时轨道变粗 + 出现滑块）。
///
/// ## 为什么自绘而不用 `Slider`
/// `Slider` 难以实现"拖动时轨道从 3dp 长到 6dp + 拇指淡入"这种细节，
/// 且它的命中区与视觉绑定（要额外包 Padding 才达标）。
/// 自绘能同时给足**48dp 命中区**与 3dp 视觉细线。
class PlayerProgressBar extends StatefulWidget {
  const PlayerProgressBar({
    super.key,
    required this.progress,
    required this.onSeek,
    this.buffered,
    this.chapters = const [],
    this.duration,
  });

  final double progress;
  final double? buffered;
  final ValueChanged<double> onSeek;

  /// 章节起点（**秒**，服务端 `MediaChapter.seconds` 原值）。
  ///
  /// ## 为什么传秒而不是 0–1 的分数
  /// 分数依赖 `duration`，而 `duration` 在起播早期是 0（容器还没探测完）——
  /// 若由调用方换算，就会把"duration 未知"和"章节在第 0 秒"混为一谈。
  /// 传原值 + 这里拿 `duration` 现算，**换算只发生在这一个地方**。
  final List<double> chapters;

  /// 总时长 —— 用来把 [chapters] 换算成 0–1 的分数。
  /// 为 0 或 null 时**不画刻度**（否则除数无意义）。
  final Duration? duration;

  @override
  State<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends State<PlayerProgressBar> {
  /// 拖动中的临时值（null = 未拖动，用外部 progress）。
  double? _dragValue;

  bool get _dragging => _dragValue != null;

  void _updateFromLocal(double dx, double width) {
    if (width <= 0) return;
    setState(() => _dragValue = (dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final value = _dragValue ?? widget.progress.clamp(0.0, 1.0);

    // 章节刻度位置（0–1）。换算只在这里发生（见 [PlayerProgressBar.chapters]）。
    //
    // ⚠️ `duration` 为 0 时**不画** —— 起播早期容器还没探测完，
    //    此时除法会得到 Infinity/NaN，画出来是错位的线或直接报错。
    final totalMs = widget.duration?.inMilliseconds ?? 0;
    final ticks = totalMs > 0
        ? [
            for (final s in widget.chapters)
              (s * 1000 / totalMs).clamp(0.0, 1.0),
          ]
        : const <double>[];

    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return Semantics(
          slider: true,
          label: '播放进度',
          value: '${(value * 100).round()}%',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              _updateFromLocal(d.localPosition.dx, width);
            },
            onTapUp: (d) {
              widget.onSeek(_dragValue ?? value);
              setState(() => _dragValue = null);
            },
            onHorizontalDragStart: (d) {
              _updateFromLocal(d.localPosition.dx, width);
            },
            onHorizontalDragUpdate: (d) {
              _updateFromLocal(d.localPosition.dx, width);
            },
            onHorizontalDragEnd: (_) {
              widget.onSeek(_dragValue ?? value);
              setState(() => _dragValue = null);
            },
            onHorizontalDragCancel: () => setState(() => _dragValue = null),
            child: SizedBox(
              // 命中区 48dp（视觉只有 3–6dp）
              height: PlayerUi.progressHitHeight,
              child: Center(
                child: SizedBox(
                  height: _dragging
                      ? PlayerUi.progressTrackHeightDragging
                      : PlayerUi.progressTrackHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 底轨
                      Container(
                        decoration: BoxDecoration(
                          color: PlayerUi.progressTrack,
                          borderRadius: BorderRadius.circular(PlayerUi.progressRadius),
                        ),
                      ),
                      // 缓冲段
                      if (widget.buffered case final b?)
                        FractionallySizedBox(
                          widthFactor: b.clamp(0.0, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: PlayerUi.progressBuffer,
                              borderRadius: BorderRadius.circular(PlayerUi.progressRadius),
                            ),
                          ),
                        ),
                      // 已播段
                      FractionallySizedBox(
                        widthFactor: value,
                        child: Container(
                          decoration: BoxDecoration(
                            color: PlayerUi.progressFilled,
                            borderRadius: BorderRadius.circular(PlayerUi.progressRadius),
                          ),
                        ),
                      ),
                      // 章节刻度
                      //
                      // ## 为什么画在"已播段"之上
                      // 刻度是**导航参考**（"这集分几段、现在到哪段"），
                      // 若被已播段盖住，划过之后就看不见了 —— 那正好是
                      // 用户最需要它的时候。故放最后（Stack 后者在上）。
                      //
                      // ## 为什么跳过首尾
                      // 第 0 秒的刻度与左端点重合、末尾的与右端点重合，
                      // 画出来只是两条"加粗的端点"，纯噪声。
                      for (final t in ticks)
                        if (t > 0.002 && t < 0.998)
                          Positioned(
                            left: (width * t) - PlayerUi.chapterTickWidth / 2,
                            top: 0,
                            bottom: 0,
                            child: Container(
                              width: PlayerUi.chapterTickWidth,
                              decoration: BoxDecoration(
                                color: PlayerUi.chapterTick,
                                borderRadius:
                                    BorderRadius.circular(PlayerUi.chapterTickWidth / 2),
                              ),
                            ),
                          ),
                      // 拖动时的拇指
                      if (_dragging)
                        Positioned(
                          left: (width * value) - PlayerUi.progressThumbSize / 2,
                          top: -(PlayerUi.progressThumbSize -
                                  PlayerUi.progressTrackHeightDragging) /
                              2,
                          child: Container(
                            width: PlayerUi.progressThumbSize,
                            height: PlayerUi.progressThumbSize,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  blurRadius: 6,
                                  color: Colors.black38,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
