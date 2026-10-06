/// 115 视频播放页。
///
/// ## ★ 本文件存在的唯一理由：把 headers 原样交给播放器
///
/// 115 的 CDN 直链与"取地址时所用的 UA"**强绑定**，且取地址响应可能回
/// `Set-Cookie`（CDN 一次性凭证）。这两样都**不在 URL 里**。
/// 只把 URL 交给播放器 → CDN 返回 403 → 现象是"地址取到了但播不了"。
///
///
/// 内核迁移后语义不变：`PlayerFacade.openUrl(url, headers:)` →
/// `PlayerChannel.open` 把 headers 拼成 `http-header-fields` 交给 mpv。
///
/// ## 为什么播放器不复用 Emby 的 player_page
///
/// Emby 播放器承载了大量 Emby 专属逻辑：进度上报（`Sessions/Playing*` +
/// `UserData`）、章节、多版本、转码判断、跳过片头。115 没有这些概念
/// （取证结论：webapi 路线**没有可用的播放进度接口**）。
/// 强行复用会让 Emby 播放器里塞满 `if (是115)` 分支，两边都更难维护。
///
/// 本页刻意**只做最小可用**：播放、暂停、进度、横屏。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../player/player_facade.dart';
import 'pan115_client.dart';
import 'pan115_store.dart';

/// 打开 115 播放页。
Future<void> openPan115Player(BuildContext context, Pan115File file) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Pan115PlayerPage(file: file),
      // 播放页自身处理横屏，故全屏推入
      fullscreenDialog: true,
    ),
  );
}

class Pan115PlayerPage extends ConsumerStatefulWidget {
  const Pan115PlayerPage({super.key, required this.file});

  final Pan115File file;

  @override
  ConsumerState<Pan115PlayerPage> createState() => _Pan115PlayerPageState();
}

class _Pan115PlayerPageState extends ConsumerState<Pan115PlayerPage> {
  /// 播放门面（原生 mpv）。异步创建：先建 Flutter 纹理，再 initialize mpv。
  PlayerFacade? _facade;
  PlayerFacade get _player => _facade!;
  bool get _ready => _facade != null;

  /// 视频尺寸变化计数（纹理要重建才能反映新宽高比）
  int _videoTick = 0;

  Pan115Playback? _playback;
  bool _resolving = true;
  String? _error;

  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _showControls = true;
  Timer? _hideTimer;

  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    // 播放期间保持屏幕常亮（原生播放器的基本预期；
    // Emby 侧缺 WakeLock 是已知缺陷，这里用 UI 层的手段先兜住）
    unawaited(SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));

    _armHide();
    unawaited(_boot());
  }

  /// 建内核 → 订阅流 → 取直链起播。
  Future<void> _boot() async {
    try {
      final p = await createPlayerFacade();
      if (!mounted) {
        unawaited(p.dispose());
        return;
      }
      _facade = p;
      _subs.addAll([
        p.stream.position.listen((v) {
          if (mounted) setState(() => _pos = v);
        }),
        p.stream.duration.listen((v) {
          if (mounted) setState(() => _dur = v);
        }),
        p.stream.playing.listen((v) {
          if (mounted) setState(() => _playing = v);
        }),
        p.stream.buffering.listen((v) {
          if (mounted) setState(() => _buffering = v);
        }),
        p.videoSizeStream.listen((_) {
          if (mounted) setState(() => _videoTick++);
        }),
        p.stream.error.listen((e) {
          // 播放失败时给出可行动提示（最常见原因是直链过期 → 重新取地址）
          if (mounted) setState(() => _error = _friendlyError(e));
        }),
      ]);
      await _resolveAndPlay();
    } catch (e) {
      if (mounted) {
        setState(() {
          _resolving = false;
          _error = '播放器初始化失败：$e';
        });
      }
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    // 恢复竖屏与系统 UI（否则退出后整个应用会一直是横屏无状态栏）
    unawaited(SystemChrome.setPreferredOrientations(
        [DeviceOrientation.portraitUp]));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    // ⚠️ 同步拆原生播放器会崩（AGENTS.md §6.2 实测 SIGSEGV）。
    // 这里延后销毁：等本次 build/路由销毁帧走完再释放 mpv 与纹理。
    final p = _facade;
    if (p != null) {
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        unawaited(p.dispose());
      });
    }
    super.dispose();
  }

  /// 把底层错误转成用户能理解、能行动的中文。
  ///
  /// 115 的直链会过期，此时正确动作是**重新取地址**而不是让用户看着
  /// 一堆 mpv 日志发呆。故错误提示里带上"重试"的语义。
  String _friendlyError(String raw) {
    final low = raw.toLowerCase();
    if (low.contains('403') || low.contains('forbidden')) {
      return 'CDN 拒绝访问（403）。可能是直链已过期或触发了限流——\n'
          '点「重试」重新获取直链；若持续失败请稍后再试（避免频繁重试）。';
    }
    if (low.contains('401') || low.contains('410') || low.contains('404')) {
      return '直链已失效（$raw）。点「重试」会重新获取播放地址。';
    }
    if (low.contains('timeout') || low.contains('timed out')) {
      return '连接超时。请检查网络后重试。';
    }
    return '播放失败：$raw';
  }

  Future<void> _resolveAndPlay() async {
    setState(() {
      _resolving = true;
      _error = null;
    });

    final client = ref.read(pan115ClientProvider);
    // 重试前先让本地缓存的直链失效：否则会拿到同一条已失效的地址
    if (_playback != null && _playback!.pickCode.isNotEmpty) {
      await client.invalidateLink(_playback!.pickCode);
    }

    final pb = await client.resolvePlayback(
      pickCode: widget.file.pickCode,
      itemId: widget.file.id,
    );
    if (!mounted) return;

    if (pb == null) {
      setState(() {
        _resolving = false;
        _error = '无法获取播放地址。\n可能原因：未登录、文件受限（违规/需会员）、'
            '或接口被风控拦截。';
      });
      return;
    }

    setState(() {
      _resolving = false;
      _playback = pb;
    });

    // ★ 关键：把 headers 一起交给播放器。
    // 漏掉它们 → CDN 403（UA 绑定 + download_token）。
    await _player.openUrl(pb.url, play: true, headers: pb.headers);
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _armHide();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PopScope(
        canPop: true,
        child: Stack(fit: StackFit.expand, children: [
          // 视频层（原生 mpv 的 Flutter 纹理）
          if (_error == null && !_resolving && _ready)
            _player.videoView(fit: BoxFit.contain, tick: _videoTick),

          if (_resolving)
            Center(child: CircularProgressIndicator(color: Cf.accent)),

          if (_error != null) _errorView(),

          // 手势层（只在有画面时拦截点击）
          if (_error == null && !_resolving)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
              ),
            ),

          if (_buffering && _error == null && !_resolving)
            Center(
                child: CircularProgressIndicator(color: Colors.white70)),

          // 控制层
          if (_showControls && _error == null && !_resolving) _controls(),
        ]),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline_rounded, size: 40, color: Cf.danger),
            SizedBox(height: 14),
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.6)),
            SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('返回'),
              ),
              SizedBox(width: 12),
              FilledButton(
                onPressed: _resolveAndPlay,
                style: FilledButton.styleFrom(backgroundColor: Cf.accent),
                child: Text('重试'),
              ),
            ]),
          ]),
        ),
      );

  Widget _controls() => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Color(0x00000000), Color(0xCC000000)],
            stops: [0, 0.5, 1],
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.arrow_back_rounded, color: Colors.white),
              ),
              Expanded(
                child: Text(widget.file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: Colors.white)),
              ),
              if (_playback != null && _playback!.fileSize > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(_sizeLabel(_playback!.fileSize),
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                ),
            ]),
            const Spacer(),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                iconSize: 40,
                onPressed: () {
                  _player.playOrPause();
                  _armHide();
                },
                icon: Icon(
                  _playing
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: Colors.white,
                ),
              ),
            ]),
            Row(children: [
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(_fmt(_pos),
                    style: TextStyle(fontSize: 11, color: Colors.white70)),
              ),
              Expanded(
                child: Slider(
                  value: _sliderValue,
                  activeColor: Cf.accent,
                  inactiveColor: Colors.white24,
                  onChanged: (v) {
                    // 拖动时先暂停自动隐藏，避免手指还在拖控制层就消失
                    _hideTimer?.cancel();
                    setState(() => _pos = Duration(
                        milliseconds: (v * _dur.inMilliseconds).round()));
                  },
                  onChangeEnd: (v) {
                    _player.seek(Duration(
                        milliseconds: (v * _dur.inMilliseconds).round()));
                    _armHide();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(_fmt(_dur),
                    style: TextStyle(fontSize: 11, color: Colors.white70)),
              ),
            ]),
          ]),
        ),
      );

  double get _sliderValue {
    if (_dur.inMilliseconds <= 0) return 0;
    final v = _pos.inMilliseconds / _dur.inMilliseconds;
    return v.clamp(0.0, 1.0);
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static String _sizeLabel(int b) {
    if (b >= 1073741824) return '${(b / 1073741824).toStringAsFixed(1)} GB';
    if (b >= 1048576) return '${(b / 1048576).round()} MB';
    return '${(b / 1024).round()} KB';
  }
}
