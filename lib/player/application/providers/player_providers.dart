/// 播放器状态提供者 —— 所有 Controller 的**唯一装配点**。
///
/// ## 为什么单独一个文件
/// 9 个 Controller 之间有依赖（面板开门要阻止 UI 自动隐藏、
/// 手势结束要恢复倍速…）。若各自定义 provider，依赖会散落在各处、
/// 且容易写出循环（A watch B、B watch A → 运行时栈溢出）。
///
/// 集中在这里后，依赖方向**一眼可见**且是单向的：
///
/// ```
///   playback ─┐
///   panel ────┼─→ uiVisibility（读 isPlaying / hasOpenPanel）
///   gesture ──┘
///   video / audio / subtitle / danmaku / playlist   （互相独立）
/// ```
///
/// `uiVisibility` 通过**回调**读取另两个的状态，而不是 `ref.watch` ——
/// 避免在 Notifier 构造期触发重建循环。回调在首次 build 后注入。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/audio_controller.dart';
import '../controllers/danmaku_panel_controller.dart';
import '../controllers/gesture_controller.dart';
import '../controllers/panel_controller.dart';
import '../controllers/playback_controller.dart';
import '../controllers/playlist_controller.dart';
import '../controllers/subtitle_controller.dart';
import '../controllers/ui_visibility_controller.dart';
import '../controllers/video_controller.dart';
import '../../domain/models/danmaku_panel_state.dart';
import '../../domain/models/gesture_state.dart';
import '../../domain/models/media_state.dart';
import '../../domain/models/panel_state.dart';
import '../../domain/models/playback_state.dart';
import '../../domain/models/ui_visibility_state.dart';

// ---------------- 状态选择器（让 Widget 只订阅自己关心的那一片）----------------

/// 播放状态。
final playbackStateProvider =
    NotifierProvider<PlaybackController, PlaybackState>(
        PlaybackController.new);

/// 仅订阅 `isPlaying` —— 播放/暂停按钮用它，避免位置每 250ms 更新时重建。
final isPlayingProvider = Provider<bool>(
    (ref) => ref.watch(playbackStateProvider.select((s) => s.isPlaying)));

/// 倍速按钮的文案 —— **永远显示用户选择的倍速**（`userSpeed`）。
///
/// ## ⚠️ 这里必须是 `userSpeed`，不是 `effectiveSpeed`（用户规格，2026-10-09）
///
/// 用户明确的 5 条规格：
/// ```
/// ① 长按只影响"实际播放倍速"，不修改"用户选择的倍速"
/// ② 长按结束后，倍速按钮回到用户之前选择的值
/// ③ 倍速按钮点击循环永远只操作 userSpeed，与长按无关
/// ④ 长按期间，倍速按钮显示不变（仍显示用户选择的值）
/// ⑤ 长按期间，只有长按反馈浮层显示 longPressSpeed
/// ```
///
/// `effectiveSpeed` 是"**内核实际在跑的**倍速"（长按期间 = 3.0），
/// 它的用途是**下发给引擎**（见 `player_ui_page` 的 `onSpeedChanged` 监听）
/// 与**长按浮层**。把它用在按钮文案上会违反第 ④ 条：
/// 长按期间按钮会跳到 3.0x，用户会以为"我的倍速被改了"。
///
/// **一句话**：`effectiveSpeed` → 给引擎；`userSpeed` → 给用户看。
///
/// （本 provider 此前用的是 `effectiveSpeed`，且**生产代码零消费者** ——
///   只有测试引用。属"写好却没用，还用错"的死代码，
///   与 AGENTS §7 里 `FileDoubanCache` 那类问题同源。）
final speedLabelProvider = Provider<String>((ref) => ref.watch(
    playbackStateProvider.select((s) => _speedLabelOf(s.userSpeed))));

String _speedLabelOf(double v) => '${v.toStringAsFixed(1)}x';

/// 仅订阅进度（0.0–1.0）—— **进度条专用**。
///
/// ⚠️ 进度条**不能** watch 整个 `PlaybackState`：位置每 250ms 更新一次，
///    整个状态对象变化会让进度条、时间文本、播放按钮一起重建。
///    用 select 收敛到"只有数值变了才重建"。
final progressProvider = Provider<double>(
    (ref) => ref.watch(playbackStateProvider.select((s) => s.progress)));

/// 手势状态。
final gestureStateProvider =
    NotifierProvider<GestureController, GestureState>(GestureController.new);

/// UI 显隐与锁定。
final uiVisibilityProvider =
    NotifierProvider<UiVisibilityController, UiVisibilityState>(
        UiVisibilityController.new);

/// 仅订阅"控制层是否可见"（含锁定判定）。
final controlsVisibleProvider = Provider<bool>((ref) =>
    ref.watch(uiVisibilityProvider.select((s) => s.controlsVisible)));

/// 是否锁定。
final isLockedProvider = Provider<bool>((ref) =>
    ref.watch(uiVisibilityProvider.select((s) => s.isLocked)));

/// 面板状态。
final panelStateProvider =
    NotifierProvider<PanelController, PanelState>(PanelController.new);

/// 播放列表。
final playlistStateProvider =
    NotifierProvider<PlaylistController, PlaylistState>(
        PlaylistController.new);

/// 视频参数。
final videoStateProvider =
    NotifierProvider<VideoController, VideoState>(VideoController.new);

/// 音频参数。
final audioStateProvider =
    NotifierProvider<AudioController, AudioState>(AudioController.new);

/// 字幕参数。
final subtitleStateProvider =
    NotifierProvider<SubtitleController, SubtitleState>(
        SubtitleController.new);

/// 弹幕面板。
final danmakuPanelProvider =
    NotifierProvider<DanmakuPanelController, DanmakuPanelState>(
        DanmakuPanelController.new);

/// 媒体信息（信息 Tab）—— 由内核推来，UI 只读。
///
/// ⚠️ 不用 `StateProvider`：**Riverpod 3.x 已移除它**（2.x 的 API）。
///    本仓库是 3.4.3，故用 `Notifier` 表达同样的"可写单值"语义。
class MediaInfoNotifier extends Notifier<MediaInfo> {
  @override
  MediaInfo build() => const MediaInfo();

  void set(MediaInfo info) => state = info;

  void clear() => state = const MediaInfo();
}

final mediaInfoProvider =
    NotifierProvider<MediaInfoNotifier, MediaInfo>(MediaInfoNotifier.new);
