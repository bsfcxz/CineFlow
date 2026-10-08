/// **播放器调试试验台**（仅 debug 构建，登录页左下角入口）。
///
/// ## 存在的理由
/// 播放器的全功能自测（手势/面板/弹幕/滤镜/画幅/锁）此前只能靠
/// 登录 Emby 后挑片源 —— 自动化验证进不去，人肉验证跑不全。
/// 本页**不经过任何服务器**：用真内核（mpv）播设备私有目录里的
/// 本地测试视频 + 合成演示弹幕，把新播放 UI 的每一个功能在真机上
/// 逐项驱动、逐项截屏验证。
///
/// ## 测试视频
/// `/data/data/com.cineflow.app/files/cf_test.mp4`（约 4s 的录屏），
/// 由宿主机推入：
/// ```
/// adb push cf_test.mp4 /data/local/tmp/
/// adb shell run-as com.cineflow.app cp /data/local/tmp/cf_test.mp4 files/
/// ```
/// 视频播完自动循环（completedStream → seek 0 + play），供持续测试。
///
/// ## 与 PlayerFlowPage 的关系
/// 复用同一批公共件：AspectVideo（画幅五档）/ danmakuUiProvider（弹幕
/// 数据）/ 各 Controller providers / volumeToKernel 换算。差异只在
/// 没有 Emby 上报与转码韧性（那是流程层的事，试验台只验 UI×内核）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, SystemUiMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../core/theme.dart';
import '../danmaku/danmaku_config.dart';
import '../danmaku/danmaku_models.dart';
import '../danmaku/danmaku_overlay.dart';
import '../danmaku/danmaku_providers.dart';
import 'application/providers/player_providers.dart';
import 'domain/models/danmaku_panel_state.dart';
import 'kernel.dart';
import 'kernel_factory.dart';
import 'player_flow_page.dart' show danmakuUiProvider, volumeToKernel;
import 'presentation/player_ui_page.dart';
import 'presentation/widgets/aspect_video.dart';

/// 测试视频（宿主机经 run-as 推入应用私有目录）。
/// 测试片（由 `tool/make_test_media.ps1` 生成，adb 推入应用私有目录）。
///
/// ## 为什么必须是这一份（不是随便录屏）
/// 验证播放器可调项时，每一项都需要片源里**存在对应内容**：
///   · 画面滤镜 → 需要高饱和多色块（testsrc2 满足）
///   · 音频延迟 → 需要**音轨**且**有节拍脉冲**（本片：每秒一声 441Hz）
///   · 字幕延迟 → 需要**字幕轨**（本片：中文 + 英文各一条）
///   · 音轨切换 → 需要 **≥2 条可区分音轨**（本片：441Hz 脉冲 vs 880Hz 连续）
///
/// 旧的 `cf_test.mp4` 是 screenrecord 录屏 —— **无音轨无字幕**，
/// 上表后四项**全都验不了**（这不是播放器的问题，是片源缺内容）。
const _testVideo = '/data/data/com.cineflow.app/files/cf_probe.mp4';

class DebugPlayerTestbed extends ConsumerStatefulWidget {
  const DebugPlayerTestbed({super.key});

  @override
  ConsumerState<DebugPlayerTestbed> createState() => _DebugPlayerTestbedState();
}

class _DebugPlayerTestbedState extends ConsumerState<DebugPlayerTestbed> {
  PlayerKernel? _kernel;

  /// 当前内核类型 —— **可切换**，用于双内核对照验证。
  ///
  /// 为什么要能切：两个内核能力不同（Media3 不支持画面滤镜/音视频延迟）。
  /// 只有切过去看，才知道"UI 是否如实禁用了做不到的项"。
  KernelType _kernelType = KernelType.mpv;
  int? _textureId;
  final _subs = <StreamSubscription<dynamic>>[];
  bool _immersive = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    ref.read(playlistStateProvider.notifier).onSelect = null;
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final kernel = PlayerKernelFactory.create(_kernelType);
    await kernel.ensureTexture();
    if (!mounted) {
      unawaited(kernel.dispose());
      return;
    }
    _kernel = kernel;
    _textureId = kernel.textureId;

    _subs.add(kernel.stateStream.listen((s) {
      final p = ref.read(playbackStateProvider.notifier);
      p.setPlaying(s.playing);
      p.setPosition(s.position);
      p.setDuration(s.duration);
      p.setBuffer(s.buffer);
      p.setBuffering(s.buffering);
      p.syncSpeed(s.rate);
    }));
    _subs.add(kernel.errorStream.listen((e) {
      if (mounted) setState(() => _error = e);
    }));
    // ---- 循环播放（供人肉验证时反复观察）----
    //
    // ⚠️ 必须 **重新 open**，不能只 `seek(0)`。
    //
    // 实测（2026-10-07）：60 秒测试片播完后画面**永久停住**，logcat 是
    //   `end-file: eof` → `command[seek] -> error running command`
    // 原因：mpv 在 EOF 之后**已卸载该文件**，此时 seek 无效；
    // 只有重新 open 才会再播。
    //
    // 旧写法 `seek(0) + play()` 只在"未播完时跳回开头"有效 ——
    // 这是个**只在播到结尾才暴露**的 bug，短时间自动化测试测不到。
    // 对本地文件重新 open 的代价是重新解封装（毫秒级），可接受。
    _subs.add(kernel.completedStream.listen((_) async {
      try {
        await kernel.open(_testVideo, play: true);
      } catch (e) {
        if (mounted) setState(() => _error = '循环重播失败：$e');
      }
    }));

    // 合成演示弹幕：4s 视频每 400ms 一条，循环对齐时间轴
    ref.read(danmakuUiProvider.notifier).set(DanmakuLoadResult(items: _demoDanmaku));

    setState(() {});
    try {
      await kernel.open(_testVideo, play: true);
    } catch (e) {
      if (mounted) setState(() => _error = '打开测试视频失败：$e');
    }
  }

  List<Danmaku> get _demoDanmaku {
    const texts = [
      '这画质太顶了！', '前方高能', '试验台弹幕', '手势左亮右音',
      '双击暂停', '长按 3x 快进', '弹幕护体', '进度条可以拖',
      '齿轮里能调滤镜', '画幅五档可切',
    ];
    return [
      for (var i = 0; i < texts.length; i++)
        Danmaku(
          timeMs: i * 400,
          text: texts[i],
          mode: i % 5 == 4
              ? DanmakuMode.bottom
              : (i % 7 == 6 ? DanmakuMode.top : DanmakuMode.scroll),
        ),
    ];
  }

  void _exit() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    // 恢复系统 UI / 方向 / 亮度 —— 与 PlayerFlowPage.dispose 同理：
    // 不能只挂在 `_exit()`（onBack）上，系统返回手势不经过它。
    // `SystemChrome` 是静态 API，不依赖 ref，可在 dispose 里调。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    final k = _kernel;
    _kernel = null;
    if (k != null) {
      unawaited(Future<void>.delayed(const Duration(milliseconds: 300))
          .then((_) => k.dispose()));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tid = _textureId;
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$_error',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const Text(
                  '测试片缺失？宿主机执行：\n'
                  'powershell -File tool/make_test_media.ps1\n'
                  'adb push %TEMP%/cf_media/cf_probe.mp4 /data/local/tmp/\n'
                  'adb shell run-as com.cineflow.app cp '
                  '/data/local/tmp/cf_probe.mp4 files/',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_kernel == null || tid == null) {
      return const Scaffold(
          backgroundColor: Colors.black, body: ColoredBox(color: Colors.black));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PlayerUiPage(
            slots: PlayerPageSlots(
              title: '试验台 · ${_kernelType.label} · cf_probe.mp4',
              video: AspectVideo(
                textureId: tid,
                videoRatio: _kernel?.aspectRatio ?? 16 / 9,
              ),
              danmakuLayer: const _TestbedDanmakuLayer(),
            ),
            callbacks: _callbacks(),
          ),
          // ---- 内核切换浮层（左上角）----
          //
          // 为什么放浮层而不是独立页面：切内核要**保留正在验证的场景**，
          // 独立页面会丢掉播放位置与面板状态，双内核对照就不准了。
          Positioned(
            left: 8,
            top: 8,
            child: _KernelChip(
              type: _kernelType,
              kernel: _kernel,
              onSwitch: _switchKernel,
            ),
          ),
        ],
      ),
    );
  }

  /// 切换内核：换 `_kernelType` 并**重建播放页**（重新 boot）。
  ///
  /// ⚠️ 必须先 dispose 旧内核再重建 —— 两个内核同时持有原生播放器与
  ///    Flutter 纹理会互相踩（第二个 createTexture 拿到已被占用的 surface，
  ///    现象是"切过去黑屏"）。
  Future<void> _switchKernel() async {
    await _kernel?.dispose();
    final next =
        _kernelType == KernelType.mpv ? KernelType.media3 : KernelType.mpv;
    if (!mounted) return;
    setState(() {
      _kernelType = next;
      _kernel = null;
      _textureId = null;
      _error = null;
      for (final sub in _subs) {
        unawaited(sub.cancel());
      }
      _subs.clear();
    });
    await _boot();
  }

  PlayerPageCallbacks _callbacks() {
    Future<void> togglePlay() async {
      final k = _kernel;
      if (k == null) return;
      if (k.state.playing) {
        await k.pause();
      } else {
        await k.play();
      }
    }

    return PlayerPageCallbacks(
      onTogglePlay: togglePlay,
      onSeekBy: (d) async {
        final k = _kernel;
        if (k == null) return;
        await k.seek(k.state.position + d);
      },
      onSeekTo: (d) async => _kernel?.seek(d),
      onSpeedChanged: (v) => _kernel?.setRate(v),
      // 面板 0–1 → 内核 0–100（与 PlayerFlowPage 同一换算源）
      onVolumeChanged: (v) => _kernel?.setVolume(volumeToKernel(v)),
      onBrightnessChanged: (v) {
        ScreenBrightness()
            .setApplicationScreenBrightness(v.clamp(0.05, 1.0))
            .catchError((_) {});
      },
      onAspectModeChanged: (m) {
        ref.read(videoStateProvider.notifier).setAspectMode(m);
      },
      onFullscreenToggled: () {
        _immersive = !_immersive;
        SystemChrome.setEnabledSystemUIMode(
            _immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
      },
      onBack: _exit,
      onSelectMedia: (_) {},
      onPrevious: () {},
      onNext: () {},
      onSelectAudioTrack: (id) => _kernel?.setAudioTrack(id),
      onSelectSubtitleTrack: (id) => _kernel?.setSubtitleTrack(id ?? 'no'),
      onImportSubtitle: () =>
          _snack('导入字幕：待接 file_picker（CF-P4 任务卡）'),
      onImportDanmaku: () =>
          _snack('导入弹幕：待接 file_picker（CF-P4 任务卡）'),
      onMatchDanmaku: () => _snack('在线匹配弹幕：本地测试无网络匹配'),
      onVideoFilterChanged: ({brightness, contrast, saturation, hue}) {
        final k = _kernel;
        final c = ref.read(videoStateProvider.notifier);
        if (brightness != null) c.setBrightness(brightness);
        if (contrast != null) c.setContrast(contrast);
        if (saturation != null) c.setSaturation(saturation);
        if (hue != null) c.setHue(hue);
        if (k != null) {
          unawaited(k.setVideoFilters(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            hue: hue,
          ));
        }
      },
      onResetFilters: () {
        ref.read(videoStateProvider.notifier).resetFilters();
        unawaited(_kernel?.setVideoFilters(
            brightness: 0, contrast: 0, saturation: 0, hue: 0));
      },
      onAudioDelayChanged: (d) {
        ref.read(audioStateProvider.notifier).setDelay(d);
        unawaited(_kernel?.setAudioDelay(d));
      },
      onSubtitleDelayChanged: (d) {
        ref.read(subtitleStateProvider.notifier).setDelay(d);
        unawaited(_kernel?.setSubtitleDelay(d));
      },
      onSubtitleFontSizeChanged: (s) {
        ref.read(subtitleStateProvider.notifier).setFontSize(s);
      },
      onSubtitleEncodingChanged: (e) {
        ref.read(subtitleStateProvider.notifier).setEncoding(e);
      },
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }
}

/// 弹幕层（试验台版）：与 PlayerFlowPage._DanmakuLayer 同一套映射。
class _TestbedDanmakuLayer extends ConsumerWidget {
  const _TestbedDanmakuLayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(danmakuUiProvider);
    final panel = ref.watch(danmakuPanelProvider);
    final cfg = ref.watch(danmakuConfigProvider).value;
    final position = ref.watch(playbackStateProvider.select((s) => s.position));

    if (data.items.isEmpty) return const SizedBox.shrink();

    return DanmakuOverlay(
      items: data.items,
      position: position,
      enabled: panel.enabled,
      opacity: panel.opacity / 100,
      fontScale: (cfg?.fontScale ?? 1.0) * _fontScaleOf(panel.fontSize),
      blockedWords: cfg?.blockedWords ?? const [],
      showArea: cfg?.showArea ?? 1.0,
      modes: switch (panel.area) {
        DanmakuArea.scroll =>
          const DanmakuDisplayModes(scroll: true, top: false, bottom: false),
        DanmakuArea.top =>
          const DanmakuDisplayModes(scroll: false, top: true, bottom: false),
        DanmakuArea.bottom =>
          const DanmakuDisplayModes(scroll: false, top: false, bottom: true),
      },
      speed: panel.speedLevel / 5,
      bold: cfg?.bold ?? false,
      avoidSubtitle: cfg?.avoidSubtitle ?? true,
    );
  }

  double _fontScaleOf(DanmakuFontSize size) => switch (size) {
        DanmakuFontSize.small => 0.8,
        DanmakuFontSize.medium => 1.0,
        DanmakuFontSize.large => 1.3,
      };
}

/// 内核切换浮层：显示当前内核 + 能力表 + 切换按钮。
///
/// ## 为什么要显示"能力表"而不是只显示内核名
/// Media3 **不支持**画面滤镜与音视频延迟。切过去后设置面板里那些滑块
/// 会变灰/不生效 —— 若用户不知道"这是内核能力差异"，
/// 会误判成"滤镜坏了"。把能力显式列出来，避免这类误判。
class _KernelChip extends StatelessWidget {
  const _KernelChip({
    required this.type,
    required this.kernel,
    required this.onSwitch,
  });

  final KernelType type;
  final PlayerKernel? kernel;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final k = kernel;
    // 能力表：只列"本页能验证"的关键项，避免喧宾夺主
    final caps = <String, bool>{
      '滤镜': k?.supports(EngineFeature.videoFilters) ?? false,
      '音延迟': k?.supports(EngineFeature.audioDelay) ?? false,
      '字延迟': k?.supports(EngineFeature.subtitleDelay) ?? false,
    };
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xCC0D1328),
          borderRadius: BorderRadius.circular(Cf.radiusSm),
          border: Border.all(color: const Color(0x59FFFFFF), width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              type.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            for (final e in caps.entries) ...[
              Icon(
                e.value ? Icons.check_circle : Icons.remove_circle_outline,
                size: 12,
                color: e.value ? const Color(0xFF00E5A0) : Colors.white38,
              ),
              const SizedBox(width: 2),
              Text(
                e.key,
                style: TextStyle(
                  color: e.value ? Colors.white70 : Colors.white30,
                  fontSize: 10,
                ),
              ),
              const SizedBox(width: 6),
            ],
            const SizedBox(width: 2),
            InkWell(
              onTap: onSwitch,
              borderRadius: BorderRadius.circular(Cf.radiusSm),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  '切换',
                  style: TextStyle(
                    color: Color(0xFF4DA3FF),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
