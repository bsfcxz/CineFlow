/// **"点了没反应"型缺陷的回归防线**（用户反馈，2026-10-09）。
///
/// 用户原话：
/// ```
/// 底栏，上下集按钮无用、播放列表点击其他剧集无用，
/// 在安卓手机系统中点击全屏好像没用，
/// 点击屏幕没有及时隐藏底栏和中央控制栏，播放器还是很卡顿。
/// ```
///
/// ## 为什么这类缺陷单元测试抓不到（本项目反复踩）
/// "点了没反应"的三个共同特征：
/// 1. **接线存在**：按钮的 `onTap` 非空，静态分析看不出问题
/// 2. **回调被调用**：`onSelectMedia(i)` 确实执行了
/// 3. **但没产生用户可见效果**：调用链在中间断了 / 只改了内部状态
///
/// ⇒ 只有断言**"用户可见的效果"**才抓得到。本文件的做法：
/// 对每个"死按钮"，断言它**最终触达了能产生效果的那个方法**。
///
/// ## 本次修掉的三处（根因各不相同）
/// | 按钮 | 根因 |
/// |---|---|
/// | 播放列表选集 | `onSelectMedia` 只调 `select(i)`（改高亮），**没人调 `_playEpisode`**；且 `select()` 内部已回调过 `onSelect` ⇒ 递归 |
/// | 上下集 | `PlayerPageCallbacks` **根本没有 `onPrevious`/`onNext` 契约** ⇒ UI 层只能自己调 `previous()/next()`（同样只改高亮），宿主无处可接 |
/// | 全屏 | 只切系统栏不切方向，而播放页已锁横屏 ⇒ 用户看不出变化 |
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String stripComments(String src) {
  var s = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  s = s.split('\n').map((l) {
    final i = l.indexOf('//');
    return i >= 0 ? l.substring(0, i) : l;
  }).join('\n');
  return s;
}

String read(String rel) => File(rel).readAsStringSync();

void main() {
  group('★ 死按钮回归（用户 2026-10-09 反馈）', () {
    // ---------------------------------------------------------------
    // 播放列表选集 → 必须真正切集
    // ---------------------------------------------------------------
    test('① 选集回调必须触达"切集播放"，不能只改列表高亮', () {
      final flow = stripComments(read('lib/player/player_flow_page.dart'));

      // 找 onSelectMedia 的实现体
      final m = RegExp(r'onSelectMedia:\s*\(([^)]*)\)\s*=>?\s*([^,]+),')
          .firstMatch(flow);
      expect(m, isNotNull,
          reason: '找不到 onSelectMedia 的实现 —— 若已重构请同步改本测试');

      final impl = m!.group(2)!.trim();
      expect(impl.contains('_playEpisode') || impl.contains('_switchTo'),
          isTrue,
          reason: '★ `onSelectMedia` 的实现是「$impl」，**没有调用切集方法**。\n'
              '    这正是用户说的"播放列表点击其他剧集无用"：\n'
              '    只改列表高亮（`select(i)`）不会换集播放，画面永远不会变。\n'
              '    必须调 `_playEpisode(i)`（自动连播用的同一条路径）。');
    });

    test('① 选集回调**不得**再调 `playlist.select()`（会递归）', () {
      final flow = stripComments(read('lib/player/player_flow_page.dart'));
      final m = RegExp(r'onSelectMedia:\s*\(([^)]*)\)\s*=>?\s*([^,]+),')
          .firstMatch(flow);
      expect(m, isNotNull);
      final impl = m!.group(2)!;
      expect(impl.contains('.select('), isFalse,
          reason: '★ `select()` **内部已经调用过** `onSelect` 回调 ——\n'
              '    在 `onSelectMedia`（正是那个回调的目标）里再调 `select()`\n'
              '    就是递归自我调用。原实现就是这么写的。');
    });

    // ---------------------------------------------------------------
    // 上下集 → 必须走宿主契约
    // ---------------------------------------------------------------
    test('② 上下集按钮必须转发给宿主（不得自己调 previous/next）', () {
      final ui = stripComments(
          read('lib/player/presentation/player_ui_page.dart'));

      // 找 PlayerActionBar 的 onPrevious/onNext 接线
      final prev = RegExp(r'onPrevious:\s*([^,\n]+(?:\([^)]*\))?[^,\n]*),')
          .firstMatch(ui);
      final next = RegExp(r'onNext:\s*([^,\n]+(?:\([^)]*\))?[^,\n]*),')
          .firstMatch(ui);
      expect(prev, isNotNull, reason: '找不到 onPrevious 接线');
      expect(next, isNotNull, reason: '找不到 onNext 接线');

      final pv = prev!.group(1)!;
      final nx = next!.group(1)!;
      expect(pv.contains('playlistStateProvider') && pv.contains('previous'),
          isFalse,
          reason: '★ `onPrevious` 直接调了 `playlist.previous()` ——\n'
              '    那只改列表高亮，**不产生播放行为**。\n'
              '    必须转发给宿主：`widget.callbacks.onPrevious`。');
      expect(nx.contains('playlistStateProvider') && nx.contains('next'),
          isFalse, reason: '同上：`onNext` 必须转发宿主');
      expect(pv.contains('callbacks.onPrevious'), isTrue,
          reason: '应转发为 `widget.callbacks.onPrevious`');
      expect(nx.contains('callbacks.onNext'), isTrue,
          reason: '应转发为 `widget.callbacks.onNext`');
    });

    test('② `PlayerPageCallbacks` 必须提供 onPrevious/onNext 契约', () {
      final ui = stripComments(
          read('lib/player/presentation/player_ui_page.dart'));
      expect(ui.contains('final VoidCallback onPrevious;'), isTrue,
          reason: '★ 契约缺失是"上下集无用"的**根本原因**：\n'
              '    UI 层想做对也无处可接（宿主收不到通知）。\n'
              '    这正是"接线看起来都在、但点了没用"的典型形态。');
      expect(ui.contains('final VoidCallback onNext;'), isTrue);
    });

    test('② 流程页的 onPrevious/onNext 必须真正切集', () {
      final flow = stripComments(read('lib/player/player_flow_page.dart'));
      for (final name in ['onPrevious', 'onNext']) {
        final m = RegExp(name + r':\s*\(\)\s*\{([^}]*)\}').firstMatch(flow);
        if (m == null) {
          // 可能是表达式形式
          final m2 = RegExp(name + r':\s*([^,\n]+),').firstMatch(flow);
          expect(m2, isNotNull, reason: '找不到 $name 的实现');
          expect(m2!.group(1)!.contains('_playEpisode'), isTrue,
              reason: '★ `$name` 没有调 `_playEpisode` —— 不会真正换集');
          continue;
        }
        expect(m.group(1)!.contains('_playEpisode'), isTrue,
            reason: '★ `$name` 没有调 `_playEpisode` —— 不会真正换集');
      }
    });

    // ---------------------------------------------------------------
    // 自动隐藏 → 三条守卫必须真的接上（否则恒不隐藏）
    // ---------------------------------------------------------------
    test('③ 自动隐藏的两个前置回调必须被注入', () {
      final ui = stripComments(
          read('lib/player/presentation/player_ui_page.dart'));
      expect(ui.contains('.isPlaying ='), isTrue,
          reason: '★ `UiVisibilityController.isPlaying` **未注入**时，\n'
              '    `scheduleHide()` 里的 `isPlaying?.call() != true` 恒成立\n'
              '    ⇒ **永不安排隐藏**（控制层一直显示）。\n'
              '    用户反馈"点击屏幕没有及时隐藏底栏"可能就是这一类。');
      expect(ui.contains('.hasOpenPanel ='), isTrue,
          reason: '`hasOpenPanel` 同样必须注入（否则面板打开时也会误隐藏）');
    });

    test('③ 单次点击必须能立即隐藏（toggle → hide 路径存在）', () {
      final ctl = stripComments(read(
          'lib/player/application/controllers/ui_visibility_controller.dart'));
      expect(ctl.contains('void toggle() => state.visible ? hide() : show();'),
          isTrue,
          reason: '单击切换显隐的路径必须存在（hide 是**立即**隐藏，不等计时器）');
      expect(ctl.contains('void hide()'), isTrue);
    });
  });
}
