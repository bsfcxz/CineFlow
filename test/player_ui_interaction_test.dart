/// 播放器 UI 交互测试 —— **逐条对应规格 §18 的检查清单**。
///
/// ## 为什么用 widget 测试覆盖清单
/// §18 列了 19 条交互，全是"点了/划了会发生什么"。源码断言只能证明
/// "代码里写了"，证明不了"点了真的会"。widget 测试能真的点击/滑动并断言结果。
///
/// ## 离线运行
/// `PlayerUiPage` 只依赖 Riverpod 的 9 个 Controller（纯状态机），
/// **不依赖引擎** —— 视频层与弹幕层都是调用方注入的 `Widget`。
/// 所以这些测试不需要设备、不需要服务器、毫秒级。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/keys.dart';
import 'package:cineflow/player/application/controllers/playlist_controller.dart';
import 'package:cineflow/player/application/providers/player_providers.dart';
import 'package:cineflow/player/domain/models/media_state.dart';
import 'package:cineflow/player/domain/models/panel_state.dart';
import 'package:cineflow/player/domain/player_constants.dart';
import 'package:cineflow/player/presentation/player_ui_page.dart';

/// 组装一个测试用播放页，并记录所有回调调用。
class _Harness {
  final List<String> calls = [];
  late PlayerPageCallbacks callbacks;
  late PlayerPageSlots slots;

  _Harness() {
    callbacks = PlayerPageCallbacks(
      onTogglePlay: () => calls.add('togglePlay'),
      onSeekBy: (d) => calls.add('seekBy:${d.inSeconds}'),
      onSeekTo: (d) => calls.add('seekTo:${d.inSeconds}'),
      onSpeedChanged: (v) => calls.add('speed:$v'),
      onVolumeChanged: (v) => calls.add('volume:$v'),
      onBrightnessChanged: (v) => calls.add('brightness:$v'),
      onAspectModeChanged: (m) => calls.add('aspect:${m.name}'),
      onFullscreenToggled: () => calls.add('fullscreen'),
      onBack: () => calls.add('back'),
      onSelectMedia: (i) => calls.add('selectMedia:$i'),
      onPrevious: () {},
      onNext: () {},
      onSelectAudioTrack: (id) => calls.add('audio:$id'),
      onSelectSubtitleTrack: (id) => calls.add('subtitle:$id'),
      onImportSubtitle: () => calls.add('importSubtitle'),
      onImportDanmaku: () => calls.add('importDanmaku'),
      onMatchDanmaku: () => calls.add('matchDanmaku'),
      onVideoFilterChanged: ({brightness, contrast, saturation, hue}) =>
          calls.add('filter'),
      onResetFilters: () => calls.add('resetFilters'),
      onAudioDelayChanged: (d) => calls.add('audioDelay:${d.inMilliseconds}'),
      onSubtitleDelayChanged: (d) =>
          calls.add('subtitleDelay:${d.inMilliseconds}'),
      onSubtitleFontSizeChanged: (s) => calls.add('subFont:${s.name}'),
      onSubtitleEncodingChanged: (e) => calls.add('subEnc:${e.name}'),
    );
    slots = const PlayerPageSlots(
      title: 'Interstellar.2014.2160p.HDR.mkv',
      video: ColoredBox(color: Colors.black),
      subtitle: '测试副标题',
    );
  }
}

/// 渲染播放页；返回 harness 与 container。
Future<(ProviderContainer, _Harness)> pumpPlayer(
  WidgetTester tester, {
  Size size = const Size(400, 800),
}) async {
  final h = _Harness();
  final c = ProviderContainer();
  addTearDown(c.dispose);

  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: PlayerUiPage(slots: h.slots, callbacks: h.callbacks),
      ),
    ),
  );
  // 首帧后 _wire() 跑（Controller 互接）+ 控制层显隐计时
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (c, h);
}

void main() {
  group('§18 清单 1：中央三键（播放/暂停 + 快进快退）', () {
    testWidgets('点播放/暂停 → 回调 togglePlay', (tester) async {
      final (_, h) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.togglePlayButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.calls, contains('togglePlay'));
    });

    testWidgets('点快进 → seekBy(+10s)', (tester) async {
      final (_, h) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.seekForwardButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.calls, contains('seekBy:10'));
    });

    testWidgets('点快退 → seekBy(-10s)', (tester) async {
      final (_, h) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.seekBackButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.calls, contains('seekBy:-10'));
    });

    testWidgets('播放中图标为暂停，暂停时为播放', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      c.read(playbackStateProvider.notifier).play();
      await tester.pump();
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });
  });

  group('§18 清单 6：倍速按钮循环 1.0→1.5→2.0→2.5→3.0→1.0', () {
    testWidgets('连点 5 次回到 1.0x', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      expect(find.text('1.0x'), findsOneWidget);

      for (final want in ['1.5x', '2.0x', '2.5x', '3.0x', '1.0x']) {
        await tester.tap(find.byKey(keys.player.speedButton));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text(want), findsOneWidget,
            reason: '倍速循环应到 $want');
      }
      expect(c.read(playbackStateProvider).userSpeed, 1.0);
    });
  });

  group('§18 清单 7：齿轮打开设置面板，4 个 Tab 互斥', () {
    testWidgets('点齿轮 → 设置面板出现', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.settingsButton));
      await tester.pump(const Duration(milliseconds: 400));

      expect(c.read(panelStateProvider).open, PanelType.settings);
      expect(find.byKey(keys.player.settingsPanel), findsOneWidget);
      // 四个 Tab 都在
      for (final t in SettingsTab.values) {
        expect(find.text(t.label), findsWidgets, reason: '缺 Tab: ${t.label}');
      }
    });

    testWidgets('★ 面板互斥（走控制器，因为 UI 层被模态抽屉遮挡）', (tester) async {
      final (c, _) = await pumpPlayer(tester);

      await tester.tap(find.byKey(keys.player.settingsButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.settings);

      // ⚠️ 不能"打开设置后直接点底栏的列表按钮" —— 抽屉（min(屏宽×0.9,400)）
      //    会盖住底栏，点击落在抽屉上而不是按钮。这是模态抽屉的**正确行为**
      //    （见 test/player_panel_modal_test.dart 的实测记录）。
      //    互斥本身由 `PanelState.open` 这个单一枚举字段结构保证，
      //    故在控制器层验证。
      c.read(panelStateProvider.notifier).open(PanelType.playlist);
      // ⚠️ 要 pump **两次**：第一次只是把新的目标值交给 AnimatedSlide
      //    并启动动画（此时位置还是旧的），第二次才真正推进动画到终点。
      //    实测：只 pump 一次会读到 left=40（旧位置），误判成"没滑出去"。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(c.read(panelStateProvider).open, PanelType.playlist,
          reason: '同时只能有一个面板（单一枚举字段 → 结构上互斥）');

      // ⚠️ 设置面板的 widget **仍在树里**（抽屉滑出屏幕，未销毁），
      //    所以"断言它不存在"是错的。可见性判据是**它被移出了可视区**。
      final settingsRect =
          tester.getRect(find.byKey(keys.player.settingsPanel));
      final screenW =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(
        settingsRect.left,
        greaterThanOrEqualTo(screenW - 1),
        reason: '设置面板应被完全移出屏幕右侧'
            '（left=${settingsRect.left}, 屏宽=$screenW）',
      );
      // 播放列表抽屉应在屏幕内
      final listRect = tester.getRect(find.byKey(keys.player.playlistPanel));
      expect(listRect.left, lessThan(1.0),
          reason: '播放列表应从左侧贴边显示（left=${listRect.left}）');
    });

    testWidgets('点遮罩 → 关闭所有面板', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.settingsButton));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tapAt(const Offset(30, 400)); // 遮罩区域（抽屉之外）
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.none);
    });

    testWidgets('点面板内的关闭按钮 → 关闭', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.settingsButton));
      await tester.pump(const Duration(milliseconds: 400));

      // ⚠️ 必须限定到**可见的那个面板**：三个抽屉同时在树里，
      //    `find.byKey(panelClose).first` 取到的是屏幕外那个（点击无效）。
      await tester.tap(find.descendant(
        of: find.byKey(keys.player.settingsPanel),
        matching: find.byKey(keys.player.panelClose),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).open, PanelType.none);
    });

    testWidgets('Tab 切换', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.settingsButton));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('信息').last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(panelStateProvider).settingsTab, SettingsTab.info);
      // 信息 Tab 的内容（文件名）
      expect(find.text('文件名'), findsOneWidget);
    });
  });

  group('§18 清单 14/15/19：锁按钮与锁定语义', () {
    testWidgets('锁按钮始终可见（含锁定时）', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      expect(find.byKey(keys.player.lockButton), findsOneWidget);

      c.read(uiVisibilityProvider.notifier).toggleLock();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(keys.player.lockButton), findsOneWidget,
          reason: '锁定后锁按钮必须还在 —— 否则用户无法解锁');
    });

    testWidgets('★ 锁定后控制层消失', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      expect(find.byKey(keys.player.controls), findsOneWidget);

      c.read(uiVisibilityProvider.notifier).toggleLock();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(keys.player.controls), findsNothing,
          reason: '锁定后 UI 强制隐藏（规格 §8.4）');
    });

    testWidgets('★ 锁定后点画面不切换 UI 显隐', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(uiVisibilityProvider.notifier).toggleLock();
      await tester.pump(const Duration(milliseconds: 100));
      final before = c.read(uiVisibilityProvider).visible;

      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.read(uiVisibilityProvider).visible, before,
          reason: '锁定时单击不该有任何反应');
    });

    testWidgets('点锁按钮能解锁', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(uiVisibilityProvider.notifier).toggleLock();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(keys.player.lockButton));
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.read(uiVisibilityProvider).isLocked, isFalse);
      expect(find.byKey(keys.player.controls), findsOneWidget);
    });
  });

  group('§18 清单 12：弹幕面板', () {
    testWidgets('底栏「弹」→ 切换弹幕开关', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      expect(c.read(danmakuPanelProvider).enabled, isTrue);

      await tester.tap(find.byKey(keys.player.danmakuButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(danmakuPanelProvider).enabled, isFalse);
    });

    testWidgets('弹幕设置入口 → 打开弹幕面板', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.danmakuSettingsButton));
      await tester.pump(const Duration(milliseconds: 400));

      expect(c.read(panelStateProvider).open, PanelType.danmaku);
      expect(find.byKey(keys.player.danmakuPanel), findsOneWidget);
      // 面板内的控件齐全
      expect(find.text('弹幕开关'), findsOneWidget);
      expect(find.text('透明度'), findsOneWidget);
      expect(find.text('字体大小'), findsOneWidget);
      expect(find.text('弹幕速度'), findsOneWidget);
      expect(find.text('显示区域'), findsOneWidget);
      expect(find.text('在线匹配弹幕库'), findsOneWidget);
    });

    testWidgets('面板内 Switch 与底栏开关同步', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.danmakuSettingsButton));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(keys.player.danmakuSwitch));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(danmakuPanelProvider).enabled, isFalse);
    });
  });

  group('§18 清单 13：播放列表面板', () {
    testWidgets('列表为空时显示空态', (tester) async {
      final (_, _) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.playlistButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('没有待播放的媒体'), findsOneWidget);
    });

    testWidgets('★ 有队列时显示项、当前项高亮、点击切换', (tester) async {
      final (c, h) = await pumpPlayer(tester);
      c.read(playlistStateProvider.notifier).setEntries(const [
        PlaylistEntry(id: '1', title: '第一集'),
        PlaylistEntry(id: '2', title: '第二集'),
        PlaylistEntry(id: '3', title: '第三集'),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(keys.player.playlistButton));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('第一集'), findsOneWidget);
      expect(find.text('第三集'), findsOneWidget);
      expect(find.text('当前队列 · 3 项'), findsOneWidget);

      await tester.tap(find.text('第三集'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(playlistStateProvider).currentIndex, 2);
      expect(h.calls, contains('selectMedia:2'));
    });

    // ★ 用户反馈（2026-10-07）：剧集/综艺的播放列表**没有显示集数**。
    //    修法对齐旧页选集抽屉（`player_page.dart:2563-2573`）的口径：
    //    `第 N 集` + 剧名 + 进度。
    testWidgets('★ 剧集列表显示集数徽章（用户反馈回归）', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(playlistStateProvider.notifier).setEntries(const [
        PlaylistEntry(id: '1', title: '初入棋局', episodeLabel: '第 1 集'),
        PlaylistEntry(id: '2', title: '宿敌相逢', episodeLabel: '第 2 集'),
        PlaylistEntry(
          id: '3',
          title: '棋逢对手',
          episodeLabel: '第 3 集',
          progressLabel: '看到 37%',
        ),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(keys.player.playlistButton));
      await tester.pump(const Duration(milliseconds: 400));

      // 集数徽章必须存在 —— 这正是用户说"没有"的东西
      expect(find.text('第 1 集'), findsOneWidget,
          reason: '播放列表应显示集数（用户反馈它缺失）。\n'
              '若这条红 → 集数又没被填进 PlaylistEntry。');
      expect(find.text('第 2 集'), findsOneWidget);
      expect(find.text('第 3 集'), findsOneWidget);

      // 集数与剧名**同时**可见（旧页选集是"第 N 集 + 剧名"）
      expect(find.text('初入棋局'), findsOneWidget);
      expect(find.text('棋逢对手'), findsOneWidget);

      // 观看进度
      expect(find.text('看到 37%'), findsOneWidget,
          reason: '对齐旧页选集的 sub：让用户看出"哪几集看过、看到哪"');
    });

    testWidgets('★ 电影（无集数）不显示空徽章', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(playlistStateProvider.notifier).setEntries(const [
        PlaylistEntry(id: 'a', title: '电影甲', subtitle: '24.6 GB · MKV'),
        PlaylistEntry(id: 'b', title: '电影乙', subtitle: '12.4 GB · MKV'),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(keys.player.playlistButton));
      await tester.pump(const Duration(milliseconds: 400));

      // 电影没有集号 → episodeLabel 为 null → 不应出现任何"第 N 集"
      expect(find.textContaining('第 '), findsNothing,
          reason: '电影不该出现"第 N 集"徽章（也不能出现"第 null 集"）');
      // 但副标题要照常显示
      expect(find.text('24.6 GB · MKV'), findsOneWidget);
    });

    testWidgets('★ 进度优先于副标题（信息密度取舍）', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(playlistStateProvider.notifier).setEntries(const [
        PlaylistEntry(
          id: '1',
          title: '已看过的',
          episodeLabel: '第 1 集',
          subtitle: '副标题不该出现的',
          progressLabel: '已看',
        ),
      ]);
      await tester.pump();

      await tester.tap(find.byKey(keys.player.playlistButton));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('已看'), findsOneWidget);
      expect(find.text('副标题不该出现的'), findsNothing,
          reason: '第二行只显示一条：进度优先于副标题。\n'
              '若两者都显示 → 行高会变，列表可读性下降。');
    });
  });

  group('§18 清单 8/9/10：设置面板的四个 Tab 内容', () {
    testWidgets('视频 Tab：比例 / 解码 / 四个画面参数', (tester) async {
      final (_, _) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.settingsButton));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('画面比例'), findsOneWidget);
      expect(find.text('解码方式'), findsOneWidget);
      expect(find.text('亮度'), findsOneWidget);
      expect(find.text('对比度'), findsOneWidget);
      expect(find.text('饱和度'), findsOneWidget);
      expect(find.text('色相'), findsOneWidget);
      // 比例五档
      for (final m in ['适应', '拉伸', '裁剪', '16:9', '4:3']) {
        expect(find.text(m), findsOneWidget, reason: '缺比例档: $m');
      }
    });

    testWidgets('★ 点比例档 → 回调收到对应模式', (tester) async {
      final (c, h) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.settingsButton));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('16:9'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.read(videoStateProvider).aspectMode, AspectMode.ratio16x9);
      expect(h.calls, contains('aspect:ratio16x9'));
    });

    testWidgets('音频 Tab：音轨列表 / 延迟 / 音量', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(audioStateProvider.notifier).setTracks(const [
        AudioTrack(id: 'a1', name: '国语', codec: 'aac', channels: 2),
        AudioTrack(id: 'a2', name: '导演评论音轨', codec: 'eac3', channels: 6),
      ]);
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      c.read(panelStateProvider.notifier).switchSettingsTab(SettingsTab.audio);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('国语'), findsOneWidget);
      expect(find.text('导演评论音轨'), findsOneWidget);
      expect(find.text('音频延迟'), findsWidgets);
      expect(find.text('音量'), findsWidgets);
    });

    testWidgets('字幕 Tab：轨道 / 外挂 / 延迟 / 字号 / 编码', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(subtitleStateProvider.notifier).setTracks(const [
        SubtitleTrack(id: 's1', name: '简体中文', format: 'srt', isExternal: true),
      ]);
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      c.read(panelStateProvider.notifier)
          .switchSettingsTab(SettingsTab.subtitle);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('关闭字幕'), findsOneWidget);
      expect(find.text('简体中文'), findsOneWidget);
      expect(find.text('导入本地字幕文件'), findsOneWidget);
      expect(find.text('字幕延迟'), findsOneWidget);
      expect(find.text('字幕字号'), findsOneWidget);
      expect(find.text('字幕编码'), findsOneWidget);
      // 四档字号 + 四种编码
      for (final x in ['小', '中', '大', '超大']) {
        expect(find.text(x), findsWidgets, reason: '缺字号档: $x');
      }
      for (final x in ['自动', 'UTF-8', 'GBK', 'BIG5']) {
        expect(find.text(x), findsOneWidget, reason: '缺编码: $x');
      }
    });

    testWidgets('信息 Tab：文件 / 视频 / 音频 / 封装', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(mediaInfoProvider.notifier).set(const MediaInfo(
            fileName: 'Interstellar.mkv',
            sizeBytes: 26400000000,
            duration: Duration(minutes: 169),
            width: 3840,
            height: 2160,
            videoCodec: 'HEVC',
            audioCodec: 'DTS-HD MA',
            container: 'Matroska',
          ));
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      c.read(panelStateProvider.notifier).switchSettingsTab(SettingsTab.info);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('文件'), findsWidgets);
      expect(find.text('视频'), findsWidgets);
      expect(find.text('音频'), findsWidgets);
      expect(find.text('封装'), findsWidgets);
      expect(find.text('Interstellar.mkv'), findsOneWidget);
      expect(find.text('3840 × 2160'), findsOneWidget);
      expect(find.text('HEVC'), findsOneWidget);
    });

    testWidgets('信息 Tab 缺失字段显示「—」而不是编造', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      c.read(panelStateProvider.notifier).switchSettingsTab(SettingsTab.info);
      await tester.pump(const Duration(milliseconds: 400));
      // 默认 MediaInfo 全空 → 应出现多个「—」
      expect(find.text('—'), findsWidgets);
    });
  });

  group('§18 清单 18：暂停时 UI 不自动隐藏', () {
    testWidgets('暂停超过 3 秒仍可见', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      // isPlaying = false（默认）
      await tester.pump(const Duration(seconds: 5));
      expect(c.read(uiVisibilityProvider).controlsVisible, isTrue,
          reason: '暂停时不该自动隐藏');
      expect(find.byKey(keys.player.controls), findsOneWidget);
    });
  });

  group('§18 清单 17：面板打开时 UI 不自动隐藏', () {
    testWidgets('面板开着超过 3 秒控制层仍在', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      c.read(playbackStateProvider.notifier).play();
      c.read(panelStateProvider.notifier).open(PanelType.settings);
      await tester.pump(const Duration(seconds: 5));
      expect(c.read(uiVisibilityProvider).controlsVisible, isTrue,
          reason: '面板打开时控制层不该隐藏（否则找不到关闭入口）');
    });
  });

  group('§18 清单 16：全屏按钮', () {
    testWidgets('点全屏 → 回调触发', (tester) async {
      final (_, h) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.fullscreenButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.calls, contains('fullscreen'));
    });

    testWidgets('全屏状态切换图标', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      c.read(uiVisibilityProvider.notifier).setFullscreen(true);
      await tester.pump();
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    });
  });

  group('§18 清单 1：单击显隐 / 双击播放（手势判定）', () {
    testWidgets('点空白 250ms 后 → 隐藏控制层', (tester) async {
      final (c, _) = await pumpPlayer(tester);
      expect(c.read(uiVisibilityProvider).controlsVisible, isTrue);

      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 500)); // 等过 250ms 判定窗
      expect(c.read(uiVisibilityProvider).controlsVisible, isFalse,
          reason: '单击应切换 UI 显隐');
    });
  });

  group('顶栏（§18 清单相关）', () {
    testWidgets('显示文件名；长文件名不溢出', (tester) async {
      final (_, _) = await pumpPlayer(tester, size: const Size(360, 780));
      expect(find.text('Interstellar.2014.2160p.HDR.mkv'), findsOneWidget);
    });

    testWidgets('点返回 → 回调', (tester) async {
      final (_, h) = await pumpPlayer(tester);
      await tester.tap(find.byKey(keys.player.backButton));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.calls, contains('back'));
    });
  });
}
