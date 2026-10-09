/// 播放器 UI 组装页（按 HTML 原型实现）—— 把状态层、手势层、各组件接起来。
///
/// ## 与既有 `player_page.dart` 的关系
/// 既有文件 2815 行，把播放/手势/面板/弹幕/上报全混在一起（规格明确禁止）。
/// 本文件是**按新分层重建的播放页**，旧的暂留不动（渐进迁移，降低风险）：
///   · 旧页继续服务现有 Emby 流程（选集/上报/自动连播）
///   · 新页实现原型要求的 UI/交互（手势/面板/全屏/弹幕面板）
///
/// ## 本文件的职责边界（严格遵守）
/// 它**只做组装**：
///   · 渲染视频帧（由上层把 `videoView` 传进来 —— 不直接碰内核）
///   · 把指针事件转给 `GestureController`
///   · 把 Controller 状态转给各 Widget
///   · 把各 Widget 的回调转给 Controller
/// **不含**任何手势判定、状态计算、单位换算 —— 那些都在各自文件里且有测试。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/providers/player_providers.dart';
import '../domain/models/media_state.dart';
import '../domain/models/panel_state.dart';
import '../domain/player_constants.dart';
import 'panels/player_danmaku_panel.dart';
import 'panels/player_panel_host.dart';
import 'panels/player_playlist_panel.dart';
import 'panels/player_settings_panel.dart';
import 'player_ui_tokens.dart';
import 'widgets/glass.dart';
import 'widgets/player_action_bar.dart';
import 'widgets/player_bars.dart';
import 'widgets/player_feedback.dart';
import 'widgets/player_gesture_layer.dart';
import '../../keys.dart';

/// 播放页回调（把"与内核/Emby 的交互"留给调用方）。
class PlayerPageCallbacks {
  const PlayerPageCallbacks({
    required this.onTogglePlay,
    required this.onSeekBy,
    required this.onSeekTo,
    required this.onSpeedChanged,
    required this.onVolumeChanged,
    required this.onBrightnessChanged,
    required this.onAspectModeChanged,
    required this.onFullscreenToggled,
    required this.onBack,
    required this.onSelectMedia,
    required this.onPrevious,
    required this.onNext,
    required this.onSelectAudioTrack,
    required this.onSelectSubtitleTrack,
    required this.onImportSubtitle,
    required this.onImportDanmaku,
    required this.onMatchDanmaku,
    required this.onVideoFilterChanged,
    required this.onResetFilters,
    required this.onAudioDelayChanged,
    required this.onSubtitleDelayChanged,
    required this.onSubtitleFontSizeChanged,
    required this.onSubtitleEncodingChanged,
  });

  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeekBy;
  final ValueChanged<Duration> onSeekTo;
  final ValueChanged<double> onSpeedChanged;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onBrightnessChanged;
  final ValueChanged<AspectMode> onAspectModeChanged;
  final VoidCallback onFullscreenToggled;
  final VoidCallback onBack;
  final ValueChanged<int> onSelectMedia;

  /// 上一集 / 下一集。
  ///
  /// ## 为什么必须走宿主（而不是 UI 层自己调 `playlist.previous()`）
  /// `previous()/next()` **只改列表的选中项**，不产生任何播放行为 ——
  /// 宿主拿到通知后才去 `_playEpisode()`。
  ///
  /// 曾经的实现是 UI 层直接调 `previous()/next()`，于是：
  /// 【列表高亮变了，但画面永远不换】= 用户说的"上下集按钮无用"。
  /// **根因是这两个契约当时根本不存在** —— 不是忘了接，是无处可接。
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<String> onSelectAudioTrack;
  final ValueChanged<String?> onSelectSubtitleTrack;
  final VoidCallback onImportSubtitle;
  final VoidCallback onImportDanmaku;
  final VoidCallback onMatchDanmaku;
  final void Function({double? brightness, double? contrast,
      double? saturation, double? hue}) onVideoFilterChanged;
  final VoidCallback onResetFilters;
  final ValueChanged<Duration> onAudioDelayChanged;
  final ValueChanged<Duration> onSubtitleDelayChanged;
  final ValueChanged<SubtitleFontSize> onSubtitleFontSizeChanged;
  final ValueChanged<SubtitleEncoding> onSubtitleEncodingChanged;
}

/// 播放页外观数据（标题、视频层、弹幕层等由调用方注入）。
class PlayerPageSlots {
  const PlayerPageSlots({
    required this.title,
    required this.video,
    this.subtitle,
    this.danmakuLayer,
    this.buffered,
    this.chapters = const [],
  });

  final String title;

  /// 视频帧（`Texture` / `PlatformView` 由调用方构造 —— 本页不碰内核）。
  final Widget video;
  final String? subtitle;

  /// 弹幕渲染层（复用既有 `lib/danmaku/` 的 overlay）。
  final Widget? danmakuLayer;

  /// 缓冲进度 0.0–1.0。
  final double? buffered;

  /// 章节起点（**秒**）—— 供进度条画刻度。
  ///
  /// ## 为什么放在 slots 而不是让 UI 自己去取
  /// 章节来自 `PlaybackLaunch.chapters`（服务端已在 `PlaybackInfo` 里给好），
  /// **只有宿主页拿得到** —— 本页不碰 `MediaProvider`（架构约定 §5.1）。
  /// 故由宿主经 slots 传入，与 [buffered] 同一模式。
  ///
  /// 默认空列表：无章节的片源（多数电影）行为完全不变。
  final List<double> chapters;
}

/// 组装后的播放页。
class PlayerUiPage extends ConsumerStatefulWidget {
  const PlayerUiPage({
    super.key,
    required this.slots,
    required this.callbacks,
  });

  final PlayerPageSlots slots;
  final PlayerPageCallbacks callbacks;

  @override
  ConsumerState<PlayerUiPage> createState() => _PlayerUiPageState();
}

class _PlayerUiPageState extends ConsumerState<PlayerUiPage> {
  final _hitTest = UiElementHitTest();

  /// 视频区域尺寸（手势映射需要宽高）。
  Size _videoSize = Size.zero;

  /// 单击/双击判定（原型 §9.4：250ms 内第二次点击 = 双击）。
  int _tapCount = 0;
  bool _showRemaining = false;


  @override
  void initState() {
    super.initState();
    // Controller 之间的回调注入（在首帧后做，避免 build 期改状态）
    WidgetsBinding.instance.addPostFrameCallback((_) => _wire());
  }

  /// 把 Controller 互相接起来（依赖注入点）。
  ///
  /// ⚠️ 放在 `addPostFrameCallback` 里：在 `build` 期调用 `read().notifier`
  /// 并**修改状态**会触发 "setState during build" 断言。
  void _wire() {
    if (!mounted) return;
    final ui = ref.read(uiVisibilityProvider.notifier);
    final panel = ref.read(panelStateProvider.notifier);

    // 自动隐藏的三条守卫数据来源（单向依赖，见 providers 的说明）
    ui.isPlaying = () => ref.read(playbackStateProvider).isPlaying;
    ui.hasOpenPanel = () => ref.read(panelStateProvider).open != PanelType.none;

    // 面板开合影响 UI 显隐（规格 §10.2 / §10.3）
    panel.onOpened = () {
      ref.read(uiVisibilityProvider.notifier).show();
      ref.read(gestureStateProvider.notifier).abort();
    };
    panel.onClosed = () => ref.read(uiVisibilityProvider.notifier).scheduleHide();

    // 手势层回调
    final g = ref.read(gestureStateProvider.notifier);
    g.onLongPressStart = () =>
        ref.read(playbackStateProvider.notifier).startLongPress();
    g.onLongPressEnd =
        () => ref.read(playbackStateProvider.notifier).endLongPress();
    g.onSeek = (target) => widget.callbacks.onSeekTo(target);
    g.onSeekPreview = (_) {};

    // ---- 亮度 / 音量：**真的去执行**（真机 bug 修复，2026-10-07）----
    //
    // ## 原来的问题（用户实测反馈）
    // 手势控制器算出了 brightness/volume 并写进 state，
    // 但那个值**只被指示器用于画圆环** —— 没有人应用到屏幕/系统。
    // 现象：左右滑动时圆环数字在变，**画面亮度与声音纹丝不动**。
    //
    // ## 修法
    // 组装页不直接调 Android API（那是宿主页的职责，见 `PlayerPageCallbacks`），
    // 故这里转发给宿主提供的 `onBrightnessChanged` / `onVolumeChanged`。
    //
    // ⚠️ 单位：手势侧 0–100，`onVolumeChanged` 契约是 **0.0–1.0**
    //    （见 `PlayerPageCallbacks` 注释与 `volumeToKernel` 的换算），
    //    故这里除以 100。写错会导致"一滑就满音量"或"永远静音"。
    g.onBrightness = (v) => widget.callbacks.onBrightnessChanged(v);
    g.onVolume = (v) => widget.callbacks.onVolumeChanged(v / 100);

    // 视频参数变化 → 交给调用方落内核
    ref.read(videoStateProvider.notifier).onChanged = (v) {
      widget.callbacks.onVideoFilterChanged(
        brightness: v.brightness,
        contrast: v.contrast,
        saturation: v.saturation,
        hue: v.hue,
      );
    };
    ref.read(audioStateProvider.notifier).onChanged = (a) {
      widget.callbacks.onVolumeChanged(a.volume);
      widget.callbacks.onAudioDelayChanged(a.delay);
    };
    ref.read(subtitleStateProvider.notifier).onChanged = (s) {
      widget.callbacks.onSubtitleDelayChanged(s.delay);
      widget.callbacks.onSubtitleFontSizeChanged(s.fontSize);
    };
    // 选集回调：转发"**被选中 entry 的下标**"给上层。
    //
    // ⚠️ 两点约束（都踩过）：
    // 1. **只转发，不调 `select()`** —— `select()` 正是本回调的调用者，
    //    再调一次就是递归（原实现就是这么写的）。
    // 2. 用 `e.id` 反查下标，而不是直接用 `currentIndex` ——
    //    正常路径下两者相同（`select()` 先更新 currentIndex 再回调），
    //    但传"用户实际点的那一项"语义更准，也不受将来
    //    `select()` 实现变化影响。
    ref.read(playlistStateProvider.notifier).onSelect = (e) {
      final entries = ref.read(playlistStateProvider).entries;
      final i = entries.indexWhere((x) => x.id == e.id);
      widget.callbacks.onSelectMedia(i >= 0 ? i : 0);
    };

    // 倍速变化 → 落内核
    ref.listenManual(playbackStateProvider, (prev, next) {
      if (prev?.effectiveSpeed != next.effectiveSpeed) {
        widget.callbacks.onSpeedChanged(next.effectiveSpeed);
      }
    });

    // 初始显示控制层并开始计时
    ref.read(uiVisibilityProvider.notifier).show();
  }

  @override
  void dispose() {
    // 恢复系统 UI 由调用方负责（它才知道要不要退横屏）
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(playbackStateProvider);
    final ui = ref.watch(uiVisibilityProvider);
    final gesture = ref.watch(gestureStateProvider);
    final panel = ref.watch(panelStateProvider);
    final playlist = ref.watch(playlistStateProvider);
    final video = ref.watch(videoStateProvider);
    final audio = ref.watch(audioStateProvider);
    final subtitle = ref.watch(subtitleStateProvider);
    final danmaku = ref.watch(danmakuPanelProvider);
    final info = ref.watch(mediaInfoProvider);

    return Scaffold(
      key: keys.player.page,
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, box) {
          _videoSize = Size(box.maxWidth, box.maxHeight);
          return Stack(
            children: [
              // ---- 1. 视频层（最底）----
              Positioned.fill(child: widget.slots.video),

              // ---- 2. 弹幕层（视频之上、控制层之下；不吃手势）----
              if (widget.slots.danmakuLayer case final d?)
                Positioned.fill(
                  key: keys.player.danmakuOverlay,
                  child: IgnorePointer(child: d),
                ),

              // ---- 3. 手势层（必须在 UI 元素之下，见 player_gesture_layer 说明）----
              Positioned.fill(
                key: keys.player.videoGestureArea,
                child: PlayerGestureLayer(
                  hitTest: _hitTest,
                  enabled: !ui.isLocked && panel.open == PanelType.none,
                  onPointerDown: (p) => ref
                      .read(gestureStateProvider.notifier)
                      .onPointerDown(
                        position: p,
                        currentPosition: playback.position,
                        brightness: 50, // 起点由调用方经服务读取后同步
                        volume: audio.volume * 100,
                      ),
                  onPointerMove: (p) => ref
                      .read(gestureStateProvider.notifier)
                      .onPointerMove(
                        position: p,
                        area: _videoSize,
                        total: playback.duration,
                      ),
                  onPointerUp: () {
                    final wasTap = ref
                        .read(gestureStateProvider.notifier)
                        .onPointerUp();
                    if (wasTap) _handleTap();
                  },
                  onPointerCancel: () =>
                      ref.read(gestureStateProvider.notifier).onPointerCancel(),
                ),
              ),

              // ---- 4. 反馈层（亮度/音量/快进/长按倍速）----
              Positioned.fill(
                child: PlayerFeedbackLayer(
                  gesture: gesture,
                  isLongPressing: playback.isLongPressing,
                  longPressSpeed: playback.longPressSpeed,
                ),
              ),

              // ---- 5. 控制层（可显隐）----
              if (ui.controlsVisible) ..._controls(playback, ui, playlist,
                  video, audio, subtitle, danmaku, info, panel),

              // ---- 6. 锁按钮（独立于控制层，锁定时常亮）----
              // 规格 §7.5：浮动在中部右侧
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: UiElementDetector(
                    hitTest: _hitTest,
                    child: GlassCircle(
                      key: keys.player.lockButton,
                      icon: ui.isLocked ? Icons.lock : Icons.lock_open,
                      active: ui.isLocked,
                      onTap: () =>
                          ref.read(uiVisibilityProvider.notifier).toggleLock(),
                      semanticLabel: ui.isLocked ? '解锁' : '锁定',
                    ),
                  ),
                ),
              ),

              // ---- 7. 面板遮罩 + 抽屉（用 UiElementDetector 包住整层，
              //         避免点击面板时触发底层手势）----
              if (panel.open != PanelType.none)
                Positioned.fill(
                  child: UiElementDetector(
                    hitTest: _hitTest,
                    child: PlayerPanelHost(
                      state: panel,
                      onClose: () =>
                          ref.read(panelStateProvider.notifier).closeAll(),
                      playlist: PlayerPlaylistPanel(
                        state: playlist,
                        onClose: () =>
                            ref.read(panelStateProvider.notifier).closeAll(),
                        onCycleMode: () =>
                            ref.read(playlistStateProvider.notifier).cycleMode(),
                        onSelect: (i) =>
                            ref.read(playlistStateProvider.notifier).select(i),
                      ),
                      settings: PlayerSettingsPanel(
                        tab: panel.settingsTab,
                        data: SettingsPanelData(
                          video: video,
                          audio: audio,
                          subtitle: subtitle,
                          info: info,
                        ),
                        actions: _settingsActions(panel),
                      ),
                      danmaku: PlayerDanmakuPanel(
                        state: danmaku,
                        onToggle: (v) => ref
                            .read(danmakuPanelProvider.notifier)
                            .setEnabled(v),
                        onOpacity: (v) => ref
                            .read(danmakuPanelProvider.notifier)
                            .setOpacity(v),
                        onFontSize: (f) => ref
                            .read(danmakuPanelProvider.notifier)
                            .setFontSize(f),
                        onSpeedLevel: (l) => ref
                            .read(danmakuPanelProvider.notifier)
                            .setSpeedLevel(l),
                        onArea: (a) =>
                            ref.read(danmakuPanelProvider.notifier).setArea(a),
                        onImportLocal: widget.callbacks.onImportDanmaku,
                        onMatchOnline: widget.callbacks.onMatchDanmaku,
                        onClose: () =>
                            ref.read(panelStateProvider.notifier).closeAll(),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 单击 / 双击判定（规格 §9.4）。
  ///
  /// ⚠️ 用 `Future.delayed` 而不是 Timer 字段：这里只需要"等 250ms 看有没有
  /// 第二次点击"，且必须处理 widget 已销毁的情况（`mounted` 检查）。
  /// 第一次点击时控制层是否可见（双击判定需要它来"恢复可见"）。
  bool _tapStartedVisible = false;

  void _handleTap() {
    final uiCtl = ref.read(uiVisibilityProvider.notifier);

    _tapCount++;
    if (_tapCount == 1) {
      _tapStartedVisible = ref.read(uiVisibilityProvider).visible;

      // ★ **可见时立即隐藏**（用户要求"点击后马上就能隐藏"，不等 250ms）
      //
      // ## 为什么可以立即隐藏，同时还能保住双击
      // 隐藏只是"把控制层收起来"，**不改 `_tapCount`** ——
      // 双击判定照常进行。若第二次点击在窗口内到达，走下面的 else
      // 分支：**恢复可见 + 播放/暂停**（否则双击会"闪一下"）。
      //
      // ⚠️ 我第一版在这里直接 `return`，把 `_tapCount` 也清零了 ——
      //    结果第二次点击被当成"新的第一次单击"，**双击彻底失效**。
      //    被 `test/player_tap_test.dart` 的 2 例抓住（那是本仓的真实防线）。
      if (_tapStartedVisible) uiCtl.hide();

      Future<void>.delayed(PlayerGestures.tapDelay, () {
        if (!mounted) return;
        if (_tapCount == 1) {
          // 250ms 内没有第二次 ⇒ 确认是单击
          // · 原本可见 → 已在上面立即隐藏，无需再动
          // · 原本隐藏 → 此刻才唤出（延时不可避免：否则双击会闪一下）
          if (!_tapStartedVisible) uiCtl.show();
        }
        _tapCount = 0;
      });
    } else {
      // 双击：播放/暂停
      _tapCount = 0;
      // 若第一次点击把控制层藏了，这里恢复 —— 双击不该顺带隐藏 UI
      if (_tapStartedVisible) uiCtl.show();
      widget.callbacks.onTogglePlay();
    }
  }

  /// 控制层（顶栏 + 中部三键 + 底栏）。
  List<Widget> _controls(
    dynamic playback,
    dynamic ui,
    dynamic playlist,
    dynamic video,
    dynamic audio,
    dynamic subtitle,
    dynamic danmaku,
    dynamic info,
    PanelState panel,
  ) {
    return [
      // 顶栏（含渐变压暗）
      //
      // ══════════════════════════════════════════════════════════════
      // ★★ 2026-10-09 修：横屏下返回键/标题被推到屏幕 1/3 处
      // ══════════════════════════════════════════════════════════════
      //
      // ## 症状（用户截图 + 真机实测）
      // 横屏 2400x1080 下：
      //     返回按钮  [102,341][234,473]   y1 = 31.6%
      //     标题      [234,356][1028,414]   y1 = 33.0%
      // 而它**应该**贴左上角（y ≈ 1%）。
      //
      // ## 根因：`BarScrim` 被当成**布局子节点**
      // 原结构是：
      //     Column(children: [ BarScrim(height: 120), Padding(顶栏) ])
      // `BarScrim` 本该是一层**背景**，但放进 `Column` 后它**占掉 120dp 布局高度**
      // ⇒ 顶栏被整体向下推 120dp。
      //     120dp × 2.75(density) = 330px = 屏幕高的 30.6%
      // 与实测 y1=31.6% **精确吻合** ⇒ 根因确认。
      //
      // 横屏只有 1080px 高，这 330px 直接把顶栏压到中间偏上 ——
      // 观感上"返回键飘在半空"，且**遮住了更多视频内容**。
      //
      // ## 修法：用 `Stack` 把 `BarScrim` 变回**真正的背景**
      // `Stack` 的子节点**不参与彼此的布局** —— 渐变层铺满、顶栏内容
      // 由自己的 Padding 决定位置 ⇒ 互不挤压。
      //
      // ⚠️ 为什么不用 `Column + Positioned`：`Positioned` 只在 `Stack` 里有效。
      // ⚠️ 为什么不动底栏：底栏**没有** BarScrim（第 31 轮已换成透明布局，
      //    见 L557-575 的三轮迭代记录）⇒ 它本来就没这个问题。
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: UiElementDetector(
          hitTest: _hitTest,
          // ⚠️ `Stack` 要 `alignment: topLeft` —— 默认是 `topStart`（等价），
          //    但显式写出以表达意图（用户明确要求"不要 Center / centerLeft"）。
          child: Stack(
            alignment: Alignment.topLeft,
            children: [
              // ---- 背景渐变（不占布局：Stack 子节点各自独立）----
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: BarScrim(height: PlayerUi.topBarFade, fromTop: true),
              ),
              // ---- 顶栏内容（贴左上角，高度仅为内容高度）----
              Padding(
                // ★ 顶部安全区 + 用户指定的内边距（12dp 顶 / 24dp 左）
                //
                // ## 为什么用 `SafeArea` 而不是手算 `MediaQuery.paddingOf`
                // 二者等价，但 `SafeArea` 把"避开刘海/状态栏/挖孔"的意图写在类型上。
                // ⚠️ 保留 `MediaQuery.paddingOf` 的**显式参与**：`SafeArea` 的
                //    `minimum` 用不上"仅顶部"的语义（它会四边都加），故这里
                //    仍以 `MediaQuery.paddingOf(context).top` 表达"只关心顶部安全区"，
                //    再由 `SafeArea(bottom:false)` 兜住其余边。
                padding: EdgeInsets.only(
                  top: 12 + MediaQuery.paddingOf(context).top,
                  left: 24,
                ),
                child: SafeArea(
                  // bottom/left/right 不需要：顶栏只在顶部；
                  // 且左右已由上面的 24dp 显式给出（避免叠加成 48dp）
                  bottom: false,
                  left: false,
                  right: false,
                  child: Row(
                    key: keys.player.topBar,
                    children: [
                      // ⚠️ 必须 `Expanded`：`PlayerTopBar` 内部有 `Expanded`
                      //    （标题行要 `ellipsis` 收敛）—— 若外层不给有界宽度，
                      //    它会抛 "RenderFlex children have non-zero flex but
                      //    incoming width constraints are unbounded"（实测崩溃）。
                      //    而 `Positioned(top/left/right)` 已给出**有限宽度**
                      //    ⇒ 这里是安全的。
                      Expanded(
                        child: PlayerTopBar(
                          title: widget.slots.title,
                          subtitle: widget.slots.subtitle,
                          onBack: widget.callbacks.onBack,
                          onBackKey: keys.player.backButton,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),

      // 中部三键
      // ⚠️ 探测必须只在按钮上（PlayerCenterControls 内部逐按钮包裹）——
      // 曾在这里包过整行的 opaque Listener，吃掉行内全部按下事件（含
      // 按钮间隙），手势层收不到 → 点显隐/滑动 seek/长按倍速失灵。
      Positioned.fill(
        child: Center(
          child: PlayerCenterControls(
            hitTest: _hitTest,
            isPlaying: playback.isPlaying,
            onTogglePlay: widget.callbacks.onTogglePlay,
            onSeekBack: () =>
                widget.callbacks.onSeekBy(-PlayerGestures.step),
            onSeekForward: () =>
                widget.callbacks.onSeekBy(PlayerGestures.step),
            playKey: keys.player.togglePlayButton,
            backKey: keys.player.seekBackButton,
            forwardKey: keys.player.seekForwardButton,
          ),
        ),
      ),

      // 底栏（渐变压暗 + 玻璃面板）
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: UiElementDetector(
          hitTest: _hitTest,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ---- 底栏：**完全不影响视频**（用户第三轮反馈）----
              //
              // ## 三轮迭代的教训
              // 1. BarScrim 黑渐变 200dp → "要透明毛玻璃"
              // 2. 白色 8%→12% + blur 22 → "改成透明的"
              // 3. 填充全透明但**保留 blur(22)** → "仍会遮挡视频" ✓ 本轮
              //
              // ## 想通的关键
              // `BackdropFilter(ImageFilter.blur)` 的语义是"把背后已画好的
              // 内容模糊一遍再合成"。**即使填充全透明**，blur 也会修改
              // 工具栏区域的视频像素 —— 用户看到"这块是糊的" = 被遮挡。
              //
              // **"透明"在用户眼里 = 这块画面与其他地方一模一样，不被处理。**
              // 所以 BackdropFilter 必须整个去掉。
              //
              // ## 可读性靠什么（不放黑遮罩、不模糊）
              // 文字/图标的 `Shadow(blurRadius:6, color: black54)` ——
              // "白字压亮画面"的标准做法，不修改背景也能读。
              // （`PlayerBottomBar` 内每段 Text 已自带该阴影。）
              Padding(
                // 顶部留一点：进度条太贴屏幕下边缘的控件行会显得挤
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: PlayerBottomBar(
                    key: keys.player.controls,
                    progress: playback.progress,
                    position: playback.position,
                    duration: playback.duration,
                    buffered: widget.slots.buffered,
                    showRemaining: _showRemaining,
                    onToggleTimeDisplay: () =>
                        setState(() => _showRemaining = !_showRemaining),
                    progressKey: keys.player.progressBar,
                    chapters: widget.slots.chapters,
                    onSeek: (v) => widget.callbacks
                        .onSeekTo(playback.duration * v),
                    actions: PlayerActionBar(
                      speedLabel: PlayerSpeeds.label(playback.userSpeed),
                      hasPrevious: playlist.hasPrevious,
                      hasNext: playlist.hasNext,
                      danmakuEnabled: danmaku.enabled,
                      fullscreen: ui.fullscreen,
                      // ★ 用户要求：选集按钮显示「第几集 / 共几集」（如 3/24）
                      //
                      // ## 为什么在**调用方**组装字符串
                      // `PlayerActionBar` 刻意不依赖 `PlaylistState`
                      // （保持"只吃 props"的可测性，见其文件头）。
                      // 且"该不该显示"是个判断，放这里更清楚：
                      // · 列表只有 1 项（电影）⇒ 不显示 —— `1/1` 是无信息的噪声
                      // · 列表未就绪 ⇒ 不显示 —— 宁可少显示，也不要闪一个错的数字
                      playlistCount: playlist.entries.length > 1
                          ? '${playlist.currentIndex + 1}/'
                              '${playlist.entries.length}'
                          : null,
                      // ★ 转发给宿主（宿主才做得了"切集播放"）。
                      //    原实现直接调 `playlist.previous()/next()` ——
                      //    那只改列表高亮，画面不动 = 用户说的"无用"。
                      onPrevious: widget.callbacks.onPrevious,
                      onNext: widget.callbacks.onNext,
                      onCycleSpeed: () => ref
                          .read(playbackStateProvider.notifier)
                          .cycleSpeed(),
                      onOpenPlaylist: () => ref
                          .read(panelStateProvider.notifier)
                          .open(PanelType.playlist),
                      onToggleDanmaku: () =>
                          ref.read(danmakuPanelProvider.notifier).toggle(),
                      onOpenDanmakuSettings: () => ref
                          .read(panelStateProvider.notifier)
                          .open(PanelType.danmaku),
                      onOpenSettings: () => ref
                          .read(panelStateProvider.notifier)
                          .open(PanelType.settings),
                      onToggleFullscreen: widget.callbacks.onFullscreenToggled,
                      keys: {
                        'prev': keys.player.prevMediaButton,
                        'next': keys.player.nextMediaButton,
                        'playlist': keys.player.playlistButton,
                        'speed': keys.player.speedButton,
                        'danmakuToggle': keys.player.danmakuButton,
                        'danmakuSettings': keys.player.danmakuSettingsButton,
                        'settings': keys.player.settingsButton,
                        'fullscreen': keys.player.fullscreenButton,
                      },
                    ),
                ),
              ),
            ],
          ),
        ),
      ),
    ];  }

  SettingsPanelActions _settingsActions(PanelState panel) {
    final vid = ref.read(videoStateProvider.notifier);
    final aud = ref.read(audioStateProvider.notifier);
    final sub = ref.read(subtitleStateProvider.notifier);
    return SettingsPanelActions(
      onClose: () => ref.read(panelStateProvider.notifier).closeAll(),
      onTabChanged: (t) =>
          ref.read(panelStateProvider.notifier).switchSettingsTab(t),
      onAspectMode: (m) {
        vid.setAspectMode(m);
        widget.callbacks.onAspectModeChanged(m);
      },
      onDecodeMode: vid.setDecodeMode,
      onVideoFilter: ({brightness, contrast, saturation, hue}) {
        // 用**公开 setter**（各自带钳制），不碰私有 `_set` ——
        // 钳制范围（±100 / 色相 ±180）写在 setter 里，绕过去就失去了它。
        if (brightness != null) vid.setBrightness(brightness);
        if (contrast != null) vid.setContrast(contrast);
        if (saturation != null) vid.setSaturation(saturation);
        if (hue != null) vid.setHue(hue);
      },
      onResetFilters: vid.resetFilters,
      onAudioTrack: (id) {
        aud.selectTrack(id);
        widget.callbacks.onSelectAudioTrack(id);
      },
      onAudioDelay: aud.setDelay,
      onVolume: aud.setVolume,
      onSubtitleTrack: (id) {
        sub.selectTrack(id);
        widget.callbacks.onSelectSubtitleTrack(id);
      },
      onSubtitleDelay: sub.setDelay,
      onSubtitleFontSize: sub.setFontSize,
      onSubtitleEncoding: sub.setEncoding,
      onImportSubtitle: widget.callbacks.onImportSubtitle,
    );
  }
}
