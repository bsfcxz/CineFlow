/// 媒体会话桥（K3 / CF-P3-KERNEL-004，2026-10-09）。
///
/// ## 解决什么
/// 通知栏控制、蓝牙/有线耳机媒体键、后台播放、音频焦点。
///
/// ## ★ 关键设计：会话命令走**既有控制器**，不新增播放逻辑
/// ```
///   媒体键 / 通知栏
///        ↓  MediaSession（原生）
///   CineFlowSessionPlayer（原生，只读状态 + 转发命令）
///        ↓ SessionChannel
///   本类  ← 你现在看的地方
///        ↓
///   PlayerPageCallbacks（**与 UI 点击完全同一套回调**）
/// ```
/// 这是刻意的：如果会话命令直接调内核，就会出现"两个主" ——
/// 通知栏显示播放中而实际已暂停、自动连播被绕开、长按倍速状态错乱。
/// 走同一套回调 ⇒ 行为与用户点击**逐字节一致**，不会出现两套逻辑。
///
/// ## 与 `PlayerSessionBridge.kt` 的分工
/// · 原生 `bridge`：持有状态快照（供通知栏读），不解析业务
/// · 本类：**唯一**解析状态并推给原生的地方（标题/时长/播放中）
///
/// 反过来的话（原生解析），内核加字段时只改一处，通知栏会显示错信息。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../kernel.dart';

/// 会话服务的通道入口（单例，App 生命周期内复用）。
class SessionBridge {
  SessionBridge._();

  /// **测试用构造器**：不注册 MethodChannel。
  ///
  /// `flutter test` 跑在桌面 VM，碰不到原生实现 —— 真实通道会抛
  /// `MissingPluginException`。子类覆写 `updateState` / `clearState`
  /// 即可断言"推了什么、推了几次"（见 `test/player_session_sync_test.dart`）。
  @visibleForTesting
  SessionBridge.forTest();

  static final SessionBridge instance = SessionBridge._();

  static const MethodChannel _channel = MethodChannel('cineflow/session');

  /// 会话命令回调（由播放页注册，映射到既有的 [PlayerPageCallbacks]）。
  void Function(String action, Duration? seekTo, double? speed)? onCommand;

  bool _registered = false;

  /// 注册命令接收（幂等 —— 多次进入播放页只注册一次）。
  void ensureRegistered() {
    if (_registered) return;
    _registered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onSessionCommand') return null;
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
      final action = args['action'] as String? ?? '';
      final posMs = (args['positionMs'] as num?)?.toInt() ?? -1;
      final speed = (args['speed'] as num?)?.toDouble();
      // ignore: avoid_print
      onCommand?.call(
        action,
        posMs >= 0 ? Duration(milliseconds: posMs) : null,
        speed,
      );
      return null;
    });
  }

  /// 启动会话服务（**起播时调**）。
  ///
  /// 不调 ⇒ 原生 `MediaSessionService.onCreate` 不执行 ⇒ 没有 MediaSession
  /// ⇒ **通知栏与媒体键静默失效**（不报错）。
  ///
  /// ⚠️ **会先申请通知权限** —— API 33+ 起 `POST_NOTIFICATIONS` 是
  /// **运行时权限**，只在 manifest 声明**不够**：用户不授权时
  /// 通知栏完全不显示媒体控制，而且不报错（真机实测 `granted=false`）。
  Future<void> start() async {
    await ensureNotificationPermission();
    try {
      await _channel.invokeMethod<bool>('start');
    } catch (e) {
      // 会话不可用不该影响播放 —— 只是没有通知栏控制而已。
      // 但要留下痕迹（本项目禁止"静默失败"）。
      debugPrint('[Session] 启动失败（不影响播放）：$e');
    }
  }

  /// 申请通知权限（API 33+ 必需）。
  ///
  /// ## 为什么由这里发起
  /// 权限请求**必须由 Activity 发起**，故走 `SystemChannel`
  /// （它持有 Activity）。时机必须在**App 前台**时 ——
  /// 后台请求会被系统直接拒绝且不弹窗。
  /// "进播放页"正是前台 + 用户刚表达播放意图的时刻，最合理。
  ///
  /// ## 用户拒绝会怎样
  /// 不重试、不打扰（拒绝就是不想给）。只是通知栏没有媒体控制，
  /// **播放本身完全不受影响**。
  Future<void> ensureNotificationPermission() async {
    try {
      const ch = MethodChannel('com.cineflow.app/notification');
      final has = await ch.invokeMethod<bool>('has') ?? false;
      if (has) return;
      await ch.invokeMethod<bool>('request');
      debugPrint('[Session] 已申请通知权限（用户可能拒绝，不影响播放）');
    } catch (e) {
      debugPrint('[Session] 通知权限申请失败：$e');
    }
  }

  /// 停止会话服务（退出播放页）。
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {
      // 停止失败无需打扰用户
    }
  }

  /// 推送状态给通知栏。
  ///
  /// 只传**变化了的字段**（其余传 null，原生侧保持原值）——
  /// 进度是秒级推送的，每次传全量会让原生侧反复重建通知。
  Future<void> updateState({
    String? title,
    String? subtitle,
    String? artworkUrl,
    Duration? duration,
    Duration? position,
    bool? isPlaying,
    bool? isBuffering,
    bool? hasMedia,
    double? speed,
  }) async {
    try {
      // `?x` 是 Dart 3 的 null-aware 元素：**值为 null 时整条省略**
      //（与 `if (x != null) 'k': x` 等价，是项目既有风格，见 AGENTS §11）。
      // 语义上很重要：原生侧把"没传"当作"本次无变化"。
      await _channel.invokeMethod<bool>('updateState', {
        'title': ?title,
        'subtitle': ?subtitle,
        'artworkUrl': ?artworkUrl,
        'durationMs': ?duration?.inMilliseconds,
        'positionMs': ?position?.inMilliseconds,
        'isPlaying': ?isPlaying,
        'isBuffering': ?isBuffering,
        'hasMedia': ?hasMedia,
        'speed': ?speed,
      });
    } catch (e) {
      // ⚠️ **不要改回 `catch (_) {}`**（静默吞异常）。
      //
      // 真机排查教训：状态推送失败时现象是"通知栏什么都没有"，
      // 而静默 catch 让**没有任何线索** —— 只能逐段加日志去猜，
      // 多花了好几轮才定位到真正原因（会话没 `addSession`）。
      //
      // 打日志不影响播放（推送失败只影响通知栏显示）。
      debugPrint('[Session] updateState 失败（通知栏可能不更新）: $e');
    }
  }

  /// 清空会话状态（退出播放页）。
  Future<void> clearState() async {
    try {
      await _channel.invokeMethod<bool>('clearState');
    } catch (e) {
      // 同 `updateState`：失败要有痕迹，不静默吞 ——
      // 残留的会话状态会让通知栏一直挂着"正在播放"。
      debugPrint('[Session] clearState 失败: $e');
    }
  }
}

/// 把 [PlaybackState] 同步到通知栏的最小适配器。
///
/// ## 为什么要单独一个类而不是在页面里调
/// 页面里"什么时候推状态"容易漏（改一处忘一处）——
/// 本项目已多次踩"配了没接线"的坑（`default_rate` 有读无写、
/// HDR 信息数据有接线断）。
/// 抽成类后：**一个地方**决定推什么，且能被单测覆盖。
class SessionStateSync {
  SessionStateSync({SessionBridge? bridge})
      : _bridge = bridge ?? SessionBridge.instance;

  final SessionBridge _bridge;

  /// 上次推送的值（**去重**：相同就不推，避免刷通知栏）。
  KernelState? _last;

  /// 媒体信息（标题等）—— 由页面在起播/换集时设置。
  String _title = '';
  String _subtitle = '';
  String? _artworkUrl;

  /// 换片时更新媒体信息（起播/切集调用）。
  void setMediaInfo({
    required String title,
    String subtitle = '',
    String? artworkUrl,
  }) {
    _title = title;
    _subtitle = subtitle;
    _artworkUrl = artworkUrl;
  }

  /// 同步一次状态（页面在状态变化时调用）。
  ///
  /// ## 为什么参数是 [KernelState] 而不是 UI 的 `PlaybackState`
  /// `kernel.stateStream` 是**最全**的状态源（所有变化都过它，包括
  /// 手势 seek、自动连播、内核内部的状态跃迁）。若改读 provider，
  /// 就得**再挂一层监听**，等于多一条链路、多一处会漏接的地方
  /// —— 本项目反复踩"配了没接线"的坑，故直接吃内核状态。
  ///
  /// ## 去重规则（两个都要，缺一会刷爆通知栏）
  /// · **播放中/暂停/缓冲/时长**变化 → 必须推（通知栏按钮与进度条要变）
  /// · **进度**变化 → 只在**秒级**才推
  ///   （进度是 250ms 推一次的，不去重会让原生侧每秒重建 4 次通知）
  void sync(KernelState s) {
    final prev = _last;
    final isPlayingChanged = prev?.playing != s.playing;
    final isBufferingChanged = prev?.buffering != s.buffering;
    final durationChanged = prev?.duration != s.duration;
    // 秒级去重：同一秒内不重复推进度
    final positionChanged = prev == null ||
        prev.position.inSeconds != s.position.inSeconds;

    if (!isPlayingChanged &&
        !isBufferingChanged &&
        !durationChanged &&
        !positionChanged) {
      return;
    }

    _last = s;
    unawaited(_bridge.updateState(
      title: _title,
      subtitle: _subtitle,
      artworkUrl: _artworkUrl,
      duration: s.duration,
      position: s.position,
      isPlaying: s.playing,
      isBuffering: s.buffering,
      hasMedia: true,
      // ⚠️ 这里**不传** `s.rate`：那是"实际播放倍速"（长按时会变），
      //    而用户选择的倍速才有意义（长按的 5 条禁令之一）。
      //    需要时由页面调 `setUserSpeed` 显式覆盖。
    ));
  }

  /// 清空（退出播放页）。
  void clear() {
    _last = null;
    _title = '';
    _subtitle = '';
    _artworkUrl = null;
    unawaited(_bridge.clearState());
  }
}
