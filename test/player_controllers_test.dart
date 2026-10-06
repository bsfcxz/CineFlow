/// Controller 行为测试 —— 交互规格中"有状态"的那部分。
///
/// ## 为什么用 ProviderContainer 而不是 widget 测试
/// 这些规则（自动隐藏的三条守卫、面板互斥、延迟钳制）都是**状态机行为**。
/// 用 widget 测试要渲染整棵播放器树、还要模拟定时器；
/// 用 `ProviderContainer` 直接驱动 Controller 则毫秒级且精确。
///
/// ## 覆盖的交互清单项
///   · 面板互斥（第 7 条）
///   · 面板打开时 UI 不自动隐藏（第 17 条）
///   · 暂停时 UI 不自动隐藏（第 18 条）
///   · 锁定时 UI 强制隐藏（第 19 条）
///   · 字幕/音频延迟边界（第 10/11 条）
///   · 倍速循环（第 6 条）
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/application/controllers/playlist_controller.dart';
import 'package:cineflow/player/application/providers/player_providers.dart';
import 'package:cineflow/player/domain/models/danmaku_panel_state.dart';
import 'package:cineflow/player/domain/models/media_state.dart';
import 'package:cineflow/player/domain/models/panel_state.dart';

ProviderContainer makeContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('PlaybackController', () {
    test('togglePlay 翻转 isPlaying', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      expect(c.read(playbackStateProvider).isPlaying, isFalse);
      n.togglePlay();
      expect(c.read(playbackStateProvider).isPlaying, isTrue);
      n.togglePlay();
      expect(c.read(playbackStateProvider).isPlaying, isFalse);
    });

    test('seekBy(±10s) 相对当前位置', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      n.setDuration(const Duration(hours: 1));
      n.seekTo(const Duration(minutes: 30));
      n.seekBy(const Duration(seconds: 10));
      expect(c.read(playbackStateProvider).position,
          const Duration(minutes: 30, seconds: 10));
      n.seekBy(const Duration(seconds: -10));
      expect(c.read(playbackStateProvider).position,
          const Duration(minutes: 30));
    });

    test('★ seekTo 越界自动钳制（负 → 0，超长 → duration）', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      n.setDuration(const Duration(minutes: 10));
      n.seekTo(const Duration(seconds: -5));
      expect(c.read(playbackStateProvider).position, Duration.zero);
      n.seekTo(const Duration(hours: 5));
      expect(c.read(playbackStateProvider).position,
          const Duration(minutes: 10),
          reason: '越界不钳制会让进度条回弹/百分比异常');
    });

    test('cycleSpeed 走完整循环回到 1.0', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      expect(c.read(playbackStateProvider).userSpeed, 1.0);
      for (final want in [1.5, 2.0, 2.5, 3.0, 1.0]) {
        n.cycleSpeed();
        expect(c.read(playbackStateProvider).userSpeed, want);
      }
    });

    test('★ 长按只在播放中生效（暂停时长按无意义）', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      n.startLongPress(); // 未播放
      expect(c.read(playbackStateProvider).isLongPressing, isFalse);
      expect(c.read(playbackStateProvider).effectiveSpeed, 1.0);

      n.play();
      n.startLongPress();
      expect(c.read(playbackStateProvider).effectiveSpeed, 3.0);
    });

    test('★ 长按结束恢复用户倍速', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      n.setUserSpeed(2.5);
      n.play();
      n.startLongPress();
      expect(c.read(playbackStateProvider).effectiveSpeed, 3.0);
      n.endLongPress();
      expect(c.read(playbackStateProvider).effectiveSpeed, 2.5);
    });

    test('★ 换集保留用户倍速（不该莫名回到 1.0x）', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      n.setUserSpeed(2.0);
      n.setPosition(const Duration(minutes: 5));
      n.setDuration(const Duration(hours: 1));
      n.resetForNewMedia();
      final s = c.read(playbackStateProvider);
      expect(s.userSpeed, 2.0, reason: '倍速是用户偏好，换一集不该被重置');
      expect(s.position, Duration.zero);
      expect(s.duration, Duration.zero);
    });

    test('错误可被清空（copyWith 哨兵）', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      n.setError('boom');
      expect(c.read(playbackStateProvider).errorMessage, 'boom');
      n.setError(null);
      expect(c.read(playbackStateProvider).errorMessage, isNull);
    });

    test('select 派生 provider 只反映对应字段', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      expect(c.read(isPlayingProvider), isFalse);
      n.play();
      expect(c.read(isPlayingProvider), isTrue);
      expect(c.read(speedLabelProvider), '1.0x');
      n.cycleSpeed();
      expect(c.read(speedLabelProvider), '1.5x');
    });

    test('progress 派生 provider', () {
      final c = makeContainer();
      final n = c.read(playbackStateProvider.notifier);
      n.setDuration(const Duration(minutes: 100));
      n.seekTo(const Duration(minutes: 25));
      expect(c.read(progressProvider), closeTo(0.25, 0.001));
    });
  });

  group('PanelController · 互斥（交互清单第 7 条）', () {
    test('打开一个面板', () {
      final c = makeContainer();
      final n = c.read(panelStateProvider.notifier);
      n.open(PanelType.settings);
      expect(c.read(panelStateProvider).open, PanelType.settings);
      expect(n.hasOpen, isTrue);
    });

    test('★ 打开第二个面板会替换第一个（结构上不可能同时开两个）', () {
      final c = makeContainer();
      final n = c.read(panelStateProvider.notifier);
      n.open(PanelType.settings);
      n.open(PanelType.danmaku);
      expect(c.read(panelStateProvider).open, PanelType.danmaku,
          reason: '状态是单一枚举字段 → 结构上互斥');
      n.open(PanelType.playlist);
      expect(c.read(panelStateProvider).open, PanelType.playlist);
    });

    test('再次点同一个面板 = 收起', () {
      final c = makeContainer();
      final n = c.read(panelStateProvider.notifier);
      n.open(PanelType.settings);
      n.open(PanelType.settings);
      expect(c.read(panelStateProvider).open, PanelType.none);
    });

    test('closeAll 关闭', () {
      final c = makeContainer();
      final n = c.read(panelStateProvider.notifier);
      n.open(PanelType.playlist);
      n.closeAll();
      expect(c.read(panelStateProvider).open, PanelType.none);
      expect(n.hasOpen, isFalse);
    });

    test('Tab 切换不影响面板开关', () {
      final c = makeContainer();
      final n = c.read(panelStateProvider.notifier);
      n.open(PanelType.settings);
      n.switchSettingsTab(SettingsTab.info);
      final s = c.read(panelStateProvider);
      expect(s.settingsTab, SettingsTab.info);
      expect(s.open, PanelType.settings, reason: '切 Tab 不该关掉面板');
    });

    test('四个 Tab 与规格一致', () {
      expect(SettingsTab.values.map((e) => e.label).toList(),
          ['视频', '音频', '字幕', '信息']);
    });

    test('面板标题与左右侧归属', () {
      expect(PanelType.playlist.title, '播放列表');
      expect(PanelType.settings.title, '设置');
      expect(PanelType.danmaku.title, '弹幕设置');
      expect(PanelType.playlist.isLeft, isTrue);
      expect(PanelType.settings.isRight, isTrue);
      expect(PanelType.danmaku.isRight, isTrue);
    });

    test('打开/关闭回调被触发', () {
      final c = makeContainer();
      final n = c.read(panelStateProvider.notifier);
      var opened = 0;
      var closed = 0;
      n.onOpened = () => opened++;
      n.onClosed = () => closed++;
      n.open(PanelType.settings);
      expect(opened, 1);
      n.closeAll();
      expect(closed, 1);
    });
  });

  group('UiVisibilityController · 自动隐藏三条规则', () {
    test('3 秒后自动隐藏（播放中、无面板、未锁定）', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.read(uiVisibilityProvider.notifier).isPlaying = () => true;
        c.read(uiVisibilityProvider.notifier).hasOpenPanel = () => false;
        c.read(uiVisibilityProvider.notifier).show();
        expect(c.read(controlsVisibleProvider), isTrue);
        async.elapse(const Duration(seconds: 4));
        expect(c.read(controlsVisibleProvider), isFalse,
            reason: '3 秒无操作应自动隐藏');
      });
    });

    test('★ 暂停时不自动隐藏（交互清单第 18 条）', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.read(uiVisibilityProvider.notifier).isPlaying = () => false;
        c.read(uiVisibilityProvider.notifier).hasOpenPanel = () => false;
        c.read(uiVisibilityProvider.notifier).show();
        async.elapse(const Duration(seconds: 10));
        expect(c.read(controlsVisibleProvider), isTrue,
            reason: '暂停时用户可能正要操作，不能自动隐藏');
      });
    });

    test('★ 面板打开时不自动隐藏（交互清单第 17 条）', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.read(uiVisibilityProvider.notifier).isPlaying = () => true;
        c.read(uiVisibilityProvider.notifier).hasOpenPanel = () => true;
        c.read(uiVisibilityProvider.notifier).show();
        async.elapse(const Duration(seconds: 10));
        expect(c.read(controlsVisibleProvider), isTrue,
            reason: '面板开着时隐藏控制层会让用户找不到关闭入口');
      });
    });

    test('★ 锁定强制隐藏且不排计时器（交互清单第 19 条）', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final n = c.read(uiVisibilityProvider.notifier);
        n.isPlaying = () => true;
        n.hasOpenPanel = () => false;
        n.toggleLock();
        expect(c.read(isLockedProvider), isTrue);
        expect(c.read(controlsVisibleProvider), isFalse,
            reason: '锁定后控制层必须立即隐藏');
        async.elapse(const Duration(seconds: 10));
        expect(c.read(controlsVisibleProvider), isFalse);
      });
    });

    test('解锁后恢复可见并重新计时', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final n = c.read(uiVisibilityProvider.notifier);
        n.isPlaying = () => true;
        n.hasOpenPanel = () => false;
        n.toggleLock();
        n.toggleLock();
        expect(c.read(isLockedProvider), isFalse);
        expect(c.read(controlsVisibleProvider), isTrue);
        async.elapse(const Duration(seconds: 4));
        expect(c.read(controlsVisibleProvider), isFalse, reason: '解锁后应恢复自动隐藏');
      });
    });

    test('toggle 切换显隐', () {
      final c = makeContainer();
      final n = c.read(uiVisibilityProvider.notifier);
      n.hide();
      expect(c.read(controlsVisibleProvider), isFalse);
      n.toggle();
      expect(c.read(controlsVisibleProvider), isTrue);
    });

    test('hintShown 只标记一次', () {
      final c = makeContainer();
      final n = c.read(uiVisibilityProvider.notifier);
      expect(c.read(uiVisibilityProvider).hintShown, isFalse);
      n.markHintShown();
      expect(c.read(uiVisibilityProvider).hintShown, isTrue);
      n.markHintShown(); // 幂等
      expect(c.read(uiVisibilityProvider).hintShown, isTrue);
    });
  });

  group('AudioController · 延迟边界（交互清单第 10 条）', () {
    test('★ 上限 +5s', () {
      final c = makeContainer();
      final n = c.read(audioStateProvider.notifier);
      n.setDelay(const Duration(seconds: 99));
      expect(c.read(audioStateProvider).delay, const Duration(seconds: 5));
    });

    test('★ 下限 −5s', () {
      final c = makeContainer();
      final n = c.read(audioStateProvider.notifier);
      n.setDelay(const Duration(seconds: -99));
      expect(c.read(audioStateProvider).delay, const Duration(seconds: -5));
    });

    test('步进 0.1s', () {
      final c = makeContainer();
      final n = c.read(audioStateProvider.notifier);
      n.stepDelay(1);
      expect(c.read(audioStateProvider).delay,
          const Duration(milliseconds: 100));
      n.stepDelay(-3);
      expect(c.read(audioStateProvider).delay,
          const Duration(milliseconds: -200));
    });

    test('canIncrease / canDecrease 边界为假', () {
      final c = makeContainer();
      final n = c.read(audioStateProvider.notifier);
      n.setDelay(const Duration(seconds: 5));
      expect(n.canIncrease, isFalse);
      expect(n.canDecrease, isTrue);
      n.setDelay(const Duration(seconds: -5));
      expect(n.canDecrease, isFalse);
      expect(n.canIncrease, isTrue);
    });
  });

  group('SubtitleController · 延迟/字号/编码（交互清单第 10 条）', () {
    test('延迟钳制在 ±5s', () {
      final c = makeContainer();
      final n = c.read(subtitleStateProvider.notifier);
      n.setDelay(const Duration(seconds: 99));
      expect(c.read(subtitleStateProvider).delay, const Duration(seconds: 5));
      n.setDelay(const Duration(seconds: -99));
      expect(c.read(subtitleStateProvider).delay, const Duration(seconds: -5));
    });

    test('四档字号与规格一致', () {
      expect(SubtitleFontSize.values.map((e) => e.label).toList(),
          ['小', '中', '大', '超大']);
    });

    test('四种编码与规格一致', () {
      expect(SubtitleEncoding.values.map((e) => e.label).toList(),
          ['自动', 'UTF-8', 'GBK', 'BIG5']);
    });

    test('★ selectTrack(null) 关闭字幕', () {
      final c = makeContainer();
      final n = c.read(subtitleStateProvider.notifier);
      n.setTracks(const [
        SubtitleTrack(id: 's1', name: '简体中文'),
        SubtitleTrack(id: 's2', name: '繁體中文'),
      ]);
      n.selectTrack('s1');
      expect(c.read(subtitleStateProvider).activeTrackId, 's1');
      n.selectTrack(null);
      expect(c.read(subtitleStateProvider).activeTrackId, isNull,
          reason: '关闭字幕必须能表达（用哨兵而非 ?? this.x）');
    });

    test('选择 SubtitleTrack.off 等价于关闭', () {
      final c = makeContainer();
      final n = c.read(subtitleStateProvider.notifier);
      n.selectTrack('s1');
      n.selectTrack(SubtitleTrack.off.id);
      expect(c.read(subtitleStateProvider).activeTrackId, isNull);
    });

    test('★ 改编码时若已挂外挂字幕会触发重新解析', () {
      final c = makeContainer();
      final n = c.read(subtitleStateProvider.notifier);
      var reloads = 0;
      n.onLoadExternalRequested = (_) => reloads++;
      n.setTracks(const [
        SubtitleTrack(id: 'ext', name: 'a.srt', isExternal: true),
      ]);
      n.setEncoding(SubtitleEncoding.gbk);
      expect(reloads, 1,
          reason: '改了编码却不重新解析 → 画面没变化，用户会以为设置无效');
    });

    test('没有外挂字幕时改编码不触发解析', () {
      final c = makeContainer();
      final n = c.read(subtitleStateProvider.notifier);
      var reloads = 0;
      n.onLoadExternalRequested = (_) => reloads++;
      n.setEncoding(SubtitleEncoding.gbk);
      expect(reloads, 0);
    });

    test('addExternalTrack 自动选中', () {
      final c = makeContainer();
      final n = c.read(subtitleStateProvider.notifier);
      n.addExternalTrack(
          const SubtitleTrack(id: 'e1', name: 'x.srt', isExternal: true));
      expect(c.read(subtitleStateProvider).activeTrackId, 'e1');
      expect(c.read(subtitleStateProvider).tracks.length, 1);
    });

    test('SubtitleTrack.subtitle 文案（原型：名称 + 格式）', () {
      expect(
        const SubtitleTrack(id: 'a', name: 'n', format: 'srt', isExternal: true)
            .subtitle,
        'SRT · 外挂',
      );
      expect(
        const SubtitleTrack(id: 'a', name: 'n', format: 'ass', isEmbedded: true)
            .subtitle,
        'ASS · 内嵌',
      );
    });
  });

  group('PlaylistController（交互清单第 13 条）', () {
    const entries = [
      PlaylistEntry(id: '1', title: 'A'),
      PlaylistEntry(id: '2', title: 'B'),
      PlaylistEntry(id: '3', title: 'C'),
    ];

    test('setEntries 钳制非法 startIndex', () {
      final c = makeContainer();
      final n = c.read(playlistStateProvider.notifier);
      n.setEntries(entries, startIndex: 99);
      expect(c.read(playlistStateProvider).currentIndex, 2,
          reason: '越界下标不该让播放器崩，退化为最后一项');
      n.setEntries(entries, startIndex: -5);
      expect(c.read(playlistStateProvider).currentIndex, 0);
    });

    test('next / previous', () {
      final c = makeContainer();
      final n = c.read(playlistStateProvider.notifier);
      n.setEntries(entries);
      n.next();
      expect(c.read(playlistStateProvider).currentIndex, 1);
      n.previous();
      expect(c.read(playlistStateProvider).currentIndex, 0);
    });

    test('★ 到头部/尾部不越界、不擅自回绕', () {
      final c = makeContainer();
      final n = c.read(playlistStateProvider.notifier);
      n.setEntries(entries);
      n.previous();
      expect(c.read(playlistStateProvider).currentIndex, 0,
          reason: '到头不动 —— 擅自回绕会让"手动点上一项"跳到片尾');
      n.setEntries(entries, startIndex: 2);
      n.next();
      expect(c.read(playlistStateProvider).currentIndex, 2);
      expect(c.read(playlistStateProvider).hasNext, isFalse);
      expect(c.read(playlistStateProvider).hasPrevious, isTrue);
    });

    test('select 同一项不触发回调', () {
      final c = makeContainer();
      final n = c.read(playlistStateProvider.notifier);
      var calls = 0;
      n.setEntries(entries);
      n.onSelect = (_) => calls++;
      n.select(0);
      expect(calls, 0, reason: '点当前项不该重新加载媒体');
      n.select(2);
      expect(calls, 1);
    });

    test('播放模式循环', () {
      final c = makeContainer();
      final n = c.read(playlistStateProvider.notifier);
      expect(c.read(playlistStateProvider).mode, PlayMode.sequence);
      n.cycleMode();
      expect(c.read(playlistStateProvider).mode, PlayMode.shuffle);
      n.cycleMode();
      expect(c.read(playlistStateProvider).mode, PlayMode.single);
      n.cycleMode();
      expect(c.read(playlistStateProvider).mode, PlayMode.sequence);
    });

    test('单曲模式自动连播返回当前项', () {
      final c = makeContainer();
      final n = c.read(playlistStateProvider.notifier);
      n.setEntries(entries);
      n.setMode(PlayMode.single);
      expect(n.autoNextEntry()?.id, '1');
    });

    test('顺序模式到末尾返回 null（由上层决定是否循环）', () {
      final c = makeContainer();
      final n = c.read(playlistStateProvider.notifier);
      n.setEntries(entries, startIndex: 2);
      expect(n.autoNextEntry(), isNull);
    });

    test('三档模式文案', () {
      expect(PlayMode.values.map((e) => e.label).toList(), ['顺序', '随机', '单曲']);
    });
  });

  group('DanmakuPanelController · 单位换算（易错点）', () {
    test('★ 透明度 0–100 ⇄ 0.2–1.0', () {
      expect(DanmakuPanelState.opacityToConfig(80), closeTo(0.8, 0.001));
      expect(DanmakuPanelState.opacityToConfig(100), 1.0);
      expect(DanmakuPanelState.opacityToConfig(0), 0.2,
          reason: '下限 0.2 —— 0 会被设置页 Slider(min 0.2) 判越界');
      expect(DanmakuPanelState.opacityFromConfig(0.8), 80);
    });

    test('★ 字号三档 ⇄ fontScale', () {
      expect(DanmakuPanelState.fontSizeToConfig(DanmakuFontSize.small), 0.85);
      expect(DanmakuPanelState.fontSizeToConfig(DanmakuFontSize.medium), 1.0);
      expect(DanmakuPanelState.fontSizeToConfig(DanmakuFontSize.large), 1.25);
      expect(DanmakuPanelState.fontSizeFromConfig(0.8), DanmakuFontSize.small);
      expect(DanmakuPanelState.fontSizeFromConfig(1.0), DanmakuFontSize.medium);
      expect(DanmakuPanelState.fontSizeFromConfig(1.3), DanmakuFontSize.large);
    });

    test('★ 速度档 1–10 ⇄ speed 0.5–2.0（单调递增）', () {
      expect(DanmakuPanelState.speedToConfig(1), closeTo(0.5, 0.001));
      expect(DanmakuPanelState.speedToConfig(10), closeTo(2.0, 0.001));
      var prev = 0.0;
      for (var l = 1; l <= 10; l++) {
        final v = DanmakuPanelState.speedToConfig(l);
        expect(v, greaterThan(prev), reason: '档位越高应越快');
        prev = v;
      }
    });

    test('速度档反向换算回到原档', () {
      for (var l = 1; l <= 10; l++) {
        final back = DanmakuPanelState.speedFromConfig(
            DanmakuPanelState.speedToConfig(l));
        expect(back, l, reason: '第 $l 档往返后变成了 $back');
      }
    });

    test('越界档位被钳制', () {
      expect(DanmakuPanelState.speedToConfig(0), closeTo(0.5, 0.001));
      expect(DanmakuPanelState.speedToConfig(99), closeTo(2.0, 0.001));
      expect(DanmakuPanelState.speedFromConfig(0.1), 1);
      expect(DanmakuPanelState.speedFromConfig(9.9), 10);
    });

    test('★ 滚动耗时 = 13 − 档位（原型公式）', () {
      expect(DanmakuPanelState.scrollDuration(1), const Duration(seconds: 12));
      expect(DanmakuPanelState.scrollDuration(5), const Duration(seconds: 8));
      expect(DanmakuPanelState.scrollDuration(10), const Duration(seconds: 3));
    });

    test('十档速度标签与原型一致', () {
      expect(DanmakuPanelState.speedLabel(1), '极慢');
      expect(DanmakuPanelState.speedLabel(5), '中');
      expect(DanmakuPanelState.speedLabel(10), '飞速');
    });

    test('默认值来自原型（透明度 80 / 速度档 5）', () {
      const s = DanmakuPanelState();
      expect(s.opacity, 80);
      expect(s.speedLevel, 5);
      expect(s.enabled, isTrue);
    });

    test('开关切换与回调', () {
      final c = makeContainer();
      final n = c.read(danmakuPanelProvider.notifier);
      var persisted = 0;
      n.onPersist = ({bool? enabled, double? opacity, double? fontScale,
              double? speed, DanmakuArea? area}) => persisted++;
      n.toggle();
      expect(c.read(danmakuPanelProvider).enabled, isFalse);
      expect(persisted, 1);
    });

    test('关闭弹幕不清空数据（再次打开立即恢复）', () {
      final c = makeContainer();
      final n = c.read(danmakuPanelProvider.notifier);
      n.setOpacity(50);
      n.toggle(); // 关
      n.toggle(); // 开
      expect(c.read(danmakuPanelProvider).opacity, 50,
          reason: '开关只影响渲染，不该重置用户设置');
    });

    test('syncFromConfig 反向同步既有配置', () {
      final c = makeContainer();
      final n = c.read(danmakuPanelProvider.notifier);
      n.syncFromConfig(
          enabled: false, opacity: 0.5, fontScale: 1.25, speed: 2.0);
      final s = c.read(danmakuPanelProvider);
      expect(s.enabled, isFalse);
      expect(s.opacity, 50);
      expect(s.fontSize, DanmakuFontSize.large);
      expect(s.speedLevel, 10);
    });

    test('降采样阈值 > 100 条（规格 §11.5）', () {
      final c = makeContainer();
      final n = c.read(danmakuPanelProvider.notifier);
      n.setActiveCount(100);
      expect(n.needsDownsampling, isFalse);
      n.setActiveCount(101);
      expect(n.needsDownsampling, isTrue);
    });

    test('三档字号与三个区域文案', () {
      expect(DanmakuFontSize.values.map((e) => e.label).toList(),
          ['小', '中', '大']);
      expect(DanmakuArea.values.map((e) => e.label).toList(),
          ['滚动', '顶部', '底部']);
    });
  });

  group('MediaInfo / AudioTrack 展示文案', () {
    test('分辨率文案', () {
      expect(
        const MediaInfo(width: 3840, height: 2160).resolutionLabel,
        '3840 × 2160',
      );
      expect(const MediaInfo().resolutionLabel, isNull,
          reason: '缺失字段应显示为 null（UI 画「—」），不要编造');
    });

    test('音轨声道文案', () {
      expect(const AudioTrack(id: 'a', name: 'n', channels: 2).subtitle,
          contains('立体声'));
      expect(const AudioTrack(id: 'a', name: 'n', channels: 8).subtitle,
          contains('7.1'));
      expect(const AudioTrack(id: 'a', name: 'n', channels: 6).subtitle,
          contains('5.1'));
    });
  });
}
