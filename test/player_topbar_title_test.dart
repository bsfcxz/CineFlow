/// **顶栏文案**回归测试（用户 2026-10-09 反馈）。
///
/// 用户原话：
/// ```
/// 左侧的退出箭头应该放置在左上角，且旁边显示的集数有重复显示，
/// 增加显示集数的名称。
/// ```
///
/// ## 修的是什么（核对代码发现的根因）
/// `player_flow_page.dart` 的旧实现：
/// ```dart
/// title:    _current.name,
/// subtitle: _current.name,   // ← 同一个值传了两次
/// ```
/// `PlayerTopBar` 是「大标题 + 可选小副标题」两行结构，两行喂同一个字段
/// ⇒ **同一句话显示两遍**。
///
/// 实机语义树印证过（多轮 dump 里反复出现）：
/// ```
/// 返回 | 第 7 集 | 第 7 集 | 快退 10 秒      ← 集数重复
/// 返回 | 秦明以身入局诱捕真凶 | 秦明以身入局诱捕真凶 | ...   ← 剧名重复
/// ```
///
/// ## 本文件守什么
/// · **绝不重复**：subtitle 与 title 相同时必须返回 null（这是 bug 的本质）
/// · **集数名称**：剧集显示 `第 N 集 · 本集名`（用户要的）
/// · 不出现 `第 null 集`（集号缺失的边界）
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/models.dart';
import 'package:cineflow/player/player_flow_page.dart';

MediaItem _episode({
  String name = '秦明以身入局诱捕真凶',
  String? seriesName = '法医秦明之龙番往事',
  int? indexNumber = 3,
}) =>
    MediaItem(
      id: 'ep1',
      name: name,
      type: 'Episode',
      seriesName: seriesName,
      indexNumber: indexNumber,
    );

MediaItem _movie({
  String name = '年会不能停！',
  String? seriesName,
  int? indexNumber,
}) =>
    MediaItem(
      id: 'mv1',
      name: name,
      type: 'Movie',
      seriesName: seriesName,
      indexNumber: indexNumber,
    );

void main() {
  group('★ 顶栏：集数名称（用户要求"增加显示集数的名称"）', () {
    test('剧集 → 「第 N 集 · 本集名」', () {
      expect(
        PlayerFlowPage.topTitleFor(_episode()),
        '第 3 集 · 秦明以身入局诱捕真凶',
        reason: '用户明确要求"增加显示集数的名称" —— 集号与名称都要有',
      );
    });

    test('无集号 → 只显示名称（**不出现"第 null 集"**）', () {
      final t = PlayerFlowPage.topTitleFor(_episode(indexNumber: null));
      expect(t, '秦明以身入局诱捕真凶');
      expect(t.contains('null'), isFalse,
          reason: '★ 集号缺失时不能拼出"第 null 集"——\n'
              '    这是拼接类代码最常见的低级缺陷。');
    });

    test('名称里已含"第 N 集" → 不重复拼', () {
      final t = PlayerFlowPage.topTitleFor(_episode(
        name: '第 3 集 秦明以身入局',
        indexNumber: 3,
      ));
      expect(t, '第 3 集 秦明以身入局',
          reason: '部分服务端把集号写进了 Name ——\n'
              '    再拼一次会变成"第 3 集 · 第 3 集 秦明…"（又是一次重复）');
    });

    test('电影 → 只显示名称', () {
      expect(PlayerFlowPage.topTitleFor(_movie()), '年会不能停！');
    });
  });

  group('★ 顶栏：不得重复显示（用户反馈的原始 bug）', () {
    test('★ 剧集的 subtitle 是**剧名**，与 title 不同', () {
      final item = _episode();
      final title = PlayerFlowPage.topTitleFor(item);
      final sub = PlayerFlowPage.subtitleFor(item);

      expect(sub, '法医秦明之龙番往事');
      expect(sub, isNot(title),
          reason: '★ 若 subtitle == title，顶栏两行就是同一句话 ——\n'
              '    这正是用户说的"集数有重复显示"。');
    });

    test('★ 电影不显示副标题（避免与 title 重复）', () {
      expect(PlayerFlowPage.subtitleFor(_movie()), isNull,
          reason: '电影的 title 已经是完整名称，再显示一行就是重复');
    });

    test('★ 剧名缺失时不显示副标题', () {
      expect(PlayerFlowPage.subtitleFor(_episode(seriesName: null)), isNull);
      expect(PlayerFlowPage.subtitleFor(_episode(seriesName: '')), isNull,
          reason: '空串也要当"没有" —— 否则会渲染一行空白');
    });

    test('★ 兜底：seriesName 恰好等于 title 时仍返回 null（绝不重复）', () {
      // 造一个"剧名与本集标题完全相同"的边界（现实中可能出现）
      final item = _episode(
        name: '法医秦明之龙番往事',
        seriesName: '法医秦明之龙番往事',
        indexNumber: null, // 无集号 → title 就是纯名称
      );
      final title = PlayerFlowPage.topTitleFor(item);
      final sub = PlayerFlowPage.subtitleFor(item);
      expect(title, '法医秦明之龙番往事',
          reason: '前提：无集号时 title 就是纯名称');
      expect(sub, isNull,
          reason: '★ 这是**防未来**的兜底：无论哪条路径算出"两行相同"，\n'
              '    都必须抑制第二行。bug 的本质就是"两行喂了同一个值"，\n'
              '    所以要去掉的是**重复**本身，而不只是修当时那一处赋值。');
    });

    test('★ 不变量：任何条目下 subtitle ≠ title', () {
      // 把各种形态都过一遍，验证不变量恒成立
      final cases = <MediaItem>[
        _episode(),
        _episode(indexNumber: null),
        _episode(seriesName: null),
        _episode(name: '法医秦明之龙番往事', seriesName: '法医秦明之龙番往事'),
        _episode(name: '第 3 集 秦明', indexNumber: 3),
        _movie(),
        _movie(seriesName: '某系列'),
        _movie(indexNumber: 5),
      ];
      for (final it in cases) {
        final title = PlayerFlowPage.topTitleFor(it);
        final sub = PlayerFlowPage.subtitleFor(it);
        expect(title, isNotEmpty,
            reason: 'title 不应为空（$it 的 name 是 "${it.name}"）');
        expect(sub, isNot(title),
            reason: '★ 不变量被破坏：条目「${it.name}」(type=${it.type}) 的\n'
                '    title="$title" 与 subtitle="$sub" 相同 ⇒ 顶栏会重复显示。');
        expect(title.contains('null'), isFalse,
            reason: 'title 里不得出现 "null" 字样');
      }
    });
  });
}
