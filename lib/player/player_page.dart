/// 播放器页 —— 安卓原生 mpv 内核（Flutter 纹理输出）+ Emby 直连流 + 进度上报
/// 控制层对齐《CineFlow UI 完整原型》播放器设计：
///   顶栏：返回 + 标题/状态行 + 画幅胶囊 + 设置；底部：时间(点击切剩余) +
///   章节刻度进度条 + 控制行（倍速/字幕/音轨/选集/跳片头开关/设置）；中央三键
///   手势：单击显隐；双击左/中/右 = -10s / 播放暂停 / +10s；长按 = 2.5x；
///        竖滑 = 左亮度 / 右音量（带竖排提示）
///   浮钮：跳过片头（**优先用服务端 `ChapterInfo.MarkerType`**，
///   名称匹配仅作兜底）；自动连播倒计时卡；右侧设置抽屉（原型 .psettings）
///
/// 内核：`PlayerFacade`（lib/player/player_facade.dart）→ `NativeKernel`
///       （安卓原生 mpv，MethodChannel + Flutter 纹理输出）。
///       参考项目：
///         mpv-android    https://github.com/mpv-android/mpv-android
///         androidx/media https://github.com/androidx/media（M3 会话层）
/// 本页只依赖门面的 API 面，**不含任何 media_kit 引用**（K4 已完成）。
library;

import 'dart:async';

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../core/theme.dart';
import '../danmaku/danmaku_config.dart';
import '../danmaku/danmaku_models.dart';
import '../danmaku/danmaku_overlay.dart';
import '../danmaku/danmaku_providers.dart';
import '../danmaku/danmaku_settings_page.dart';
import '../data/emby_provider.dart';
import '../data/media_provider.dart';
import '../data/models.dart';
import '../state/providers.dart';
import 'player_facade.dart';
import 'kernel.dart';
import 'track_aligner.dart';

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

  /// 快进/快退的步长（秒）。用户要求**默认 10s**。
  ///
  /// 做成常量而不是散落的字面量：将来若要进设置页调档（10/15/30s），
  /// 只改这里 + 加一个偏好键即可，不会漏改某一处。
  static const kSeekStepSeconds = 10;

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

  /// 长按倍速的可选档位（用户要求：长按屏幕临时加速）。
  ///
  /// 默认 **2.0x** —— 2x 是人类"听得清但明显更快"的舒适上限；
  /// 3x 以上基本只能靠字幕，作为可选档位提供而不做默认。
  static const holdSpeedChoices = <double>[1.5, 2.0, 2.5, 3.0];

  /// 解析长按倍速偏好。空/非法/越界一律回退 2.0x。
  /// public static 供单测断言。
  static double parseHoldSpeed(String? raw) {
    final v = double.tryParse(raw ?? '');
    if (v == null) return 2.0;
    // 夹在合理区间：<1 无意义（长按应该更快），>4 会掉帧
    if (v < 1.0 || v > 4.0) return 2.0;
    return v;
  }

  // ---------- 控制条按钮的显隐规则（纯函数，public static 供单测）----------
  //
  // ★ 用户规则（原话）：
  //   "如果存在唯一性那就可以隐藏，如果有可选择性那就可以显示"
  //   "选集…如果播放电影…只有一部那就需要隐藏，
  //     如果播放综艺和剧集等有多集的那就需要显示，方便控制"
  //
  // 原则：**只有一个选项的按钮是噪音** —— 点开弹层发现别无选择，
  // 还白占了横屏本就紧张的宽度（这正是"选集被挤出屏幕"的背景）。
  //
  // 做成 static 纯函数而不是 State 的 getter：可单测、无副作用。
  // （此前的教训：逻辑藏在私有 State 里就只能靠真机点击验证，成本极高。）

  /// 「选集」是否显示：**多集才有得选**。
  ///
  /// 电影（无分集）或只有 1 集 → 隐藏。
  /// 注：即使隐藏，自动连播仍正常（那只依赖 episodes 存在，与此按钮无关）。
  static bool showEpisodeButton(List<MediaItem>? episodes) =>
      episodes != null && episodes.length > 1;

  /// 「字幕」是否显示。
  ///
  /// 字幕**多一个"关闭"选项**，所以只要**有 ≥1 条字幕轨**就有得选
  /// （在"某条字幕"与"关闭"之间）。0 条 → 点开只有"关闭"，纯噪音 → 隐藏。
  static bool showSubtitleButton(int subtitleTrackCount) =>
      subtitleTrackCount > 0;

  /// 「音轨」是否显示。
  ///
  /// 音轨**没有"关闭"选项**（关掉声音无意义），所以必须 **≥2 条**才有选择余地。
  static bool showAudioButton(int audioTrackCount) => audioTrackCount > 1;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  /// 播放门面（原生 mpv）。创建是异步的（要先建 Flutter 纹理再 initialize），
  /// 故用可空字段 + 收窄 getter：`_player` 在 `_boot()` 完成后必然非空，
  /// 所有调用点因此保持非空类型，`!` 只集中在这一处。
  /// build 里以 `_ready` 为门，纹理就绪前不渲染视频层。
  PlayerFacade? _facade;
  PlayerFacade get _player => _facade!;

  /// 内核是否已就绪（纹理已建、mpv 已 initialize）
  bool get _ready => _facade != null;

  /// 未就绪时用的空状态。
  ///
  /// 控制层/抽屉的 **build 路径**会读 `state`（字幕/音轨标签、设置抽屉），
  /// 而它们在 `_boot()` 完成前就可能被渲染（比如起播很慢时用户点了设置）。
  /// 给一个常量兜底，比在每个读取点写 `?.` 更不易漏、也更省重复。
  static const _emptyState = FacadePlayerState(
    position: Duration.zero,
    duration: Duration.zero,
    buffer: Duration.zero,
    playing: false,
    buffering: false,
    rate: 1.0,
    volume: 100,
    completed: false,
    track: FacadeTrack(
      audio: FacadeAudioTrack(id: 'auto'),
      subtitle: FacadeSubtitleTrack(id: 'auto'),
    ),
    tracks: FacadeTracks(audio: [], subtitle: []),
  );

  /// 状态快照（未就绪时返回空状态；**只可用于读**）
  FacadePlayerState get _pstate => _facade?.state ?? _emptyState;

  /// 视频尺寸变化计数（Texture 需要重建才能反映新宽高比）
  int _videoTick = 0;

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

  /// 是否正处于"长按倍速"状态。
  ///
  /// 用独立标志而不是"当前倍速 == 2.5"来判断 ——
  /// 后者在用户把常速本身就设成 2.5x 时会误判，导致松手后被重置为 1.0x
  /// （改造前的真实 bug）。
  bool _holdingSpeed = false;

  /// 长按时的倍速（可在「播放设置」里选，默认 2.0x）。
  double _holdSpeed = 2.0;

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
    // 内核创建是异步的（要先建 Flutter 纹理再 initialize mpv），
    // 故 _start() 放进 _boot()，避免在 _player 还是 null 时就用它。
    unawaited(_boot());
  }

  /// 建内核 → 订阅流 → 起播。
  ///
  /// 顺序不能反：`createPlayerFacade` 内部会先 `createTexture` 再 `initialize`，
  /// 因为 mpv 的 `wid` 必须在 `mpv_initialize` 之前设好（见 PlayerChannel 注释）。
  Future<void> _boot() async {
    try {
      final p = await createPlayerFacade();
      if (!mounted) {
        unawaited(p.dispose());
        return;
      }
      _facade = p;
      _subs.addAll([
        p.stream.position.listen((d) {
          setState(() => _pos = d);
          _checkIntroSkip();
        }),
        p.stream.duration.listen((d) => setState(() => _dur = d)),
        p.stream.buffer.listen((d) => setState(() => _buf = d)),
        p.stream.playing.listen((b) {
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
        p.stream.buffering.listen((b) => setState(() => _buffering = b)),
        p.stream.rate.listen((r) => setState(() => _rate = r)),
        // 视频尺寸（宽高比）：纹理要重建才能反映新的 AspectRatio
        p.videoSizeStream.listen((_) {
          if (mounted) setState(() => _videoTick++);
        }),
        p.stream.error.listen((e) {
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
        p.stream.completed.listen((done) {
          if (done) _onCompleted();
        }),
      ]);
      await _start();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '播放器初始化失败：$e';
          _resolving = false;
        });
      }
    }
  }

  Future<void> _loadPrefs() async {
    final store = ref.read(sessionStoreProvider);
    final autoIntro = await store.getPref('skip_intro_auto');
    final autoNext = await store.getPref('auto_next');
    final defaultRate = await store.getPref('default_rate');
    final holdSpeed = await store.getPref('hold_speed');
    if (mounted) {
      setState(() {
        _autoIntroSkip = autoIntro != '0'; // 默认开
        _autoNextEnabled = autoNext != '0'; // 默认开
        _defaultRate = PlayerPage.parseDefaultRate(defaultRate);
        _holdSpeed = PlayerPage.parseHoldSpeed(holdSpeed);
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
      await _player.openUrl(launch.url,
          play: true, headers: launch.headers);
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
      // ★ 按服务端指定的默认轨起播（用户指出的"致命问题"的收尾）
      //
      //   服务端 `MediaSource.DefaultAudioStreamIndex` /
      //   `DefaultSubtitleStreamIndex` 明确指定了"该用哪条轨"——
      //   实测某片返回 `DefaultAudioStreamIdx=1`，且流的 DisplayTitle 带
      //   "(默认)" 标记。而此前这两个字段**解析了却零消费**，
      //   起播完全依赖 mpv 自己的默认选择（可能与服务端不一致，例如
      //   服务端选国语、mpv 选第一条英语）。
      //
      //   火后不管（不 await）：切轨要等内核 `track-list` 事件到达，
      //   此处若 await 会拖慢起播；失败也无害（保持 mpv 默认）。
      unawaited(_applyServerDefaultTracks(launch));
      // 章节与片头区间。
      // ★ 现在**直接读 launch.chapters**（服务端把章节放在 PlaybackInfo 的
      //   MediaSource 里），**不再单独发 getChapters 请求** ——
      //   省掉一次 HTTP 往返（审计发现的重复请求）。
      //   仅当 launch 里没有章节时才回退到单独查询（老服务器/异常情况）。
      if (launch.chapters.isNotEmpty) {
        setState(() => _chapters = launch.chapters);
        _intro = _detectIntro(launch.chapters);
      } else {
        // 回退路径：服务端没在 PlaybackInfo 里给章节时，单独查一次
        api.getChapters(_current.id).then((ch) {
          if (!mounted || ch.isEmpty) return;
          setState(() => _chapters = ch);
          _intro = _detectIntro(ch);
        }).catchError((_) {});
      }
    } on MediaException catch (e) {
      setState(() {
        _error = e.message;
        _resolving = false;
      });
    } catch (e, st) {
      // ⚠️ 这里原来是 `catch (_)` —— **真实异常被整个丢掉**：
      // 不打日志、不显示原因，用户只看到笼统的"起播失败，请稍后重试"，
      // 排查时连一行线索都没有（实测就踩到了：真机上点播放只出这句话，
      // logcat 里什么都没有）。这与缺陷 §7.8「不要把失败伪装成正常」同类。
      //
      // 现在：日志留全栈（供排查），界面显示**真实原因**（供用户判断能否自救，
      // 比如"服务器不可达" vs "这个文件没有可播流"）。
      debugPrint('[Player] 起播失败: $e\n$st');
      setState(() {
        _error = '起播失败：$e';
        _resolving = false;
      });
    }
  }

  /// 识别片头区间 **(开始秒, 结束秒)**。
  ///
  /// ## 策略：优先用服务端的原生标记，名称匹配只作兜底
  ///
  /// ⚠️ **旧注释"Emby 无原生片头检测，用名称匹配"是错的**，已实测推翻：
  /// 本服务器某剧集章节的 `MarkerType` 为
  /// `Chapter, IntroStart, IntroEnd, Chapter, …` —— 服务端**早已标好**。
  ///
  /// 而名称匹配（`contains('片头')||'intro'||'opening'`）是脆弱启发式：
  ///   · 叫"主题曲"/"OP"/"序章" → **识别不到**（功能失效）
  ///   · 叫"片头曲欣赏"/"片头解析" → **误跳**（更糟，直接跳过正片内容）
  ///
  /// 故顺序为：
  ///   1. **`MarkerType == 'IntroStart'` → 找配对的 `IntroEnd`**（精确）
  ///   2. 服务端没标 → 退回名称匹配（老库/未开 marker 检测时仍可用）
  (double, double)? _detectIntro(List<MediaChapter> ch) {
    // ① 服务端原生标记（首选）
    for (var i = 0; i < ch.length; i++) {
      if (!ch[i].isIntroStart) continue;
      final start = ch[i].seconds;
      // 找它之后的第一个 IntroEnd 作为终点
      for (var j = i + 1; j < ch.length; j++) {
        if (ch[j].isIntroEnd) {
          final end = ch[j].seconds;
          if (end > start) return (start, end);
          break;
        }
      }
      // 有 IntroStart 却没有配对的 IntroEnd：用下一章起点兜底
      final end = i + 1 < ch.length ? ch[i + 1].seconds : start + 120.0;
      if (end > start) return (start, end);
      break;
    }

    // ② 兜底：名称匹配（服务端未标记时）
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

  /// 按服务端指定的默认轨设置音轨/字幕轨。
  ///
  /// ## 为什么需要（用户指出的"致命问题"的收尾）
  ///
  /// 服务端 `MediaSource.DefaultAudioStreamIndex` /
  /// `DefaultSubtitleStreamIndex` 明确说了"该用哪条轨"，但此前**零消费** ——
  /// 起播完全靠 mpv 自己的默认选择，可能与服务端不一致
  /// （服务端选国语、mpv 挑第一条英语；或服务端说"不开字幕"、mpv 却开了）。
  ///
  /// ## 为什么要等 `track-list` 事件
  ///
  /// `openUrl` 返回时内核的 `track-list` 往往**还没到**（要解封装完成后才有），
  /// 此时 `_pstate.tracks` 是空的，直接查会找不到轨道 → 故轮询等待（最多 ~3 秒）。
  ///
  /// ## 为什么不能直接用 index 当 id
  ///
  /// 服务端的 index 是 **ffmpeg 全局流索引**，内核的 id 是**每类型独立编号**，
  /// 两者不同 → 必须用 `TrackAligner`（对齐 `ff-index`）。
  /// 用 id 直接比会**切错轨**（见 `kernel.dart` 的 `ffIndex` 注释）。
  Future<void> _applyServerDefaultTracks(PlaybackLaunch launch) async {
    final wantAudio = launch.defaultAudioIndex;
    final wantSub = launch.defaultSubtitleIndex;
    // 服务端什么都没指定 → 保持 mpv 默认（不做多余操作）
    if (wantAudio == null && wantSub == null) return;

    // 等内核上报轨道（最多 3s，每 200ms 探一次）
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      if (_pstate.tracks.audio.isNotEmpty ||
          _pstate.tracks.subtitle.isNotEmpty) {
        break;
      }
    }
    if (!mounted) return;

    try {
      // —— 音轨 ——
      if (wantAudio != null) {
        final server = launch.streams.where((s) => s.type == 'Audio').toList();
        final aligned = TrackAligner.alignAudio(server, _pstate.tracks.audio,
            defaultIndex: wantAudio);
        final hit = aligned.where((a) => a.isDefault).toList();
        if (hit.isNotEmpty) {
          final k =
              _pstate.tracks.audio.where((t) => t.id == hit.first.kernelId);
          if (k.isNotEmpty) await _player.setAudioTrack(k.first);
        }
      }

      // —— 字幕 ——
      // `DefaultSubtitleStreamIndex == null` 表示**服务端默认不开字幕**；
      // 此时不主动关（尊重 mpv/用户习惯），只在服务端明确指定时切。
      if (wantSub != null) {
        final server =
            launch.streams.where((s) => s.type == 'Subtitle').toList();
        final aligned = TrackAligner.alignSubtitle(
            server, _pstate.tracks.subtitle,
            defaultIndex: wantSub);
        final hit = aligned.where((a) => a.isDefault).toList();
        if (hit.isNotEmpty) {
          final k =
              _pstate.tracks.subtitle.where((t) => t.id == hit.first.kernelId);
          if (k.isNotEmpty) await _player.setSubtitleTrack(k.first);
        }
      }
    } catch (e) {
      // 非致命：设不上默认轨不影响播放，用户仍可手动切
      debugPrint('[Player] 应用服务端默认轨失败（非致命）: $e');
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
      await _player.openUrl(launch.url,
          play: true, headers: launch.headers);
      _reportStart(launch);
      // 换集是新的媒体源 → 默认轨也要按新集的服务端设置重新应用
      // （各集的音轨/字幕轨数量与默认索引都可能不同）
      unawaited(_applyServerDefaultTracks(launch));
      // 章节优先读 launch 带来的（省一次请求），缺失时才单独查
      if (launch.chapters.isNotEmpty) {
        setState(() => _chapters = launch.chapters);
        _intro = _detectIntro(launch.chapters);
      } else {
        api.getChapters(_current.id).then((ch) {
          if (!mounted || ch.isEmpty) return;
          setState(() => _chapters = ch);
          _intro = _detectIntro(ch);
        }).catchError((_) {});
      }
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
      await _player.openUrl(
          method == 'transcode' ? launch.transcodingUrl! : launch.url,
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

  /// 相对当前进度跳转（快进/快退）。
  ///
  /// ## 为什么统一成一个方法
  /// 双击手势（左右 1/3 屏）与控制层的 ±10s 按钮**是同一件事**，
  /// 必须共用同一份边界处理 —— 否则会出现"双击能退到负值、按钮不能"
  /// 这类不一致。原先只有双击在用，控制层那两个键是"上一集/下一集"（用户反馈没用）。
  ///
  /// 边界处理（否则有两个恼人现象）：
  ///   · 退到 0 之前 → 夹到 0（不然 mpv 收到负时间会报错且位置异常）
  ///   · 快进超过总长 → 夹到 `duration - 1s`（留 1s 触发"播放结束"逻辑；
  ///     直接 seek 到 duration 会让 mpv 立刻 end-file，自动连播反而不触发）
  Future<void> _seekBy(int seconds) async {
    var target = _pos + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    final total = _dur;
    if (total > Duration.zero) {
      final max = total - const Duration(seconds: 1);
      if (target > max) target = max > Duration.zero ? max : Duration.zero;
    }
    await _player.seek(target);
    // 跳转后立即上报新的位置：服务端在按旧位置递增进度，
    // 若不纠正，此后 10 秒内退出就会把错误位置存成"继续观看"点。
    _reportEvent(ProgressEvent.timeUpdate);
    _flash(seconds < 0 ? Icons.replay_10_rounded : Icons.forward_10_rounded,
        seconds < 0 ? '快退 ${-seconds}s' : '快进 ${seconds}s');
    _armHide();
  }

  Future<void> _togglePlay() async {
    _playing ? await _player.pause() : await _player.play();
    _flash(_playing ? Icons.play_arrow_rounded : Icons.pause_rounded, null);
    _armHide();
  }

  /// 长按屏幕 → 临时倍速播放（用户要求）。
  ///
  /// ## 改造前的问题
  /// · **硬编码 2.5x**：用户无法自选（有人习惯 2x，有人要 3x）
  /// · 恢复逻辑有 bug：`_rate == 2.5 ? 1.0 : _rate` —— 若用户本来就把
  ///   常速设成 2.5x，长按松手后会被**错误地重置为 1.0x**
  /// · 松手后只清 `_flashIcon`，**没有恢复"控制层自动隐藏"的计时**
  ///   （`_armHide` 在末尾调了但没重置 `_hideTimer`），可能停留 2.5x 状态
  /// · 长按期间**没有视觉提示强度**（只有一个小 flash 图标）
  ///
  /// ## 现在的行为
  /// · 倍速档位可在「播放设置」里选（默认 2.0x）
  /// · 长按立刻升到该倍速，屏幕中央显示"2.0x 倍速中"提示
  /// · 松手**精确恢复**到长按前的倍速（用一个独立的 `_rateBeforeHold`
  ///   标志判断是否处于长按中，不再靠"当前值 == 2.5"猜）
  /// · 若长按中途滑动/退出，也保证恢复（见 `_onLongPressEnd` 与 dispose）
  void _onLongPressStart() {
    if (_locked) return;
    // 已经在长按中就不重复触发（Flutter 可能因多指重复回调）
    if (_holdingSpeed) return;
    _holdingSpeed = true;
    _rateBeforeHold = _rate;
    _player.setRate(_holdSpeed);
    _flash(Icons.fast_forward_rounded, '${_holdSpeed}x 倍速中');
    // 长按期间不要让控制层自动隐藏（否则提示会消失，用户以为没生效）
    _hideTimer?.cancel();
  }

  void _onLongPressEnd() {
    if (!_holdingSpeed) return;
    _holdingSpeed = false;
    _player.setRate(_rateBeforeHold);
    setState(() => _flashIcon = null);
    _armHide();
  }

  /// 竖滑：左半屏亮度 / 右半屏音量（对齐原型 gesture-hints）
  void _onVerticalDragStart(DragStartDetails d) {
    if (_locked) return;
    _dragBrightness =
        d.globalPosition.dx < MediaQuery.sizeOf(context).width / 2;
    _dragValue = _dragBrightness ? 1.0 : _pstate.volume / 100;
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
              // 视频层：原生 mpv 的 Flutter 纹理。
              // 未就绪（内核还在建纹理/mpv 还没 initialize）时也渲染黑底，
              // 否则 GestureDetector 会因为子控件缺失而收不到手势。
              child: (_resolving || _error != null || !_ready)
                  ? Container(color: Colors.black)
                  : _player.videoView(fit: _fit, tick: _videoTick),
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
              // 一次性取出配置再取值：原先连写 6 个 `ref.watch(...).value?.x ?? 默认`
              // 既啰嗦又容易在新增设置项时漏加（漏了就是"设置了不生效"）。
              child: Builder(builder: (context) {
                final dc =
                    ref.watch(danmakuConfigProvider).value ??
                        const DanmakuConfig();
                return DanmakuOverlay(
                  items: _danmaku,
                  position: _pos,
                  enabled: _danmakuEnabled,
                  opacity: dc.opacity,
                  fontScale: dc.fontScale,
                  blockedWords: dc.blockedWords,
                  showArea: dc.showArea,
                  // 对照 B 站新增：类型开关 / 速度 / 加粗 / 防挡字幕
                  modes: dc.modes,
                  speed: dc.speed,
                  bold: dc.bold,
                  avoidSubtitle: dc.avoidSubtitle,
                );
              }),
            ),

          // 居中：加载 / 错误 / 缓冲 / 竖滑反馈 / 手势反馈
          if (_resolving || _error != null)
            Center(
              child: _error != null
                  // ★ 用户反馈「视频点击播放时会闪红」—— 就是这里：
                  //   原实现是**整圈 danger 红描边**的对话框，在深色画面上
                  //   一整块红色非常刺眼，且 `_resolving` 与 `_error` 共用同一个
                  //   渲染槽位，切换瞬间会先出现再消失 → 观感是"闪一下红"。
                  //
                  //   改为 Material 的错误呈现：**中性面板 + 红色仅用于图标**，
                  //   红色面积从"整圈边框"降到"16px 图标"，不再刺眼；
                  //   文案左对齐、给出可操作提示（点任意处退出）。
                  ? _errorPanel()
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
                  child: Icon(_flashIcon, size: 24, color: Colors.white),
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
                      size: 20, color: Cf.warn),
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
                        // ⚠️ 原先是硬编码 0x2100D4FF（青色 13%）。紧邻的边框用的是
                        // Cf.accent（随主题切换），两者在外观页切到绿/紫/橙时会**不同色**。
                        // 实测确认的 bug，改用 accent 的透明度派生。
                        color: Cf.accent.withValues(alpha: 0.13),
                        border: Border.all(color: Cf.accent),
                      ),
                      child: Text('切换转码',
                          style: TextStyle(
                              fontSize: 11,
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
                              TextStyle(fontSize: 11, color: Cf.text3)),
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
                          fontSize: 12,
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

  /// 播放器错误面板。
  ///
  /// ## 为什么不用「整圈红边框」（用户反馈"播放时闪红"）
  ///
  /// 原实现是 `Border.all(color: Cf.danger)` 的对话框 —— 在**深色视频画面**上
  /// 一整圈高饱和红非常刺眼；加上 `_resolving` 与 `_error` 共用同一渲染槽位，
  /// 起播失败瞬间会"出现→消失"，观感就是**闪一下红**。
  ///
  /// 改为 Material 的错误呈现惯例（对齐 MUI `Alert severity="error"`）：
  ///   · 面板本身是中性 `surface`（不刺眼）
  ///   · **红色只用于 20px 图标** —— 信号色而非大面积填充
  ///   · 文案左对齐、次级色；下方给出**可操作**的下一步
  Widget _errorPanel() {
    return GestureDetector(
      onTap: _finalizeAndExit,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Cf.surface,
          borderRadius: BorderRadius.circular(Cf.radiusMd),
          // 描边只表达边界，不用信号色（深色主题靠描边分层，见 UI-DESIGN §1.5）
          border: Border.all(color: Cf.border),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.error_outline_rounded,
              size: Cf.iconMd, color: Cf.danger),
          const SizedBox(width: Cf.gap3),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('无法播放',
                      style: Cf.body.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Cf.gap1),
                  Text(_error!,
                      style: Cf.caption.copyWith(color: Cf.text2, height: 1.5)),
                  const SizedBox(height: Cf.gap2),
                  Text('点此返回', style: Cf.micro.copyWith(color: Cf.text3)),
                ]),
          ),
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
          size: 24,
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
  ///
  /// ## 命中区与视觉尺寸分开（横屏可用性）
  ///
  /// 播放器是**横屏**使用的，可用高度只有 ~393dp；控制层按钮若按视觉尺寸
  /// （实测有调用点传 `iconSize: 18`，即约 18dp）当命中区，只有 48dp 标准的
  /// **约 1/3**，躺着看片时几乎点不中——而播放器里误触代价更大（跳进度/退出）。
  ///
  /// 故：**视觉仍可小（`size`），外面套一层 ≥48dp 的透明命中区**
  /// （`hitSize` 默认 48）。这也是参考项目的既有结论：
  /// 「横屏播放器的 chip 视觉 32dp，命中区撑到 44dp」。
  ///
  /// 顺带把裸 `GestureDetector` 换成 `InkWell`：有按压反馈，
  /// 且 `behavior: opaque` 保证透明区域也能接到点击。
  Widget _glassCircle({
    required IconData icon,
    required VoidCallback? onTap,
    double size = 46,
    double iconSize = 20,
    double hitSize = 48,
  }) {
    final target = hitSize > size ? hitSize : size;
    return SizedBox(
      width: target,
      height: target,
      child: Center(
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
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
          ),
        ),
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
                          TextStyle(fontSize: 11, color: Cf.text2)),
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
                  fontSize: 11,
                  color: Cf.text2,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          const Spacer(),
          Text(_fmt(total),
              style: TextStyle(
                  fontSize: 11,
                  color: Cf.text2,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ]),
        SizedBox(height: 2),
        // 控制行
        //
        // ★★ 用户反馈"播放中的选集按钮消失了" —— 根因是**横向溢出被裁**：
        //    这一行塞了 7 个按钮（倍速/字幕/音轨/弹幕/选集/跳片头/设置），
        //    横屏可用宽约 843dp，而按钮宽度随标签长度变化（"选集 5/34"、
        //    字幕/音轨带轨道名时更宽）。`Row` 没有滚动也没有 Flexible，
        //    **超出的部分直接画到屏幕外** —— 表现为"按钮不见了"。
        //    上一轮我把 `_ctrlBtn` 的命中区从 32dp 提到 48dp、图标 16→20，
        //    每个按钮变宽，于是把尾部的按钮挤了出去（加剧了这个问题）。
        //
        //    修法（两层保险）：
        //      1. **选集按钮固定在左侧、始终可见**（它是播放剧集最常用的入口，
        //         不该因为标签长而被挤掉）
        //      2. 其余按钮放进**横向滚动**区，任何宽度下都能访问到，
        //         而不是被静默裁掉
        Row(children: [
          // —— 固定区：选集 ——
          // 仅在"多集"时显示（电影/单集没有选择余地 → 隐藏，避免噪音）
          if (_showEpisodeBtn) ...[
            _ctrlBtn(
              icon: Icons.playlist_play_rounded,
              label: '选集 ${_index + 1}/${eps!.length}',
              onTap: _showEpisodeSheet,
            ),
            const SizedBox(width: Cf.gap2),
          ],
          // —— 滚动区：其余功能钮 ——
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // 关掉滚动条指示（横屏控制条上多余）
              physics: const ClampingScrollPhysics(),
              child: Row(children: [
                _ctrlBtn(
                  icon: Icons.speed_rounded,
                  label: '${_rate}x',
                  onTap: _showRateSheet,
                ),
                // 字幕：无字幕轨时隐藏（点开只有"关闭"，无可选）
                if (_showSubtitleBtn)
                  _ctrlBtn(
                    icon: Icons.subtitles_outlined,
                    label: _subtitleLabel(),
                    onTap: _showSubtitleSheet,
                  ),
                // 音轨：少于 2 条时隐藏（音轨没有"关闭"选项，1 条即无可选）
                if (_showAudioBtn)
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
                // ★ 「跳片头」已从控制条移除（用户要求）——
                //   它是个"设置一次就不再改"的偏好，放在播放中的控制条上
                //   属于噪音；改到「我的 → 播放设置」里开关。
                //   偏好键仍是 `skip_intro_auto`，`_autoIntroSkip` 的自动跳过
                //   逻辑**完全不受影响**（它只读这个字段，不依赖按钮存在）。
                _ctrlBtn(
                  icon: Icons.settings_rounded,
                  label: '设置',
                  onTap: () {
                    setState(() => _showSettings = true);
                    _hideTimer?.cancel();
                  },
                ),
              ]),
            ),
          ),
        ]),
        SizedBox(height: 6),
        // 中央三键：**快退 10s / 播放暂停 / 快进 10s**
        //
        // ★ 用户反馈"快进和后退按键没有用"——
        //   原因是原来这两个键根本不是快进/快退，而是**上一集/下一集**
        //   （`skip_previous`/`skip_next` + `_playEpisode`），
        //   而且还有个更隐蔽的问题：它们带 `eps != null && _index > 0` 守卫，
        //   从首页「继续观看」直接进播放器时 episodes 为 null，
        //   两个键**直接变成禁用态**（`onTap: null`）→ 按了毫无反应。
        //
        //   现在按用户要求改为**±10s 跳转**（B 站/YouTube 的常见交互），
        //   且**不依赖 episodes**，任何进入路径都可用。
        //   切集仍可通过「选集」抽屉完成，不丢功能。
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _glassCircle(
            icon: Icons.replay_10_rounded,
            iconSize: Cf.iconLg,
            onTap: () => _seekBy(-PlayerPage.kSeekStepSeconds),
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
                  size: 40,
                  color: Cf.ink),
            ),
          ),
          SizedBox(width: 20),
          _glassCircle(
            icon: Icons.forward_10_rounded,
            iconSize: Cf.iconLg,
            onTap: () => _seekBy(PlayerPage.kSeekStepSeconds),
          ),
        ]),
      ]),
    );
  }

  /// 控制条上的**短标签**（空间有限，只取最关键的一段）。
  ///
  /// 与 `_trackDisplay`（弹层里用的完整名）分工不同：
  /// 控制条一个按钮只有 ~60dp，塞不下"简体中文 · 5.1 声道 · eac3"。
  String _trackShort(String? title, String? language, String id) {
    if (id == 'no') return '关';
    if (title != null && title.isNotEmpty) {
      // 端名往往很长（如 "简体中文 (外挂)"），取首段
      return title.split(' ').first;
    }
    if (language != null && language.isNotEmpty) {
      return KernelTrack(id: id, language: language).displayName;
    }
    return '开';
  }

  /// 弹层里的**完整轨道名**（用户要求："多音轨多字幕…显示出名称，
  /// 像字幕的话有中字、双语、繁体等"）。
  ///
  /// 复用 `KernelTrack.displayName` 的拼装规则，保证**弹层与控制条口径一致**
  /// （不会出现弹层写"中文 · 5.1 声道"而按钮写"开"这种割裂）。
  String _trackDisplay(
    String? title,
    String? language,
    String id, {
    String? codec,
    int? channels,
    bool external = false,
    bool forced = false,
  }) {
    return KernelTrack(
      id: id,
      title: title,
      language: language,
      codec: codec,
      channels: channels,
      isExternal: external,
      isForced: forced,
    ).displayName;
  }

  String _subtitleLabel() {
    final t = _pstate.track.subtitle;
    if (t.id == 'no') return '字幕 关';
    return '字幕 ${_trackShort(t.title, t.language, t.id)}';
  }

  String _audioLabel() {
    final t = _pstate.track.audio;
    return '音轨 ${_trackShort(t.title, t.language, t.id)}';
  }

  // ---------- 控制条按钮的「该不该显示」判定 ----------
  //
  // 规则本体在 `PlayerPage.showXxxButton`（public static，可单测）；
  // 这里只把当前播放状态喂进去。

  /// 「选集」按钮是否显示
  bool get _showEpisodeBtn => PlayerPage.showEpisodeButton(widget.episodes);

  /// 「字幕」按钮是否显示
  bool get _showSubtitleBtn =>
      PlayerPage.showSubtitleButton(_pstate.tracks.subtitle.length);

  /// 「音轨」按钮是否显示
  bool get _showAudioBtn =>
      PlayerPage.showAudioButton(_pstate.tracks.audio.length);

  /// 控制层功能钮（速度 / 字幕 / 音轨 / 弹幕 / 选集 / 跳片头 / 设置）。
  ///
  /// ## 改造前的问题（用户反馈"有些按键没有用""需要优化"）
  ///
  /// 1. **高度只有 32dp** —— 低于 Material 的 48dp 触控基线（`UI-DESIGN.md` §3.1）。
  ///    播放器是**横屏**使用的，可用高仅 393dp，躺着看片时 32dp 很难点中。
  /// 2. **裸 `GestureDetector`** —— **没有任何按压反馈**。用户点了之后
  ///    界面上毫无变化（尤其"跳片头"这类开关，只改内部状态不改图标时，
  ///    看起来就像"点了没用"）。这是"按键没用"观感的主要来源。
  /// 3. 无 tooltip —— 图标语义不够直观时无从确认。
  ///
  /// ## 改法（对齐 Material 3 / MUI 的 chip 规范）
  ///
  /// · 视觉尺寸保持紧凑（**32dp 高**，横屏下不臃肿）
  /// · 外层套 **48dp 透明命中区**（视觉与命中区分离，同 `_glassCircle`）
  /// · 改用 `InkWell` → 有涟漪反馈
  /// · `active` 态**同时改底色+描边+文字粗细+图标填充**，让开关状态一眼可见
  Widget _ctrlBtn({
    required IconData icon,
    required String label,
    bool active = false,
    VoidCallback? onTap,
  }) {
    final color = active ? Cf.accent : Cf.text2;
    return SizedBox(
      height: 48, // 命中区 ≥48dp（视觉仍是下面的 32dp）
      child: Center(
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                // 原为硬编码 0x2100D4FF：切主题时会与 Cf.accent 边框不同色（实测 bug）
                color: active
                    ? Cf.accent.withValues(alpha: 0.16)
                    : const Color(0x14FFFFFF),
                border: Border.all(
                    color: active ? Cf.accent : const Color(0x1FFFFFFF)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: Cf.iconSm, color: color),
                const SizedBox(width: 5),
                Text(label,
                    style: Cf.caption.copyWith(
                        color: color,
                        fontWeight:
                            active ? FontWeight.w800 : FontWeight.w500)),
              ]),
            ),
          ),
        ),
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
                              size: 20, color: Cf.text2),
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
                                for (final t in _pstate.tracks.audio)
                                  _psOpt(
                                      t.title ??
                                          (t.language != null
                                              ? '音轨 ${t.language}'
                                              : '音轨 ${t.id}'),
                                      selected: _player
                                              .state.track.audio.id ==
                                          t.id,
                                      onTap: () => _player.setAudioTrack(t)),
                                if (_pstate.tracks.audio.isEmpty)
                                  Padding(
                                    padding: EdgeInsets.symmetric(vertical: 4),
                                    child: Text('仅一路音轨',
                                        style: TextStyle(
                                            fontSize: 11, color: Cf.text3)),
                                  ),
                              ]),
                              _psGroup('字幕', [
                                _psOpt('关闭字幕',
                                    selected: _player
                                            .state.track.subtitle.id ==
                                        'no',
                                    onTap: () => _player
                                        .setSubtitleTrack(FacadeSubtitleTrack.no)),
                                for (final t
                                    in _pstate.tracks.subtitle)
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
                                              fontSize: 11,
                                              color: Cf.text3)),
                                    ]),
                                  )
                                else if (_danmakuError != null)
                                  Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 6),
                                    child: Text(_danmakuError!,
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Cf.danger)),
                                  )
                                else if (_danmaku.isEmpty)
                                  Padding(
                                    padding:
                                        EdgeInsets.symmetric(vertical: 6),
                                    child: Text('该片暂无弹幕',
                                        style: TextStyle(
                                            fontSize: 11, color: Cf.text3)),
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
                                          fontSize: 11, color: Cf.text3),
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
                              // 长按倍速（用户要求新增）：长按屏幕时临时升到的倍速。
                              // 与上面的"播放速度"不同——那个是常速；这个是按住才生效。
                              _psGroup('长按倍速（按住屏幕）', [
                                for (final s in PlayerPage.holdSpeedChoices)
                                  _psOpt(
                                      '${s}x',
                                      selected: _holdSpeed == s,
                                      onTap: () async {
                                    setState(() => _holdSpeed = s);
                                    await ref
                                        .read(sessionStoreProvider)
                                        .setPref('hold_speed', '$s');
                                    // 立刻让用户看到效果（长按提示会显示新档位）
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
                fontSize: 10,
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
          // 同上：硬编码 0x2100D4FF → 改用 accent 派生，保证切主题一致。
          color: selected
              ? Cf.accent.withValues(alpha: 0.13)
              : Cf.surface2,
          border: Border.all(color: selected ? Cf.accent : Cf.border),
        ),
        child: Text(label,
            maxLines: 1,
            style: TextStyle(
                fontSize: 11,
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
                      fontSize: 12, color: Cf.text2)),
              SizedBox(height: 1),
              Text(sub,
                  style: TextStyle(fontSize: 10, color: Cf.text3)),
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
              Text(label, style: TextStyle(fontSize: 12, color: Cf.text2))),
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
    final tracks = _pstate.tracks.audio;
    final current = _pstate.track.audio;
    // ★ 用服务端的好名字：把内核轨道与 launch.streams 按 ffIndex 对齐。
    //   内核只给 codec/channels（拼出来 "6ch · eac3"），
    //   服务端给 "Chinese TRUEHD 5.1 (默认)" —— 后者才是用户要的。
    final aligned = _alignedAudio();
    _showSheet(
      title: '音轨（${tracks.length} 条）',
      children: [
        if (tracks.isEmpty)
          Padding(
            padding: EdgeInsets.all(14),
            child: Text('仅一路音轨',
                style: TextStyle(fontSize: 12, color: Cf.text3)),
          ),
        for (var i = 0; i < tracks.length; i++)
          _sheetRow(
            label: _audioSheetLabel(i, aligned, tracks[i]),
            selected: current.id == tracks[i].id,
            onTap: () {
              _player.setAudioTrack(tracks[i]);
              Navigator.pop(context);
            },
          ),
      ],
    );
  }

  /// 把当前内核音轨与服务端 `MediaStream` 对齐（音轨）。
  ///
  /// `_launch` 为 null（深链回退路径）时返回空 → 调用方走内核兜底名字。
  List<AlignedTrack> _alignedAudio() {
    final server = _launch?.streams.where((s) => s.type == 'Audio').toList();
    if (server == null || server.isEmpty) return const [];
    return TrackAligner.alignAudio(server, _pstate.tracks.audio,
        defaultIndex: _launch?.defaultAudioIndex);
  }

  /// 把当前内核字幕轨与服务端 `MediaStream` 对齐。
  List<AlignedTrack> _alignedSubtitle() {
    final server =
        _launch?.streams.where((s) => s.type == 'Subtitle').toList();
    if (server == null || server.isEmpty) return const [];
    return TrackAligner.alignSubtitle(server, _pstate.tracks.subtitle,
        defaultIndex: _launch?.defaultSubtitleIndex);
  }

  /// 音轨弹层里第 [i] 行的显示名：优先对齐结果（服务端名），否则内核兜底。
  String _audioSheetLabel(
      int i, List<AlignedTrack> aligned, FacadeAudioTrack t) {
    if (i < aligned.length) {
      final a = aligned[i];
      // 默认轨标注（用户能一眼看出服务端指定的是哪条）
      return a.isDefault ? '${a.label}  ✔ 默认' : a.label;
    }
    return _trackDisplay(t.title, t.language, t.id,
        codec: t.codec, channels: t.channels);
  }

  /// 字幕弹层里第 [i] 行的显示名。
  ///
  /// [idx] 是"去掉首位『关闭字幕』"后的下标 —— 调用方负责传。
  String _subtitleSheetLabel(
      int idx, List<AlignedTrack> aligned, FacadeSubtitleTrack t) {
    if (idx < aligned.length) {
      final a = aligned[idx];
      return a.isDefault ? '${a.label}  ✔ 默认' : a.label;
    }
    return _trackDisplay(t.title, t.language, t.id,
        external: t.isExternal, forced: t.isForced);
  }

  void _showSubtitleSheet() {
    final tracks = _pstate.tracks.subtitle;
    final current = _pstate.track.subtitle;
    final aligned = _alignedSubtitle();
    _showSheet(
      title: '字幕（${tracks.length} 条）',
      children: [
        _sheetRow(
          label: '关闭字幕',
          selected: current.id == 'no',
          onTap: () {
            _player.setSubtitleTrack(FacadeSubtitleTrack.no);
            Navigator.pop(context);
          },
        ),
        // ★ 用户要求：多字幕时显示名称（中字 / 双语 / 繁体）。
        //   现在**优先用服务端的 `DisplayTitle`**（实测形如
        //   `Chinese Simplified (PGSSUB)` / `Chinese Traditional (PGSSUB)`），
        //   内核信息仅作兜底。对齐靠 `ff-index`（见 TrackAligner）。
        for (var i = 0; i < tracks.length; i++)
          _sheetRow(
            label: _subtitleSheetLabel(i, aligned, tracks[i]),
            selected: current.id == tracks[i].id,
            onTap: () {
              _player.setSubtitleTrack(tracks[i]);
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
              fontSize: 13,
              color: selected ? Cf.accent : Cf.text,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      subtitle: sub != null
          ? Text(sub,
              style: TextStyle(fontSize: 10, color: Cf.text3))
          : null,
      trailing: selected
          ? Icon(Icons.check_rounded, size: 20, color: Cf.accent)
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
