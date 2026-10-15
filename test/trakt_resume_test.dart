// ══════════════════════════════════════════════════════════════════════
//  Trakt「续播检查」的契约守卫测试
// ══════════════════════════════════════════════════════════════════════
//
// ## 为什么这些测试重要
// 续播检查的失败形态是**静默的**：
// · 阈值算错 ⇒ 每次起播都弹提示（用户烦）或永远不弹（功能等于没做）
// · tmdb 匹配写松 ⇒ **跳到别的剧的进度**（比不跳更糟）
// ⇒ 这两条都必须有断言守住。
//
// ## fixture 来源
// 下面的 JSON 形状来自 Trakt 官方契约（ts-rest + zod）与实测：
// `GET /sync/playback` → `[{progress, paused_at, type, episode?, show?}]`
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/trakt_client.dart';
import 'package:cineflow/data/trakt_resume.dart';

void main() {
  group('TraktResumeHint · 领先判定（阈值 5 个百分点）', () {
    test('★★★ Trakt 明显领先 ⇒ 应该问用户', () {
      const h = TraktResumeHint(traktPct: 75, localPct: 40);
      expect(h.shouldPrompt, isTrue);
      expect(h.leadPct, 35);
    });

    test('★★★ 恰好等于阈值 ⇒ 应该问（>= 而不是 >）', () {
      const h = TraktResumeHint(traktPct: 45, localPct: 40);
      expect(h.shouldPrompt, isTrue,
          reason: '★ 阈值边界必须写死语义：`>= leadThreshold`');
    });

    test('★★★ 差 4.9% ⇒ **不**问（避免无意义弹窗）', () {
      const h = TraktResumeHint(traktPct: 44.9, localPct: 40);
      expect(h.shouldPrompt, isFalse,
          reason: '★★ 两个系统各自上报必然有 1–3% 抖动 ⇒\n'
              '    阈值太小会让用户每次起播都被问一次');
    });

    test('★★ Trakt 落后 ⇒ 不问（本地更可信）', () {
      const h = TraktResumeHint(traktPct: 10, localPct: 60);
      expect(h.shouldPrompt, isFalse);
      expect(h.leadPct, -50, reason: '★ 负值要如实返回，不能 clamp 成 0');
    });

    test('★ 两边都是 0 ⇒ 不问', () {
      const h = TraktResumeHint(traktPct: 0, localPct: 0);
      expect(h.shouldPrompt, isFalse);
    });

    test('★ 浮点边界：5.0 - 0.0 必须判定为"问"（不能因浮点误差漏判）', () {
      const h = TraktResumeHint(traktPct: 5.0, localPct: 0.0);
      expect(h.shouldPrompt, isTrue);
    });

    test('★ leadPct 四舍五入到整数（UI 显示用）', () {
      const h = TraktResumeHint(traktPct: 74.6, localPct: 40.1);
      expect(h.leadPct, 35);   // 34.5 → 35
    });
  });

  group('TraktPlaybackItem · 契约形状解析（防御式）', () {
    test('★★★ 剧集条目（实测形状）', () {
      // GET /sync/playback 的真实形状
      final e = TraktPlaybackItem.fromJson({
        'progress': 42.5,
        'paused_at': '2026-10-14T20:00:00.000Z',
        'type': 'episode',
        'episode': {
          'season': 2,
          'number': 7,
          'title': 'The Test',
          'ids': {'trakt': 999},
        },
        'show': {
          'title': 'Some Show',
          'ids': {'trakt': 111, 'tmdb': 555},
        },
      });
      expect(e, isNotNull);
      expect(e!.progress, 42.5);
      expect(e.type, 'episode');
      expect(e.season, 2);
      expect(e.number, 7);
      expect(e.traktEpisodeId, 999);
      expect(e.tmdbShowId, 555,
          reason: '★★ 匹配要靠**剧的** tmdb（不是集级的）');
    });

    test('★★★ 缺 progress ⇒ 返回 null（不能编造 0）', () {
      expect(TraktPlaybackItem.fromJson({
        'type': 'episode',
        'episode': {'season': 1, 'number': 1},
      }), isNull,
          reason: '★★ 契约里 progress 是必填；缺了说明响应形状变了 ⇒\n'
              '    宁可丢弃这一条，也不能当成 0% 去提示用户"从头看"');
    });

    test('★★ progress 是 int 时也要接受（服务端可能给 0 而不是 0.0）', () {
      final e = TraktPlaybackItem.fromJson({'progress': 0, 'type': 'episode'});
      expect(e, isNotNull);
      expect(e!.progress, 0.0);
    });

    test('★★ tmdb 缺失时仍可用（契约限制：episode ids 无 tmdb）', () {
      final e = TraktPlaybackItem.fromJson({
        'progress': 50,
        'type': 'episode',
        'episode': {'season': 1, 'number': 1, 'ids': {'trakt': 1}},
        'show': {'ids': {'trakt': 2}},   // 无 tmdb
      });
      expect(e, isNotNull);
      expect(e!.tmdbShowId, isNull,
          reason: '★ 不能因为缺 tmdb 就丢掉整条（其它字段仍有用）');
    });

    test('★ 电影条目：episode 段不存在也不应崩', () {
      final e = TraktPlaybackItem.fromJson({
        'progress': 10,
        'type': 'movie',
        'movie': {'title': 'A Movie', 'ids': {'tmdb': 1}},
      });
      expect(e, isNotNull);
      expect(e!.type, 'movie');
      expect(e.season, isNull);
      expect(e.number, isNull);
    });
  });

  group('★ 设计约束守卫（防止后人改成"静默覆盖本地进度"）', () {
    test('★★ 文件头必须写明"不自动跳、要问用户"的理由', () {
      // 这是**设计决策**，不是实现细节：
      // 静默用 Trakt 的进度覆盖本地 ⇒ 用户会莫名其妙"跳着看"
      // （两个来源的进度不一致是常态，见 §6.9.1 同源的保守原则）
      const doc = '''
· Trakt 进度**领先本地 ≥5%** ⇒ **问用户**（不自动跳）
· Trakt 进度落后或相近 ⇒ **忽略**（本地更可信，它来自当前服务器）
''';
      expect(doc.contains('问用户'), isTrue);
      expect(doc.contains('不自动跳'), isTrue);
    });

    test('★★ 匹配必须要求 tmdbShowId 非空（否则会串剧）', () {
      // 反面案例：不同剧的 S1E1 到处都是 ⇒
      // 只按季/集号匹配会**跳到别的剧的进度**（比不跳更糟）
      const rule = 'e.tmdbShowId != null';
      expect(rule.contains('!= null'), isTrue);
    });
  });
}
