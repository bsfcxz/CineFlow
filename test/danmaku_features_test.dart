// 弹幕三项功能（手动匹配 / 简繁转换 / 过滤等级）的守卫测试。
//
// ## 用户要求原文
// "手动匹配面板 / 简繁转换 / 过滤等级，在线匹配弹幕库增加搜弹幕
//  方便自动匹配，防止有些弹幕匹配错误"
//
// ## 为什么这些断言必要
// 三项都是"配了没接线"的高危形态（本仓库反复栽过）：
// · 手动匹配：按钮**早就存在**但只是 debugPrint 死按钮（真机确认）
// · 简繁转换：参数**早就发了**但硬编码 `chConvert: 1`，改不了
// · 过滤等级：纯新增，若 overlay 不读它则完全无效
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/danmaku/danmaku_config.dart';
import 'package:cineflow/danmaku/danmaku_layout.dart';
import 'package:cineflow/danmaku/danmaku_match_sheet.dart';
import 'package:cineflow/danmaku/danmaku_models.dart';

/// 剥注释读源码（§8.4：断言不得被注释满足）。
String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

Danmaku d(String text, [double t = 0]) =>
    Danmaku(timeMs: (t * 1000).round(), text: text);

void main() {
  group('★★ 手动匹配（用户："防止有些弹幕匹配错误"）', () {
    test('★★ 按钮不得再是 debugPrint 死按钮', () {
      final p = code('lib/player/player_flow_page.dart');
      expect(p.contains('onMatchDanmaku: () => unawaited(_openMatchSheet())'),
          isTrue,
          reason: '★★ 原来这里是 debugPrint 占位（真机确认点了没反应）。\n'
              '    自动匹配必然在"译名不同/多季归档"时猜错，\n'
              '    没有手动匹配 ⇒ 用户毫无纠错出路。');
      expect(p.contains('_openMatchSheet'), isTrue);
      expect(p.contains('_loadDanmakuWithEpisode'), isTrue);
    });

    test('★★ 选中后必须**直接生效**（不回设置页）', () {
      final p = code('lib/player/player_flow_page.dart');
      final i = p.indexOf('Future<void> _loadDanmakuWithEpisode');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到该方法');
      final seg = p.substring(i, (i + 1400).clamp(0, p.length));
      expect(seg.contains('client.comments(m.episodeId)'), isTrue,
          reason: '★ 必须用**用户选的** episodeId 拉弹幕');
      expect(seg.contains('danmakuUiProvider.notifier).set('), isTrue,
          reason: '★★ 必须把结果写进 UI —— 否则选中了界面不更新');
    });

    test('★ 候选搜索返回**列表**（不是一个 id）', () {
      final c = code('lib/danmaku/danmaku_client.dart');
      expect(c.contains('Future<List<DanmakuCandidate>> searchCandidates'),
          isTrue,
          reason: '★ 自动匹配只返回一个 id ⇒ 猜错无从纠正；\n'
              '    手动匹配必须拿到**候选列表**给用户选。');
      expect(c.contains('DanmakuCandidate('), isTrue);
    });

    test('★ 候选搜索对公共代理走两步（与自动匹配同口径）', () {
      final c = code('lib/danmaku/danmaku_client.dart');
      final i = c.indexOf('Future<List<DanmakuCandidate>> searchCandidates');
      final seg = c.substring(i, (i + 1000).clamp(0, c.length));
      expect(seg.contains('DanmakuProviderKind.publicProxy'), isTrue,
          reason: '★ 公共代理没有 search/episodes（实测 404）⇒ 必须两步');
      expect(seg.contains("'/api/v2/search/anime'"), isTrue);
      expect(seg.contains("'/api/v2/bangumi/"), isTrue);
    });

    test('★ 单个候选取详情失败不影响其它候选', () {
      final c = code('lib/danmaku/danmaku_client.dart');
      final i = c.indexOf('Future<List<DanmakuCandidate>> searchCandidates');
      final seg = c.substring(i, (i + 1800).clamp(0, c.length));
      expect(seg.contains('catch (_)'), isTrue,
          reason: '★ 8 个候选里有一个取集失败，不该让整个列表空掉');
    });

    test('★ 面板预填自动匹配用的关键词（用户不用从零输）', () {
      final p = code('lib/player/player_flow_page.dart');
      final i = p.indexOf('Future<void> _openMatchSheet');
      final seg = p.substring(i, (i + 700).clamp(0, p.length));
      expect(seg.contains('parseDanmakuQuery'), isTrue,
          reason: '★ 预填必须与自动匹配**同一口径**的番剧名');
      expect(seg.contains('initialKeyword: q.anime'), isTrue);
    });
  });

  group('★★ 简繁转换（复用服务端，不做本地映射表）', () {
    test('★ 三档语义与实测一致（0 原文 / 1 简 / 2 繁）', () {
      // 实测（2026-10-10，公共代理）：
      //   chConvert=1 → 繁体特征字 0 / 简体 23   ⇒ 转简体
      //   chConvert=2 → 繁体特征字 23 / 简体 0   ⇒ 转繁体
      expect(DanmakuChConvert.original.code, 0);
      expect(DanmakuChConvert.simplified.code, 1);
      expect(DanmakuChConvert.traditional.code, 2);
      for (final v in DanmakuChConvert.values) {
        expect(v.label.trim().isNotEmpty, isTrue, reason: '${v.name} 缺标签');
      }
    });

    test('★ 默认简体（大陆用户主场景）', () {
      expect(const DanmakuConfig().chConvert, DanmakuChConvert.simplified);
    });

    test('★★ 客户端必须用配置的值（原来硬编码 1）', () {
      final c = code('lib/danmaku/danmaku_client.dart');
      expect(c.contains('chConvertCode'), isTrue,
          reason: '★★ 原来 `comments()` 的 `chConvert` 硬编码为 1 ⇒\n'
              '    用户在设置里怎么选都不会生效（"配了没接线"）。');
      expect(c.contains('chConvertCode: config.chConvert.code'), isTrue,
          reason: '★ 必须从配置传入');
    });

    test('★★ chConvert 必须进缓存 key（否则切了读旧缓存）', () {
      final c = code('lib/danmaku/danmaku_client.dart');
      expect(c.contains(r'$cv:${baseUrl.hashCode}'), isTrue,
          reason: '★★ 缓存 key 不含简繁档 ⇒ 切了档读到的还是旧结果，\n'
              '    用户会以为"开关没生效"（本仓库同类坑反复出现）。');
    });
  });

  group('★★ 过滤等级（对照 RyoLee 的「过滤等级」）', () {
    test('★ 0 级不过滤（原样返回）', () {
      final list = [d('哈'), d('好帅'), d('66666666')];
      expect(filterByLevel(list, 0).length, 3);
    });

    test('★ 1 级去重复（保留最早一条）', () {
      final list = [d('好帅', 0), d('好帅', 5), d('好帅', 9), d('别的', 1)];
      final out = filterByLevel(list, 1);
      expect(out.length, 2, reason: '重复的只留一条');
      expect(out.first.timeMs, 0,
          reason: '★ 保留**最早**的那条（首发在剧情点上）');
    });

    test('★ 2 级去单字', () {
      final list = [d('6'), d('?'), d('哈哈'), d('好帅')];
      final out = filterByLevel(list, 2);
      expect(out.length, 2, reason: '"6"/"?" 是单字 ⇒ 被滤掉');
    });

    test('★ 3 级去超长（>30 字）', () {
      final long = d('这是一条特别特别长的弹幕' * 5); // >30 字
      final list = [long, d('正常弹幕')];
      expect(filterByLevel(list, 3).length, 1);
      expect(filterByLevel(list, 2).length, 2,
          reason: '2 级不该滤超长（规则逐级叠加）');
    });

    test('★ 4 级去复读（单字符重复率 >60%）', () {
      final list = [d('66666666'), d('哈哈哈哈哈哈'), d('正常的一句话')];
      final out = filterByLevel(list, 4);
      expect(out.length, 1, reason: '复读被滤，正常弹幕保留');
      expect(out.first.text, '正常的一句话');
    });

    test('★ 等级越高滤得越多（单调性）', () {
      final list = [
        d('哈'), d('?'), d('好帅好帅'), d('66666666'),
        d('这是一条超长的弹幕内容需要超过三十个字才能被过滤掉所以我要多写一点'),
        d('正常的弹幕内容'),
      ];
      var prev = list.length;
      for (var lv = 0; lv <= 4; lv++) {
        final n = filterByLevel(list, lv).length;
        expect(n, lessThanOrEqualTo(prev),
            reason: '$lv 级滤掉的数量不该比上一级少（规则是叠加的）');
        prev = n;
      }
    });

    test('★ 全滤掉时回退原列表（不能变成"没有弹幕"）', () {
      // 极端：全是单字 ⇒ 2 级会全滤。那时应回退，而不是空列表 ——
      // 否则用户会以为"弹幕坏了"（而实际是过滤太狠）
      final all = [d('6'), d('?'), d('哈')];
      expect(filterByLevel(all, 2).length, 3,
          reason: '★ 全滤空时回退原列表（宁可多显示，也不要"没有弹幕"）');
    });

    test('★ 空列表安全', () {
      expect(filterByLevel(const [], 4), isEmpty);
    });

    test('★★ overlay 必须**真的读** filterLevel（否则功能无效）', () {
      final o = code('lib/danmaku/danmaku_overlay.dart');
      expect(o.contains('filterByLevel(widget.items, widget.filterLevel)'),
          isTrue,
          reason: '★★ 只是加了配置字段但渲染层不读 ⇒ 功能完全无效\n'
              '    （本仓库"配了没接线"的典型形态）');
    });

    test('★ 顺序：先按等级、再按屏蔽词', () {
      final o = code('lib/danmaku/danmaku_overlay.dart');
      final i = o.indexOf('final shown = filterBlocked(');
      expect(i, greaterThanOrEqualTo(0));
      final seg = o.substring(i, (i + 200).clamp(0, o.length));
      expect(seg.contains('filterByLevel('), isTrue,
          reason: '★ 先等级过滤能减少后一步的比对条数');
    });
  });

  group('★ 配置往返（新字段必须能存能读）', () {
    test('★ copyWith 覆盖新字段', () {
      const c = DanmakuConfig();
      expect(c.copyWith(chConvert: DanmakuChConvert.traditional).chConvert,
          DanmakuChConvert.traditional);
      expect(c.copyWith(filterLevel: 3).filterLevel, 3);
    });

    test('★★ 存储层必须读写这两个字段', () {
      final s = code('lib/data/session_store.dart');
      expect(s.contains("'chConvert': c.chConvert.name"), isTrue,
          reason: '★ 存 name（可读、可降级）');
      expect(s.contains('chConvert: DanmakuChConvert.values.firstWhere'),
          isTrue);
      expect(s.contains("'filterLevel': c.filterLevel"), isTrue);
      expect(s.contains('orElse: () => const DanmakuConfig().chConvert'),
          isTrue,
          reason: '★ 未知值回退**默认值**（默认值只在 DanmakuConfig 一处）');
    });

    test('★ patch 必须支持新字段（设置页要用）', () {
      final p = code('lib/danmaku/danmaku_providers.dart');
      expect(p.contains('DanmakuChConvert? chConvert'), isTrue);
      expect(p.contains('int? filterLevel'), isTrue);
    });
  });

  group('★ DTO 的显示文案', () {
    test('candidate.display 含类型（帮用户区分同名作品）', () {
      const a = DanmakuCandidate(animeId: 1, title: '斗罗大陆', type: '网络放送');
      expect(a.display, contains('斗罗大陆'));
      expect(a.display, contains('网络放送'));
      const b = DanmakuCandidate(animeId: 1, title: '斗罗大陆');
      expect(b.display, '斗罗大陆', reason: '类型为空时不显示空括号');
    });

    test('episode.display 缺段时不出现残留字符', () {
      const e = DanmakuEpisodeBrief(episodeId: 7, number: 3, title: '第3话');
      expect(e.display, '第 3 话',
          reason: '★ 标题与集号重复时只显示一次（实测代理的 title 就是"第3话"）');
      const f = DanmakuEpisodeBrief(episodeId: 9, title: '母亲和孩子');
      expect(f.display, '母亲和孩子', reason: '无集号时只显示标题');
      const g = DanmakuEpisodeBrief(episodeId: 11);
      expect(g.display, contains('11'), reason: '都没有时回退到 id（可排查）');
    });

    test('manualMatch.display 合并番剧名与集名', () {
      const m = DanmakuManualMatch(
          episodeId: 1, animeTitle: '彻夜之歌', episodeLabel: '第 1 话');
      expect(m.display, '彻夜之歌 · 第 1 话');
      const n = DanmakuManualMatch(episodeId: 1, animeTitle: '彻夜之歌');
      expect(n.display, '彻夜之歌');
    });
  });
}
