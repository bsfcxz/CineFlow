// 电影播放时**不得残留上一部剧的播放列表**。
//
// ## 用户报障（真机截图）
// 播放电影《生化危机：爆发夜》时，底栏列表按钮显示 **`2/173`** ——
// 那是上一部剧（173 集）的残留数据。
//
// ## 根因
// `playlistStateProvider` 是**应用级单例**（退出播放页不重置），
// 而宿主只在"有分集"时 `setEntries`：
// ```dart
// if (eps != null && eps.isNotEmpty) { setEntries([...]); }   // 电影进不来
// ```
// ⇒ 电影播放时列表仍是上一部剧 ⇒ 按钮显示错计数；
// **更严重**：点开面板会看到上一部剧的分集，误点会切到别的剧。
//
// ## 守什么
// ① 电影（`episodes == null`）⇒ 宿主走 else ⇒ 列表**必须被清空**
// ② 清空后 `entries.length <= 1` ⇒ 底栏按钮**自动只剩图标**
//    （可见性由同一个判据推导，不需要第二套"电影就隐藏"的逻辑）
// ③ 多集仍显示计数（回归：别把功能改没了）
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/application/controllers/playlist_controller.dart';
import 'package:cineflow/player/application/providers/player_providers.dart';

ProviderContainer makeContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

/// 底栏按钮显示的计数（与 `player_ui_page` 的 `playlistCount` 同判据）。
///
/// 抽成函数是**为了把"判据"钉在一处**：UI 层改判据时这里必须同步，
/// 否则测试会与实际行为脱钩（`§8.4` 的"假防线"形态）。
String? badgeFor(PlaylistState s) => s.entries.length > 1
    ? '${s.currentIndex + 1}/${s.entries.length}'
    : null;

void main() {
  group('★ 电影播放：播放列表必须清空（用户报障）', () {
    test('清空后 entries 为空、currentIndex 归零', () {
      final c = makeContainer();
      final n = c.read(playlistStateProvider.notifier);

      // 先模拟"刚播完一部 173 集的剧"
      n.setEntries([
        for (var i = 0; i < 173; i++)
          PlaylistEntry(id: 'e$i', title: '第 ${i + 1} 集'),
      ], startIndex: 1);
      expect(c.read(playlistStateProvider).entries.length, 173);
      expect(badgeFor(c.read(playlistStateProvider)), '2/173',
          reason: '前置条件：剧集态确实显示 2/173（与用户截图一致）');

      // 电影进页 ⇒ 宿主走 else 分支清空
      n.setEntries(const []);

      final s = c.read(playlistStateProvider);
      expect(s.entries, isEmpty,
          reason: '★ 电影必须清空列表 —— 否则残留上一部剧的 173 集，'
              '底栏显示 `2/173`（用户截图的实际现象）');
      expect(s.currentIndex, 0,
          reason: '★ 空列表索引必须归零（否则越界）');
      expect(s.isEmpty, isTrue);
    });

    test('★ 清空后底栏计数判据不成立（按钮只剩图标）', () {
      final c = makeContainer();
      c.read(playlistStateProvider.notifier).setEntries(const []);
      expect(badgeFor(c.read(playlistStateProvider)), isNull,
          reason: '★ 清空 ⇒ 判据不成立 ⇒ 按钮自动不显示计数'
              '（单一事实源，不需要第二套"电影就隐藏"的逻辑）');
    });

    test('单集（1 项）同样不显示计数', () {
      final c = makeContainer();
      c.read(playlistStateProvider.notifier)
          .setEntries(const [PlaylistEntry(id: 'm1', title: '电影')]);
      expect(badgeFor(c.read(playlistStateProvider)), isNull,
          reason: '★ 只有 1 项时 `1/1` 是无信息噪声，不该显示');
    });

    test('多集仍显示计数（回归：别把功能改没了）', () {
      final c = makeContainer();
      c.read(playlistStateProvider.notifier).setEntries([
        for (var i = 0; i < 24; i++)
          PlaylistEntry(id: 'e$i', title: '第 ${i + 1} 集'),
      ], startIndex: 2);
      expect(badgeFor(c.read(playlistStateProvider)), '3/24',
          reason: '★ 多集应显示 `3/24`（用户要的形态）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ★★ 防"测试与真实源码脱钩"（反面教材：本仓库已栽过两次）
  // ══════════════════════════════════════════════════════════════════
  //
  // 上面的 `badgeFor` 是**复刻的判据** —— 若 UI 层把 `> 1` 改成别的，
  // 测试仍会绿（假防线）。故这里断言**真实源码**。
  group('★★ 真实源码必须与测试同构（防脱钩）', () {
    late String ui;
    late String flow;

    setUpAll(() {
      // 剥注释：否则断言可能被注释里的同名文本满足（§8.4 第 1 条）
      String code(String p) => File(p)
          .readAsStringSync()
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
          })
          .join('\n');
      ui = code('lib/player/presentation/player_ui_page.dart');
      flow = code('lib/player/player_flow_page.dart');
    });

    test('★ UI 层判据必须是 entries.length > 1（多集才显示）', () {
      expect(ui.contains('playlist.entries.length > 1'), isTrue,
          reason: '★ 底栏计数的判据必须是"多于 1 项" ——\n'
              '    改判据时本测试与 `badgeFor` 必须同步，否则测试失去意义。');
    });

    test('★★ 宿主必须有"电影清空列表"的分支', () {
      expect(flow.contains('setEntries(const [])'), isTrue,
          reason: '★★ 电影（episodes == null）必须走 else 清空播放列表 ——\n'
              '    否则残留上一部剧的分集：底栏显示错计数，\n'
              '    点开面板还会看到别的剧（用户真机截图报障）。');
    });

    test('★ 清空必须发生在"有分集才 setEntries"的 else 侧', () {
      // 结构断言：if (eps != null && eps.isNotEmpty) { ...setEntries([...]) }
      //           else { ...setEntries(const []) }
      final i = flow.indexOf('if (eps != null && eps.isNotEmpty)');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到分集判定');
      final elseIdx = flow.indexOf('else {', i);
      expect(elseIdx, greaterThan(i), reason: '找不到 else 分支');
      final clearIdx = flow.indexOf('setEntries(const [])', elseIdx);
      expect(clearIdx, greaterThan(elseIdx),
          reason: '★ 清空必须在 else 分支里（专为电影而设）');
    });
  });
}
