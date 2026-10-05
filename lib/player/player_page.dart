/// 播放器页 —— media_kit（libmpv）内核 + Emby 直连流 + 进度上报
/// 控制层对齐《CineFlow UI 完整原型》播放器设计：
///   顶栏：返回 + 标题/状态行 + 画幅胶囊 + 设置；底部：时间(点击切剩余) +
///   章节刻度进度条 + 控制行（倍速/字幕/音轨/选集/跳片头开关/设置）；中央三键
///   手势：单击显隐；双击左/中/右 = -10s / 播放暂停 / +10s；长按 = 2.5x；
///        竖滑 = 左亮度 / 右音量（带竖排提示）
///   浮钮：跳过片头（按章节名识别）；自动连播倒计时卡；右侧设置抽屉（原型 .psettings）
library;

import 'dart:async';

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../core/theme.dart';
import '../danmaku/danmaku_models.dart';
import '../danmaku/danmaku_overlay.dart';
import '../danmaku/danmaku_providers.dart';
import '../danmaku/danmaku_settings_page.dart';
import '../data/emby_provider.dart';
import '../data/media_provider.dart';
import '../data/models.dart';
import '../state/providers.dart';

/// 打开播放器
///
/// 已迁到 `pages/player/player_routes.dart`（go_router）。
/// 那里保留了同名函数 `openPlayer(context, item, ...)`，
/// 调用方只需改 import —— 这样"路由迁移"不会波及调用点签名。
/// 迁移原因与回退策略见 `docs/decisions/0005-go-router-migration.md`。

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({
    super.key,
    required this.item,
    this.episodes,
    this.index = 0,
    this.mediaSourceId,
  });
  final MediaItem item;
  final List<MediaItem>? episodes;
  final int index;

  /// 多版本条目：本页首次起播使用的媒体源 id（换集时不沿用，各集版本不同）
  final String? mediaSourceId;

  /// 解析已保存的默认倍速偏好。空/非法一律回退 1.0x。
  /// public static 供单元测试断言（缺陷 7.5 是"有读无写"，静态分析发现不了）。
  static double parseDefaultRate(String? raw) =>
      double.tryParse(raw ?? '') ?? 1.0;

  /// 写回偏好：1.0x 视为默认值，存空串以清除该偏好。
  static String encodeDefaultRate(double rate) => rate == 1.0 ? '' : '$rate';

  /// 可选的默认倍速档位（与播放速度组区分：这只影响"下次起播"）
  static const defaultRateChoices = <double>[1.0, 1.25, 1.5, 2.0];

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  final _player = Player();
  late final VideoController _controller;

  // 播放状态
  late MediaItem _current;
  int _index = 0;
  bool _resolving = true;
  bool _switching = false;
  String? _error;
  PlaybackLaunch? _launch;
  bool _started = false;
  bool _finalized = false;
  double _resumeSeconds = 0; // 换集时带上已看进度

  // 播放器流状态（订阅驱动 rebuild）
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration _buf = Duration.zero;
  bool _playing = false;

  /// 是否已进入过播放态。用于区分"起播"（已由 reportPlaybackStart 上报）
  /// 与"用户暂停后恢复"（需发 Unpause）——否则起播会多发一次 Unpause。
  bool _hasPlayedOnce = false;
  bool _buffering = false;
  double _rate = 1.0;
  double _rateBeforeHold = 1.0;

  // 播放方式：直连优先，转码是最后手段
  String _playMethod = 'direct'; // direct / transcode
  bool _autoFallbackTried = false; // 直连失败自动切转码只试一次
  Timer? _speedTimer;
  int _bufStalls = 0;
  bool _netSlowHint = false; // 速度不足提示卡

  // 章节 / 跳过片头
  List<MediaChapter> _chapters = const [];
  (double, double)? _intro; // 片头章节 (开始秒, 结束秒)
  bool _introSkipped = false; // 每次起播只自动跳一次

  // 偏好（持久化）
  bool _autoIntroSkip = true;
  bool _autoNextEnabled = true;
  double _defaultRate = 1.0; // 下次起播使用的倍速（cf_pref_default_rate）

  // 弹幕
  //
  // 加载结果与开关都在这里：弹幕**不是**播放的必要条件，
  // 所以它的状态与播放状态完全解耦——加载失败只影响弹幕层，
  // 视频照常播（见 danmaku_providers 的"绝不抛异常"约定）。
  List<Danmaku> _danmaku = const [];
  bool _danmakuEnabled = true; // 本次播放的用户开关（配置里的 enabled 是全局）
  bool _danmakuLoading = false;
  String? _danmakuError;
  String? _danmakuMatched; // 服务端匹配到的番剧名（让用户确认对不对）

  // 控制层
  bool _showControls = true;
  bool _locked = false;
  bool _showSettings = false;
  bool _showRemaining = false;
  BoxFit _fit = BoxFit.contain;
  Timer? _hideTimer;
  Timer? _reportTimer;
  Timer? _flashTimer;
  Timer? _autoNextTimer;
  int? _autoNextSeconds;
  IconData? _flashIcon; // 双击/长按/竖滑的瞬时反馈
  String? _flashText;

  // 竖滑（左亮度 / 右音量）
  double? _dragValue; // 0~1，拖动中的即时值
  bool _dragBrightness = false;
  bool _showGestureHints = false;

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _current = widget.item;
    _index = widget.index;
    // 换集续播：入口条目自带进度（Resume 数据），推进到 >2% 且未播完处
    final pct = widget.item.progress;
    final totalSec = widget.item.runtimeTicks == null
        ? 0.0
        : widget.item.runtimeTicks! / 10000000;
    if (pct > 0.02 && pct < 0.95 && totalSec > 0) {
      _resumeSeconds = totalSec * pct;
    }
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controller = VideoController(_player);
    _subs.addAll([
      _player.stream.position.listen((d) {
        setState(() => _pos = d);
        _checkIntroSkip();
      }),
      _player.stream.duration.listen((d) => setState(() => _dur = d)),
      _player.stream.buffer.listen((d) => setState(() => _buf = d)),
      _player.stream.playing.listen((b) {
        // 播放/暂停切换后立即上报（官方要求"任何用户交互后立即上报"）。
        // 挂在 stream 而不是某个按钮回调上：暂停的来源有多种
        // （中央按钮、手势双击、耳机线控、系统媒体控件），
        // 只挂按钮会漏掉后几种，而服务端正在按旧状态递增进度。
        //
        // 用 _hasPlayedOnce 排除"起播"这次转变：起播已由
        // reportPlaybackStart 报过，再发一次 Unpause 是重复上报。
        final wasPlaying = _playing;
        setState(() => _playing = b);
        if (!_started || wasPlaying == b) return;
        if (!_hasPlayedOnce) {
          if (b) _hasPlayedOnce = true; // 起播，不发
          return;
        }
        _reportEvent(b ? ProgressEvent.unpause : ProgressEvent.pause);
      }),
      _player.stream.buffering.listen((b) => setState(() => _buffering = b)),
      _player.stream.rate.listen((r) => setState(() => _rate = r)),
      _player.stream.error.listen((e) {
        if (!mounted || e.isEmpty) return;
        // 直连出错且未试过转码 → 自动降级一次
        if (!_autoFallbackTried &&
            _playMethod == 'direct' &&
            (_launch?.transcodingUrl ?? '').isNotEmpty) {
          _autoFallbackTried = true;
          unawaited(_reopenAs('transcode', reason: '直连失败，已切换转码'));
          return;
        }
        setState(() => _error = '播放出错：$e');
      }),
      _player.stream.completed.listen((done) {
        if (done) _onCompleted();
      }),
    ]);
    _loadPrefs();
    // 弹幕与播放并行加载：不 await，避免拖慢起播。
    // 用户先看到画面，弹幕稍后出现（这与官方客户端行为一致）。
    unawaited(_loadDanmaku());
    _armHide(seconds: 6);
    // 手机端手势提示（竖排，几秒后淡出）
    setState(() => _showGestureHints = true);
    Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showGestureHints = false);
    });
    _start();
  }

  Future<void> _loadPrefs() async {
    final store = ref.read(sessionStoreProvider);
    final autoIntro = await store.getPref('skip_intro_auto');
    final autoNext = await store.getPref('auto_next');
    final defaultRate = await store.getPref('default_rate');
    if (mounted) {
      setState(() {
        _autoIntroSkip = autoIntro != '0'; // 默认开
        _autoNextEnabled = autoNext != '0'; // 默认开
        _defaultRate = PlayerPage.parseDefaultRate(defaultRate);
      });
    }
  }

  Future<void> _start() async {
    final api = ref.read(embyApiProvider);
    if (api == null) {
      setState(() => _error = '未登录');
      return;
    }
    try {
      final launch = await api.resolvePlayback(_current.id,
          mediaSourceId: widget.mediaSourceId);
      if (!mounted) return;
      setState(() {
        _launch = launch;
        _resolving = false;
      });
      await _player.open(Media(launch.url), play: true);
      if (_resumeSeconds > 3) {
        await _player.seek(Duration(seconds: _resumeSeconds.toInt()));
      }
      // 默认倍速偏好
      final savedRate = double.tryParse(
          await ref.read(sessionStoreProvider).getPref('default_rate') ?? '');
      if (savedRate != null && savedRate != 1) {
        await _player.setRate(savedRate);
      }
      _reportStart(launch);
      // 章节与片头区间（异步加载，不阻塞起播）
      api.getChapters(_current.id).then((ch) {
        if (!mounted || ch.isEmpty) return;
        setState(() => _chapters = ch);
        _intro = _detectIntro(ch);
      }).catchError((_) {});
    } on MediaException catch (e) {
      setState(() {
        _error = e.message;
        _resolving = false;
      });
    } catch (_) {
      setState(() {
        _error = '起播失败，请稍后重试';
        _resolving = false;
      });
    }
  }

  /// 按章节名识别片头区间（Emby 无原生片头检测，用名称匹配）
  (double, double)? _detectIntro(List<MediaChapter> ch) {
    for (var i = 0; i < ch.length; i++) {
      final n = ch[i].name.toLowerCase();
      if (n.contains('片头') || n.contains('intro') || n.contains('opening')) {
        final start = ch[i].seconds;
        final end = i + 1 < ch.length ? ch[i + 1].seconds : 120.0;
        if (end > start) return (start, end);
      }
    }
    return null;
  }

  void _checkIntroSkip() {
    final intro = _intro;
    if (intro == null || _introSkipped || !_autoIntroSkip) return;
    if (_pos.inSeconds >= intro.$1 && _pos.inSeconds < intro.$2 - 1) {
      _introSkipped = true;
      _player.seek(Duration(seconds: intro.$2.toInt()));
      _flash(Icons.fast_forward_rounded, '已跳过片头');
    }
  }

  // ---------- 弹幕 ----------

  /// 加载当前条目的弹幕。
  ///
  /// ## 为什么是"尽力而为"
  ///
  /// 弹幕依赖外部服务（官方或自建），可能因为：没配、网络不通、
  /// 该片没有弹幕库、服务端生成超时而失败。**这些都不该让播放变差**，
  /// 所以：
  ///   - 全程 try/catch，失败只记 `_danmakuError`
  ///   - 不阻塞起播（`_start` 不等它）
  ///   - 检查 `mounted`：用户可能在加载完成前就退出播放器了
  ///
  /// 注意 `_danmakuError` 与"没有弹幕"是两回事：前者要提示，
  /// 后者（`items` 为空但无 error）静默即可——大多数冷门片确实没弹幕。
  Future<void> _loadDanmaku() async {
    final cfg = ref.read(danmakuConfigProvider).value;
    if (cfg == null || !cfg.isUsable) {
      // 没配置源：不是错误，静默（设置页会引导用户去配）
      if (mounted) setState(() => _danmakuLoading = false);
      return;
    }
    if (mounted) setState(() => _danmakuLoading = true);

    try {
      final result = await ref.read(danmakuForItemProvider(widget.item).future);
      if (!mounted) return;
      setState(() {
        _danmaku = result.items;
        _danmakuError = result.error;
        _danmakuMatched = result.matchedTitle;
        _danmakuLoading = false;
      });
    } catch (e) {
      // 兜底：provider 内部已捕获常见异常，这里防的是意外情况
      if (!mounted) return;
      setState(() {
        _danmakuError = '弹幕加载失败：$e';
        _danmakuLoading = false;
      });
    }
  }

  /// 切换弹幕显示（本次播放内有效，不改全局配置）
  void _toggleDanmaku() {
    setState(() => _danmakuEnabled = !_danmakuEnabled);
    _flash(
      _danmakuEnabled
          ? Icons.subtitles_rounded
          : Icons.subtitles_off_rounded,
      _danmakuEnabled ? '弹幕已开' : '弹幕已关',
    );
  }

  /// 起播上报：先 Sessions/Playing 声明开始，再每 10s Progress（Emby 的
  /// 「正在播放」面板依赖 Start 才会立即出现本条会话，缺了它要等第一个 Progress）
  void _reportStart(PlaybackLaunch launch) {
    final api = ref.read(embyApiProvider);
    if (api == null || _started) return;
    _started = true;
    api.reportPlaybackStart(
      itemId: launch.itemId,
      playSessionId: launch.playSessionId,
      mediaSourceId: launch.mediaSourceId,
      positionTicks: _pos.inMilliseconds * 10000,
    );
    _reportTimer?.cancel();
    _reportTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final a = ref.read(embyApiProvider);
      final l = _launch;
      if (a == null || l == null) return;
      a.reportPlaybackProgress(
        itemId: l.itemId,
        playSessionId: l.playSessionId,
        mediaSourceId: l.mediaSourceId,
        positionTicks: _pos.inMilliseconds * 10000,
        paused: !_playing,
        rate: _rate,
        // 定时上报的原因恒为 TimeUpdate；用户交互另有即时上报
        eventName: ProgressEvent.timeUpdate,
      );
    });
  }

  /// 用户交互后**立即**上报一次进度。
  ///
  /// 官方文档（Playback Check-ins）要求进度在两种时机上报：
  ///   1. 每 10 秒自动一次（`TimeUpdate`）
  ///   2. **任何用户交互之后立即一次**，并带上对应的事件名
  ///
  /// 为什么第 2 条不能省：服务端会自行按秒递增进度，只在定时上报时校准。
  /// 于是用户拖动进度条后，服务端仍按旧位置继续递增，
  /// 若此后 10 秒内退出（或 App 被杀），落库的进度就是**错的**——
  /// 表现为"下次继续观看从错误的位置开始"。
  /// 带事件名上报能让服务端立刻纠正。
  void _reportEvent(String eventName) {
    final a = ref.read(embyApiProvider);
    final l = _launch;
    if (a == null || l == null || !_started) return;
    a.reportPlaybackProgress(
      itemId: l.itemId,
      playSessionId: l.playSessionId,
      mediaSourceId: l.mediaSourceId,
      positionTicks: _pos.inMilliseconds * 10000,
      paused: !_playing,
      rate: _rate,
      eventName: eventName,
    );
  }

  /// 换集 / 自动连播
  Future<void> _playEpisode(int index) async {
    final eps = widget.episodes;
    if (_switching || eps == null || index < 0 || index >= eps.length) return;
    final api = ref.read(embyApiProvider);
    final old = _launch;
    if (api != null && old != null && _started) {
      api.reportPlaybackStop(
        itemId: old.itemId,
        playSessionId: old.playSessionId,
        mediaSourceId: old.mediaSourceId,
        positionTicks: _pos.inMilliseconds * 10000,
      );
      // 换集同样要落库上一集的条目进度，否则「继续观看」读不到它
      api.reportItemProgress(
        itemId: old.itemId,
        positionTicks: _pos.inMilliseconds * 10000,
      );
    }
    _started = false;
    _introSkipped = false;
    _intro = null;
    _reportTimer?.cancel();
    setState(() {
      _switching = true;
      _current = eps[index];
      _index = index;
      _resolving = true;
      _error = null;
      _pos = Duration.zero;
      _buf = Duration.zero;
      _resumeSeconds = 0;
    });
    try {
      // 换集不沿用上一集的版本选择：各集的媒体源 id 不同，交由服务端给默认路
      final launch = await api!.resolvePlayback(_current.id);
      if (!mounted) return;
      setState(() => _launch = launch);
      await _player.open(Media(launch.url), play: true);
      _reportStart(launch);
      api.getChapters(_current.id).then((ch) {
        if (!mounted || ch.isEmpty) return;
        setState(() => _chapters = ch);
        _intro = _detectIntro(ch);
      }).catchError((_) {});
      // 换集必须重载弹幕（否则沿用上一集的弹幕时间轴，完全对不上）
      unawaited(_loadDanmaku());
      _startSpeedWatch();
    } catch (e) {
      setState(() => _error = e is MediaException ? e.message : '切换失败');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 起播速度监测（码率跟不上就建议降档）。
  /// media_kit 不暴露下载速度，用「播放中但缓冲持续不足」近似：
  /// 前 30 秒内每 2 秒采样一次，缓冲 <4s 累计 3 次即提示切转码。
  void _startSpeedWatch() {
    _speedTimer?.cancel();
    _bufStalls = 0;
    var samples = 0;
    _speedTimer = Timer.periodic(const Duration(seconds: 2), (t) {
      if (!mounted) return t.cancel();
      samples++;
      if (samples > 15 || !_playing) return;
      if (_buffering) return; // 正在缓冲不计
      if (_dur.inSeconds > 0 && _buf.inSeconds < 4) {
        _bufStalls++;
      } else {
        _bufStalls = 0;
      }
      if (_bufStalls >= 3 && !_netSlowHint) {
        t.cancel();
        if (mounted) setState(() => _netSlowHint = true);
      }
    });
  }

  /// 切换播放方式（直连 / 转码），保持当前进度
  Future<void> _reopenAs(String method, {String? reason}) async {
    final launch = _launch;
    if (launch == null || _switching) return;
    if (method == 'transcode' && (launch.transcodingUrl ?? '').isEmpty) {
      _flash(Icons.info_rounded, '该媒体源没有可用的转码流');
      return;
    }
    if (method == _playMethod) return;
    final keepPos = _pos;
    setState(() {
      _playMethod = method;
      _switching = true;
    });
    try {
      await _player.open(
          Media(method == 'transcode' ? launch.transcodingUrl! : launch.url),
          play: true);
      if (keepPos.inSeconds > 3) {
        await _player.seek(keepPos);
      }
      if (reason != null) _flash(Icons.sync_rounded, reason);
      _armHide();
    } catch (_) {
      _flash(Icons.error_rounded, '切换失败');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _onCompleted() {
    // 播完 → 自动连播倒计时卡（可取消；偏好可关闭）
    final eps = widget.episodes;
    if (!_autoNextEnabled || eps == null || _index >= eps.length - 1) return;
    _autoNextSeconds = 5;
    _autoNextTimer?.cancel();
    _autoNextTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final v = _autoNextSeconds;
      if (v == null) return;
      if (v <= 1) {
        _autoNextTimer?.cancel();
        _autoNextSeconds = null;
        _playEpisode(_index + 1);
      } else {
        setState(() => _autoNextSeconds = v - 1);
      }
    });
    setState(() => _autoNextSeconds = 5);
  }

  void _cancelAutoNext() {
    _autoNextTimer?.cancel();
    setState(() => _autoNextSeconds = null);
  }

  // ---------- 手势 ----------

  Offset? _doubleTapPos;

  void _onTap() {
    if (_showSettings) {
      setState(() => _showSettings = false);
      return;
    }
    setState(() => _showControls = !_showControls);
    if (_showControls) _armHide();
  }

  void _onDoubleTap() {
    if (_locked) return;
    final w = MediaQuery.sizeOf(context).width;
    final dx = _doubleTapPos?.dx ?? w / 2;
    if (dx < w / 3) {
      _seekBy(-10);
    } else if (dx > w * 2 / 3) {
      _seekBy(10);
    } else {
      _togglePlay();
    }
  }

  Future<void> _seekBy(int seconds) async {
    final target = _pos + Duration(seconds: seconds);
    await _player.seek(target);
    // 跳转后立即上报新的位置：服务端在按旧位置递增进度，
    // 若不纠正，此后 10 秒内退出就会把错误位置存成"继续观看"点。
    _reportEvent(ProgressEvent.timeUpdate);
    _flash(seconds < 0 ? Icons.replay_10_rounded : Icons.forward_10_rounded,
        seconds < 0 ? '-10 秒' : '+10 秒');
  }

  Future<void> _togglePlay() async {
    _playing ? await _player.pause() : await _player.play();
    _flash(_playing ? Icons.play_arrow_rounded : Icons.pause_rounded, null);
    _armHide();
  }

  void _onLongPressStart() {
    if (_locked) return;
    _rateBeforeHold = _rate == 2.5 ? 1.0 : _rate;
    _player.setRate(2.5);
    _flash(Icons.fast_forward_rounded, '2.5x 倍速中');
  }

  void _onLongPressEnd() {
    _player.setRate(_rateBeforeHold);
    setState(() => _flashIcon = null);
    _armHide();
  }

  /// 竖滑：左半屏亮度 / 右半屏音量（对齐原型 gesture-hints）
  void _onVerticalDragStart(DragStartDetails d) {
    if (_locked) return;
    _dragBrightness =
        d.globalPosition.dx < MediaQuery.sizeOf(context).width / 2;
    _dragValue = _dragBrightness ? 1.0 : _player.state.volume / 100;
    _hideTimer?.cancel();
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (_locked || _dragValue == null) return;
    final delta = -d.delta.dy / 300;
    final v = (_dragValue! + delta).clamp(0.0, 1.0);
    setState(() => _dragValue = v);
    if (_dragBrightness) {
      ScreenBrightness().setApplicationScreenBrightness(v.clamp(0.05, 1.0));
    } else {
      _player.setVolume(v * 100);
    }
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_dragValue == null) return;
    final v = _dragValue!;
    final isBrightness = _dragBrightness;
    final label = isBrightness
        ? '亮度 ${(v * 100).round()}%'
        : '音量 ${(v * 100).round()}%';
    _dragValue = null;
    _flash(
        isBrightness ? Icons.brightness_6_rounded : Icons.volume_up_rounded,
        label);
    _armHide();
  }

  void _flash(IconData icon, String? text) {
    setState(() {
      _flashIcon = icon;
      _flashText = text;
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _flashIcon = null);
    });
  }

  void _armHide({int seconds = 4}) {
    _hideTimer?.cancel();
    _hideTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && _playing && !_locked && !_showSettings) {
        setState(() => _showControls = false);
      }
    });
  }

  // ---------- 退出 ----------

  void _finalizeAndExit() {
    if (_finalized) return;
    _finalized = true;
    final api = ref.read(embyApiProvider);
    final launch = _launch;
    if (api != null && launch != null && _started) {
      api.reportPlaybackStop(
        itemId: launch.itemId,
        playSessionId: launch.playSessionId,
        mediaSourceId: launch.mediaSourceId,
        positionTicks: _pos.inMilliseconds * 10000,
      );
      // 会话上报之外，再持久化条目级进度：Sessions/Playing 是会话状态，
      // 服务端可能随会话结束丢弃；决定「继续观看」的是条目自身的 UserData。
      // 播到 ≥95% 视为看完（与详情页「已看」判定一致）。
      final done = _dur > Duration.zero && _pos >= _dur * 0.95;
      api.reportItemProgress(
        itemId: launch.itemId,
        positionTicks: done ? 0 : _pos.inMilliseconds * 10000,
        played: done ? true : null,
      );
    }
    _player.pause();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _reportTimer?.cancel();
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    _autoNextTimer?.cancel();
    _speedTimer?.cancel();
    // 恢复应用内亮度
    unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    // 延迟销毁：避免在路由销毁帧内同步释放解码器（media_kit 原生崩溃坑）
    unawaited(Future<void>.delayed(const Duration(milliseconds: 300))
        .then((_) => _player.dispose()));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finalizeAndExit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          // 视频层 + 手势
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onTap,
              onDoubleTapDown: (d) => _doubleTapPos = d.globalPosition,
              onDoubleTap: _onDoubleTap,
              onLongPressStart: (_) => _onLongPressStart(),
              onLongPressEnd: (_) => _onLongPressEnd(),
              onVerticalDragStart: _onVerticalDragStart,
              onVerticalDragUpdate: _onVerticalDragUpdate,
              onVerticalDragEnd: _onVerticalDragEnd,
              child: (_resolving || _error != null)
                  ? Container(color: Colors.black)
                  : Video(
                      controller: _controller,
                      controls: NoVideoControls,
                      fit: _fit,
                    ),
            ),
          ),

          // 弹幕层：盖在视频之上、控制层之下。
          //
          // 位置很关键（三个约束）：
          //  1. **必须在视频之后**：否则被视频盖住看不见
          //  2. **必须在控制层之前**：否则弹幕飘在按钮/进度条上，很难看
          //  3. **内部用 IgnorePointer**：不能吃掉手势，
          //     否则播放器的单击显隐/双击快进全部失效
          if (_danmakuEnabled && _danmaku.isNotEmpty && _error == null)
            Positioned.fill(
              child: DanmakuOverlay(
                items: _danmaku,
                position: _pos,
                enabled: _danmakuEnabled,
                opacity: ref.watch(danmakuConfigProvider).value?.opacity ?? 1.0,
                fontScale:
                    ref.watch(danmakuConfigProvider).value?.fontScale ?? 1.0,
                blockedWords:
                    ref.watch(danmakuConfigProvider).value?.blockedWords ??
                        const [],
                showArea:
                    ref.watch(danmakuConfigProvider).value?.showArea ?? 1.0,
              ),
            ),

          // 居中：加载 / 错误 / 缓冲 / 竖滑反馈 / 手势反馈
          if (_resolving || _error != null)
            Center(
              child: _error != null
                  ? GestureDetector(
                      onTap: _finalizeAndExit,
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Cf.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Cf.danger),
                        ),
                        child: Text(_error!,
                            style: TextStyle(
                                fontSize: 12.5, color: Cf.text2)),
                      ),
                    )
                  : CircularProgressIndicator(color: Cf.accent),
            )
          else if (_dragValue != null)
            Center(child: _dragIndicator())
          else if (_buffering)
            Center(
                child: SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(color: Cf.accent),
            ))
          else if (_flashIcon != null)
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Color(0x88000000),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_flashIcon, size: 30, color: Colors.white),
                ),
                if (_flashText != null) ...[
                  SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0x88000000),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(_flashText!,
                        style: TextStyle(
                            fontSize: 11, color: Cf.accent)),
                  ),
                ],
              ]),
            ),

          // 竖排手势提示（进入后几秒 / 控制层隐藏时）
          if (_showGestureHints && !_showControls) ..._gestureHints(),

          // 网络较慢提示卡（建议降档）
          if (_netSlowHint && !_locked && _showControls)
            Positioned(
              left: 16,
              right: 16,
              bottom: 110,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: const Color(0xF20D1328),
                  border: Border.all(color: Cf.warn),
                ),
                child: Row(children: [
                  Icon(Icons.network_check_rounded,
                      size: 18, color: Cf.warn),
                  SizedBox(width: 9),
                  const Expanded(
                    child: Text('网络较慢，缓冲跟不上播放',
                        style: TextStyle(fontSize: 11, color: Cf.text)),
                  ),
                  SizedBox(width: 9),
                  GestureDetector(
                    onTap: () {
                      setState(() => _netSlowHint = false);
                      unawaited(_reopenAs('transcode',
                          reason: '已切换转码 1080p'));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color: const Color(0x2100D4FF),
                        border: Border.all(color: Cf.accent),
                      ),
                      child: Text('切换转码',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: Cf.accent)),
                    ),
                  ),
                  SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => setState(() => _netSlowHint = false),
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: Text('忽略',
                          style:
                              TextStyle(fontSize: 10.5, color: Cf.text3)),
                    ),
                  ),
                ]),
              ),
            ),

          // 跳过片头浮钮（区间内显示）
          if (_intro != null &&
              !_locked &&
              _pos.inSeconds >= _intro!.$1 &&
              _pos.inSeconds < _intro!.$2 - 1 &&
              _autoNextSeconds == null)
            Positioned(
              right: 20,
              bottom: 110,
              child: GestureDetector(
                onTap: () {
                  _introSkipped = true;
                  _player.seek(Duration(seconds: _intro!.$2.toInt()));
                  _flash(Icons.fast_forward_rounded, '已跳过片头');
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: const Color(0x24FFFFFF),
                    border: Border.all(color: const Color(0x47FFFFFF)),
                  ),
                  child: Text(
                      '跳过片头 ${(_intro!.$2 - _pos.inSeconds).round()}s',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
            ),

          // 自动连播倒计时卡
          if (_autoNextSeconds != null)
            Positioned(
              right: 16,
              bottom: 96,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: const Color(0xF20D1328),
                  border: Border.all(color: Cf.accent),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('本集结束，${_autoNextSeconds}s 后自动连播',
                      style:
                          TextStyle(fontSize: 11, color: Cf.text)),
                  SizedBox(width: 10),
                  GestureDetector(
                    onTap: _cancelAutoNext,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Cf.border),
                      ),
                      child: Text('取消',
                          style:
                              TextStyle(fontSize: 10, color: Cf.text3)),
                    ),
                  ),
                ]),
              ),
            ),

          // 画幅按钮：左侧中部（控制层显示时）
          if (_showControls && !_locked)
            Positioned(
              left: 14,
              top: 0,
              bottom: 0,
              child: Center(
                child: _glassCircle(
                  size: 40,
                  iconSize: 18,
                  icon: Icons.aspect_ratio_rounded,
                  onTap: _cycleFit,
                ),
              ),
            ),

          // 锁按钮：右侧中部
          if (_locked || _showControls)
            Positioned(
              right: 14,
              top: 0,
              bottom: 0,
              child: Center(
                child: AnimatedOpacity(
                  opacity: _locked ? 1 : (_showControls ? 1 : 0),
                  duration: const Duration(milliseconds: 250),
                  child: _glassCircle(
                    size: 40,
                    iconSize: 18,
                    icon: _locked
                        ? Icons.lock_rounded
                        : Icons.lock_open_rounded,
                    onTap: () {
                      setState(() => _locked = !_locked);
                      if (!_locked) _armHide();
                    },
                  ),
                ),
              ),
            ),

          // 控制层
          AnimatedOpacity(
            opacity: (_showControls && !_locked) ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            child: IgnorePointer(
              ignoring: !_showControls || _locked,
              child: Column(children: [
                _topBar(),
                const Spacer(),
                _bottomBar(),
              ]),
            ),
          ),

          // 设置抽屉（右侧，对齐原型 .psettings）
          _settingsDrawer(),
        ]),
      ),
    );
  }

  Widget _dragIndicator() {
    final v = _dragValue ?? 0;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(
          _dragBrightness
              ? Icons.brightness_6_rounded
              : Icons.volume_up_rounded,
          size: 26,
          color: Colors.white),
      SizedBox(height: 10),
      SizedBox(
        width: 130,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: v,
            minHeight: 5,
            backgroundColor: const Color(0x4DFFFFFF),
            valueColor: AlwaysStoppedAnimation(Cf.accent),
          ),
        ),
      ),
      SizedBox(height: 6),
      Text('${(v * 100).round()}%',
          style: TextStyle(
              fontSize: 11,
              color: Cf.accent,
              fontWeight: FontWeight.w700)),
    ]);
  }

  List<Widget> _gestureHints() {
    Widget hint(String text, {required bool left}) => Positioned(
          top: 0,
          bottom: 0,
          left: left ? 8 : null,
          right: left ? null : 8,
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0x59000000),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(text,
                  style: TextStyle(
                      fontSize: 9,
                      height: 1.2,
                      color: Color(0x8CE6F4FF))),
            ),
          ),
        );
    return [
      AnimatedOpacity(
        opacity: _showControls ? 0 : 1,
        duration: const Duration(milliseconds: 300),
        child: SizedBox.expand(
            child: Stack(children: [
          hint('亮\n度\n↑\n↓', left: true),
          hint('音\n量\n↑\n↓', left: false),
        ])),
      ),
    ];
  }

  /// 玻璃圆钮（中央三键左右键 / 锁）
  Widget _glassCircle({
    required IconData icon,
    required VoidCallback? onTap,
    double size = 46,
    double iconSize = 20,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0x1FFFFFFF),
          border: Border.all(color: const Color(0x2EFFFFFF)),
        ),
        child: Icon(icon, size: iconSize,
            color: onTap == null ? const Color(0x66FFFFFF) : Colors.white),
      ),
    );
  }

  /// 「极光玻璃」面板：blur + 半透明深蓝 + 细白描边（Liquid Glass × 夜色）
  /// 只圆内侧角：顶栏圆下角、底栏圆上角（贴屏幕边不缺角）
  Widget _glassPanel({
    required Widget child,
    EdgeInsets padding = EdgeInsets.zero,
    BorderRadius borderRadius = const BorderRadius.vertical(
        bottom: Radius.circular(18)),
  }) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0x660B1020),
            border: Border(
              top: BorderSide(color: const Color(0x26FFFFFF)),
              left: BorderSide(color: const Color(0x1AFFFFFF)),
              right: BorderSide(color: const Color(0x1AFFFFFF)),
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  void _cycleFit() {
    setState(() {
      _fit = switch (_fit) {
        BoxFit.contain => BoxFit.cover,
        BoxFit.cover => BoxFit.fill,
        _ => BoxFit.contain,
      };
    });
    final label = switch (_fit) {
      BoxFit.contain => '自适应',
      BoxFit.cover => '裁切填充',
      _ => '拉伸',
    };
    _flash(Icons.aspect_ratio_rounded, '画面：$label');
  }

  Widget _topBar() {
    final status = [
      if (_launch?.videoLabel != null) _launch!.videoLabel!,
      if (_launch?.audioLabel != null) _launch!.audioLabel!,
      if (_launch?.container case final c? when c.isNotEmpty)
        c.toUpperCase(),
      _playMethod == 'transcode' ? '转码' : '直连',
    ].join(' · ');
    return _glassPanel(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(
            onPressed: _finalizeAndExit,
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 20),
          ),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(_current.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                    if (_current.seasonEpisode case final se?)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(se,
                            style: TextStyle(
                                fontSize: 11,
                                color: Cf.accent,
                                fontWeight: FontWeight.w600)),
                      ),
                  ]),
                  Text(status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 10.5, color: Cf.text2)),
                ]),
          ),
          SizedBox(width: 14),
        ]),
      ]),
    );
  }

  Widget _bottomBar() {
    final eps = widget.episodes;
    final total = _dur;
    final remaining = total - _pos;
    return _glassPanel(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // 进度条（缓冲 + 章节刻度）
        _ProgressBar(
          position: _pos,
          duration: total,
          buffer: _buf,
          chapters: [for (final c in _chapters) c.seconds],
          onChangeStart: () => _hideTimer?.cancel(),
          onSeek: (d) {
            _player.seek(d);
            // 拖动进度条是"错误续播位置"最主要的来源，必须立刻纠正服务端
            _reportEvent(ProgressEvent.timeUpdate);
            _armHide();
          },
        ),
        SizedBox(height: 4),
        // 时间行：当前(点击切剩余) / 总时长
        Row(children: [
          GestureDetector(
            onTap: () => setState(() => _showRemaining = !_showRemaining),
            child: Text(
              _showRemaining
                  ? '-${_fmt(remaining.isNegative ? Duration.zero : remaining)}'
                  : _fmt(_pos),
              style: TextStyle(
                  fontSize: 10.5,
                  color: Cf.text2,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          const Spacer(),
          Text(_fmt(total),
              style: TextStyle(
                  fontSize: 10.5,
                  color: Cf.text2,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ]),
        SizedBox(height: 2),
        // 控制行（对齐原型 .player-ctrls）
        Row(children: [
          _ctrlBtn(
            icon: Icons.speed_rounded,
            label: '${_rate}x',
            onTap: _showRateSheet,
          ),
          _ctrlBtn(
            icon: Icons.subtitles_outlined,
            label: _subtitleLabel(),
            onTap: _showSubtitleSheet,
          ),
          _ctrlBtn(
            icon: Icons.graphic_eq_rounded,
            label: _audioLabel(),
            onTap: _showAudioSheet,
          ),
          _ctrlBtn(
            icon: Icons.chat_bubble_rounded,
            label: '弹幕',
            active: _danmakuEnabled,
            onTap: _toggleDanmaku,
          ),
          const Spacer(),
          if (eps != null)
            _ctrlBtn(
              icon: Icons.playlist_play_rounded,
              label: '选集 ${_index + 1}/${eps.length}',
              onTap: _showEpisodeSheet,
            ),
          _ctrlBtn(
            icon: Icons.flash_on_rounded,
            label: '跳片头',
            active: _autoIntroSkip,
            onTap: () async {
              setState(() => _autoIntroSkip = !_autoIntroSkip);
              await ref
                  .read(sessionStoreProvider)
                  .setPref('skip_intro_auto', _autoIntroSkip ? '1' : '0');
            },
          ),
          _ctrlBtn(
            icon: Icons.settings_rounded,
            label: '设置',
            onTap: () {
              setState(() => _showSettings = true);
              _hideTimer?.cancel();
            },
          ),
        ]),
        SizedBox(height: 6),
        // 中央三键（玻璃圆钮 + 渐变主键双层辉光）
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _glassCircle(
            icon: Icons.skip_previous_rounded,
            iconSize: 22,
            onTap: (eps != null && _index > 0)
                ? () => _playEpisode(_index - 1)
                : null,
          ),
          SizedBox(width: 20),
          GestureDetector(
            onTap: _togglePlay,
            child: Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: Cf.primaryGradient,
                border: Border.all(color: const Color(0x59FFFFFF), width: 1.5),
                boxShadow: [
                  BoxShadow(
                      color: Cf.accent.withValues(alpha: .45), blurRadius: 22),
                  BoxShadow(
                      color: Cf.accent2.withValues(alpha: .25),
                      blurRadius: 44),
                ],
              ),
              child: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 32,
                  color: Cf.ink),
            ),
          ),
          SizedBox(width: 20),
          _glassCircle(
            icon: Icons.skip_next_rounded,
            iconSize: 22,
            onTap: (eps != null && _index < eps.length - 1)
                ? () => _playEpisode(_index + 1)
                : null,
          ),
        ]),
      ]),
    );
  }

  String _trackShort(String? title, String? language, String id) {
    if (id == 'no') return '关';
    if (title != null && title.isNotEmpty) {
      // 端名往往很长（如 "简体中文 (外挂)"），取首段
      return title.split(' ').first;
    }
    if (language != null && language.isNotEmpty) return language;
    return '开';
  }

  String _subtitleLabel() {
    final t = _player.state.track.subtitle;
    if (t.id == 'no') return '字幕 关';
    return '字幕 ${_trackShort(t.title, t.language, t.id)}';
  }

  String _audioLabel() {
    final t = _player.state.track.audio;
    return '音轨 ${_trackShort(t.title, t.language, t.id)}';
  }

  Widget _ctrlBtn({
    required IconData icon,
    required String label,
    bool active = false,
    VoidCallback? onTap,
  }) {
    final color = active ? Cf.accent : Cf.text2;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: active ? const Color(0x2100D4FF) : const Color(0x14FFFFFF),
          border: Border.all(
              color: active ? Cf.accent : const Color(0x1FFFFFFF)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: color),
          SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 10.5,
                  color: color,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500)),
        ]),
      ),
    );
  }

  // ---------- 设置抽屉（原型 .psettings） ----------

  Widget _settingsDrawer() {
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !_showSettings,
        child: AnimatedSlide(
          offset: _showSettings ? Offset.zero : const Offset(1, 0),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          child: Container(
            width: 272,
            decoration: BoxDecoration(
              color: Color(0xF70D1328),
              border: Border(left: BorderSide(color: Cf.border)),
            ),
            child: SafeArea(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
                      child: Row(children: [
                        Text('播放设置',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w800)),
                        const Spacer(),
                        IconButton(
                          onPressed: () =>
                              setState(() => _showSettings = false),
                          icon: Icon(Icons.close_rounded,
                              size: 18, color: Cf.text2),
                        ),
                      ]),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _psGroup('播放速度', [
                                for (final s in const [
                                  0.5,
                                  0.75,
                                  1.0,
                                  1.25,
                                  1.5,
                                  2.0,
                                  3.0
                                ])
                                  _psOpt('${s}x',
                                      selected: _rate == s,
                                      onTap: () {
                                    _player.setRate(s);
                                    _reportEvent(
                                        ProgressEvent.playbackRateChange);
                                  }),
                              ]),
                              _psGroup('音轨', [
                                for (final t in _player.state.tracks.audio)
                                  _psOpt(
                                      t.title ??
                                          (t.language != null
                                              ? '音轨 ${t.language}'
                                              : '音轨 ${t.id}'),
                                      selected: _player
                                              .state.track.audio.id ==
                                          t.id,
                                      onTap: () => _player.setAudioTrack(t)),
                                if (_player.state.tracks.audio.isEmpty)
                                  Padding(
                                    padding: EdgeInsets.symmetric(vertical: 4),
                                    child: Text('仅一路音轨',
                                        style: TextStyle(
                                            fontSize: 10.5, color: Cf.text3)),
                                  ),
                              ]),
                              _psGroup('字幕', [
                                _psOpt('关闭字幕',
                                    selected: _player
                                            .state.track.subtitle.id ==
                                        'no',
                                    onTap: () => _player
                                        .setSubtitleTrack(SubtitleTrack.no())),
                                for (final t
                                    in _player.state.tracks.subtitle)
                                  _psOpt(
                                      t.title ??
                                          (t.language != null
                                              ? '字幕 ${t.language}'
                                              : '字幕 ${t.id}'),
                                      selected: _player
                                              .state.track.subtitle.id ==
                                          t.id,
                                      onTap: () =>
                                          _player.setSubtitleTrack(t)),
                              ]),
                              _psGroup('弹幕', [
                                _psOpt(
                                    _danmakuEnabled ? '弹幕已开' : '弹幕已关',
                                    selected: _danmakuEnabled,
                                    onTap: _toggleDanmaku),
                                // 加载状态 / 失败原因 / 匹配结果都放在这里，
                                // 让用户在抽屉里就能判断"为什么没弹幕"
                                if (_danmakuLoading)
                                  Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 6),
                                    child: Row(children: [
                                      SizedBox(
                                          width: 13,
                                          height: 13,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 1.6,
                                              color: Cf.accent)),
                                      SizedBox(width: 8),
                                      Text('正在匹配弹幕…',
                                          style: TextStyle(
                                              fontSize: 10.5,
                                              color: Cf.text3)),
                                    ]),
                                  )
                                else if (_danmakuError != null)
                                  Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 6),
                                    child: Text(_danmakuError!,
                                        style: TextStyle(
                                            fontSize: 10.5,
                                            color: Cf.danger)),
                                  )
                                else if (_danmaku.isEmpty)
                                  Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 6),
                                    child: Text('该片暂无弹幕',
                                        style: TextStyle(
                                            fontSize: 10.5, color: Cf.text3)),
                                  )
                                else
                                  Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 6),
                                    child: Text(
                                      '已加载 ${_danmaku.length} 条'
                                      '${_danmakuMatched != null ? ' · ${_danmakuMatched!}' : ''}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 10.5, color: Cf.text3),
                                    ),
                                  ),
                              ]),
                              _psGroup('播放方式', [
                                _psOpt('直连原文件',
                                    selected: _playMethod == 'direct',
                                    onTap: () {
                                      unawaited(
                                          _reopenAs('direct'));
                                    }),
                                _psOpt('转码 1080p',
                                    selected: _playMethod == 'transcode',
                                    onTap: () {
                                      unawaited(_reopenAs('transcode',
                                          reason: '已切换转码 1080p'));
                                    }),
                              ]),
                              _psGroup('画面比例', [
                                _psOpt('自适应',
                                    selected: _fit == BoxFit.contain,
                                    onTap: () => setState(
                                        () => _fit = BoxFit.contain)),
                                _psOpt('裁切填充',
                                    selected: _fit == BoxFit.cover,
                                    onTap: () =>
                                        setState(() => _fit = BoxFit.cover)),
                                _psOpt('拉伸',
                                    selected: _fit == BoxFit.fill,
                                    onTap: () =>
                                        setState(() => _fit = BoxFit.fill)),
                              ]),
                              _psRow('弹幕设置…', '弹幕源 · 样式 · 屏蔽词',
                                  onTap: () {
                                    Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                const DanmakuSettingsPage()));
                                  }),
                              _psGroup('行为', [
                                _psToggle('自动跳过片头', _autoIntroSkip,
                                    (v) async {
                                  setState(() => _autoIntroSkip = v);
                                  await ref
                                      .read(sessionStoreProvider)
                                      .setPref('skip_intro_auto',
                                          v ? '1' : '0');
                                }),
                                _psToggle('自动连播下一集', _autoNextEnabled,
                                    (v) async {
                                  setState(() => _autoNextEnabled = v);
                                  await ref
                                      .read(sessionStoreProvider)
                                      .setPref('auto_next', v ? '1' : '0');
                                }),
                              ]),
                              // 默认倍速：只影响"下次起播"，不改当前播放（当前播放用上面的播放速度组）。
                              // 修复前该偏好有读无写——player_page 读 default_rate，但全项目无写入入口。
                              _psGroup('默认倍速（下次起播）', [
                                for (final s in PlayerPage.defaultRateChoices)
                                  _psOpt(
                                      s == 1.0 ? '1x（默认）' : '${s}x',
                                      selected: _defaultRate == s,
                                      onTap: () async {
                                    setState(() => _defaultRate = s);
                                    await ref
                                        .read(sessionStoreProvider)
                                        .setPref('default_rate',
                                            PlayerPage.encodeDefaultRate(s));
                                  }),
                              ]),
                              SizedBox(height: 6),
                              const Row(children: [
                                // 服务器实测无转码能力（免费版），故当前固定直连；
                                // 结论与依据见 emby_provider.resolvePlayback 注释
                                Text('直连播放（服务器不支持转码）',
                                    style: TextStyle(
                                        fontSize: 10, color: Cf.text3)),
                                Spacer(),
                                Text('● 硬解',
                                    style: TextStyle(
                                        fontSize: 10, color: Cf.success)),
                              ]),
                              SizedBox(height: 14),
                            ]),
                      ),
                    ),
                  ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _psGroup(String label, List<Widget> opts) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 9.5,
                color: Cf.text3,
                fontWeight: FontWeight.w700,
                letterSpacing: 1)),
        SizedBox(height: 7),
        Wrap(spacing: 6, runSpacing: 6, children: opts),
      ]),
    );
  }

  Widget _psOpt(String label,
      {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: selected ? const Color(0x2100D4FF) : Cf.surface2,
          border: Border.all(color: selected ? Cf.accent : Cf.border),
        ),
        child: Text(label,
            maxLines: 1,
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Cf.accent : Cf.text2)),
      ),
    );
  }

  Widget _psRow(String label, String sub, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 11.5, color: Cf.text2)),
              SizedBox(height: 1),
              Text(sub,
                  style: TextStyle(fontSize: 9.5, color: Cf.text3)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, size: 16, color: Cf.text3),
        ]),
      ),
    );
  }

  Widget _psToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(children: [
      Expanded(
          child:
              Text(label, style: TextStyle(fontSize: 11.5, color: Cf.text2))),
      GestureDetector(
        onTap: () => onChanged(!value),
        child: Container(
          width: 32,
          height: 18,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: value ? Cf.accent : Cf.border,
          ),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          padding: const EdgeInsets.all(2),
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? Cf.ink : Cf.text3,
            ),
          ),
        ),
      ),
    ]);
  }

  // ---------- 快捷 sheet（底部控制行入口） ----------

  void _showRateSheet() {
    _showSheet(
      title: '倍速',
      children: [
        for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
          _sheetRow(
            label: '$s 倍速',
            selected: _rate == s,
            onTap: () {
              _player.setRate(s);
              // 倍速影响服务端对进度的推算，须带事件名即刻上报
              _reportEvent(ProgressEvent.playbackRateChange);
              Navigator.pop(context);
            },
          ),
      ],
    );
  }

  void _showAudioSheet() {
    final tracks = _player.state.tracks.audio;
    final current = _player.state.track.audio;
    _showSheet(
      title: '音轨',
      children: [
        if (tracks.isEmpty)
          Padding(
            padding: EdgeInsets.all(14),
            child: Text('仅一路音轨',
                style: TextStyle(fontSize: 12, color: Cf.text3)),
          ),
        for (final t in tracks)
          _sheetRow(
            label: t.title ??
                (t.language != null ? '音轨 ${t.language}' : '音轨 ${t.id}'),
            selected: current.id == t.id,
            onTap: () {
              _player.setAudioTrack(t);
              Navigator.pop(context);
            },
          ),
      ],
    );
  }

  void _showSubtitleSheet() {
    final tracks = _player.state.tracks.subtitle;
    final current = _player.state.track.subtitle;
    _showSheet(
      title: '字幕',
      children: [
        _sheetRow(
          label: '关闭字幕',
          selected: current.id == 'no',
          onTap: () {
            _player.setSubtitleTrack(SubtitleTrack.no());
            Navigator.pop(context);
          },
        ),
        for (final t in tracks)
          _sheetRow(
            label: t.title ??
                (t.language != null ? '字幕 ${t.language}' : '字幕 ${t.id}'),
            selected: current.id == t.id,
            onTap: () {
              _player.setSubtitleTrack(t);
              Navigator.pop(context);
            },
          ),
      ],
    );
  }

  void _showEpisodeSheet() {
    final eps = widget.episodes;
    if (eps == null) return;
    _showSheet(
      title: '选集 · ${_current.displayTitle}',
      maxHeight: 420,
      children: [
        for (var i = 0; i < eps.length; i++)
          _sheetRow(
            label: [
              if (eps[i].indexNumber != null) '第 ${eps[i].indexNumber} 集',
              eps[i].name,
            ].join(' '),
            sub: eps[i].played
                ? '已看'
                : (eps[i].progress > 0
                    ? '看到 ${(eps[i].progress * 100).round()}%'
                    : null),
            selected: i == _index,
            onTap: () {
              Navigator.pop(context);
              _playEpisode(i);
            },
          ),
      ],
    );
  }

  void _showSheet(
      {required String title,
      required List<Widget> children,
      double maxHeight = 300}) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Cf.surface,
      constraints: BoxConstraints(maxHeight: maxHeight),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w800)),
              ),
              Flexible(
                child:
                    SingleChildScrollView(child: Column(children: children)),
              ),
              SizedBox(height: 6),
            ]),
      ),
    );
  }

  Widget _sheetRow(
      {required String label,
      String? sub,
      bool selected = false,
      required VoidCallback onTap}) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 12.5,
              color: selected ? Cf.accent : Cf.text,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      subtitle: sub != null
          ? Text(sub,
              style: TextStyle(fontSize: 10, color: Cf.text3))
          : null,
      trailing: selected
          ? Icon(Icons.check_rounded, size: 18, color: Cf.accent)
          : null,
      onTap: onTap,
    );
  }
}

/// 自定义进度条：底轨 + 缓冲段 + 播放段（渐变）+ 章节刻度 + 拖拽手柄
class _ProgressBar extends StatefulWidget {
  const _ProgressBar({
    required this.position,
    required this.duration,
    required this.buffer,
    required this.onChangeStart,
    required this.onSeek,
    this.chapters = const [],
  });
  final Duration position;
  final Duration duration;
  final Duration buffer;
  final List<double> chapters; // 章节起点（秒）
  final VoidCallback onChangeStart;
  final ValueChanged<Duration> onSeek;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragValue; // 0~1，拖拽中

  @override
  Widget build(BuildContext context) {
    final totalMs =
        widget.duration.inMilliseconds.toDouble().clamp(1, double.infinity);
    final pos = _dragValue ?? (widget.position.inMilliseconds / totalMs);
    final buf = (widget.buffer.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final chapterFractions = widget.duration.inMilliseconds > 0
        ? widget.chapters.map((s) => (s * 1000 / totalMs).clamp(0.0, 1.0))
        : <double>[];
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => widget.onChangeStart(),
        onHorizontalDragUpdate: (d) {
          setState(() {
            _dragValue =
                ((_dragValue ?? pos) + d.delta.dx / w).clamp(0.0, 1.0);
          });
        },
        onHorizontalDragEnd: (_) {
          widget.onSeek(Duration(
              milliseconds: ((_dragValue ?? pos) * totalMs).round()));
          _dragValue = null;
        },
        onTapUp: (d) {
          widget.onSeek(Duration(
              milliseconds: (d.localPosition.dx / w * totalMs).round()));
        },
        child: Container(
          height: 26,
          alignment: Alignment.center,
          child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerLeft,
              children: [
            // 底轨
            Container(
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: const Color(0x2EFFFFFF),
              ),
            ),
            // 缓冲段
            FractionallySizedBox(
              widthFactor: buf,
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: const Color(0x52FFFFFF),
                ),
              ),
            ),
            // 播放段
            FractionallySizedBox(
              widthFactor: pos.clamp(0.0, 1.0),
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  gradient: Cf.primaryGradient,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 章节刻度
            for (final f in chapterFractions)
              Positioned(
                left: (f * w).clamp(0.0, w - 2.0),
                child: Container(
                  width: 2,
                  height: 10,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(1),
                    color: const Color(0x80FFFFFF),
                  ),
                ),
              ),
            // 手柄
            Positioned(
              left: (pos.clamp(0.0, 1.0) * w) - 6,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Cf.accent,
                  boxShadow: [
                    BoxShadow(
                        color: Cf.accent.withValues(alpha: .7), blurRadius: 8),
                  ],
                ),
              ),
            ),
          ]),
        ),
      );
    });
  }
}
