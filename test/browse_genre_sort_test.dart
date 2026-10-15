// ══════════════════════════════════════════════════════════════════════
//  守卫测试：A（genre 入口）+ D（用户可选排序）—— 2026-10-15
// ══════════════════════════════════════════════════════════════════════
//
// ## 背景（借鉴 Overseerr，见 docs/lessons/tmdb-integration-research.md）
// 它的 `DiscoverSliderType` 把 **genre 做成一等入口**（`MOVIE_GENRES`/`TV_GENRES`），
// 且 `sortBy` 是**查询参数**（用户可选）而不是硬编码。
//
// ## 为什么必须测
// 这两项**都不报错**、analyze 全绿，但错了会让功能静默失效：
// · genre id 发错 namespace ⇒ **筛出 0 条**（TMDB 的 movie/tv 两套 id）
// · `categoryDefault` 不回落 ⇒ 不选排序的用户拿到错误默认（根因①复发）
// · 缓存键漏 genre/sort ⇒ 切了却命中旧缓存（根因④复发）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/calendar_client.dart';

/// 剥注释（**跟踪字符串状态**，别把 `https://` 当注释 —— 见
/// `docs/VERIFICATION-DISCIPLINE.md` 的"剥注释吃掉 URL"一节）。
String _stripComments(String src) {
  final out = StringBuffer();
  var inS = false, inD = false;
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    final nxt = i + 1 < src.length ? src[i + 1] : '';
    if (!inS && !inD) {
      if (c == "'") {
        inS = true;
      } else if (c == '"') {
        inD = true;
      } else if (c == '/' && nxt == '/') {
        while (i < src.length && src[i] != '\n') {
          i++;
        }
        continue;
      } else if (c == '/' && nxt == '*') {
        i += 2;
        while (i + 1 < src.length &&
            !(src[i] == '*' && src[i + 1] == '/')) {
          i++;
        }
        i += 2;
        continue;
      }
    } else {
      if (c == r'\' && i + 1 < src.length) {
        out.write(c);
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (inS && c == "'") inS = false;
      if (inD && c == '"') inD = false;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  late String cal;
  late String browse;

  setUpAll(() async {
    cal = _stripComments(
        await File('lib/data/calendar_client.dart').readAsString());
    browse = _stripComments(
        await File('lib/pages/browse_page.dart').readAsString());
  });

  group('A：genre 入口 —— movie / tv 是**两套独立 id**', () {
    test('★★★ `genresFor` 按 kind 返回不同列表（movie 与 tv 的 id 不同）', () {
      final movie = genresFor(BrowseCategory.movie);
      final tv = genresFor(BrowseCategory.series);
      final movieIds = {for (final g in movie) g.id};
      final tvIds = {for (final g in tv) g.id};
      // 「动作」：电影 28 / 剧集 10759
      expect(movieIds.contains(28), isTrue, reason: '★ 电影「动作」= 28');
      expect(tvIds.contains(10759), isTrue,
          reason: '★★★ 剧集「动作冒险」= 10759（**不是** 28）\n'
              '    TMDB 的 movie/tv 是两套独立 genre id\n'
              '    ⇒ 给剧集发 28 会**筛出 0 条**');
      expect(tvIds.contains(28), isFalse,
          reason: '★★★ 剧集列表里**不该**出现电影的 id 28');
    });

    test('★★★ 每个列表都带「全部」（用户要能取消筛选）', () {
      for (final c in BrowseCategory.values) {
        final list = genresFor(c);
        expect(list.first.id, -1,
            reason: '★★ `${c.label}` 的类型列表第一项必须是「全部」\n'
                '    （否则用户选了就**回不去**）');
      }
    });

    test('★★★ 「全部」的 `toParam` 不产生多余筛选', () {
      // 无类别 genre 且用户选「全部」⇒ null（不加参数）
      expect(BrowseGenre.all.toParam(), isNull,
          reason: '★ 电影（无自带 genre）+ 全部 ⇒ 不该发 `with_genres`');
      // 有类别 genre + 全部 ⇒ 只发类别的
      expect(BrowseGenre.all.toParam(categoryGenre: '16'), '16',
          reason: '★ 动漫 + 全部 ⇒ 只发 `16`（行为与改动前一致）');
    });

    test('★★★ `toParam` 用 `|`（OR）而非逗号（逗号是 AND）', () {
      final v = BrowseGenre.action.toParam(categoryGenre: '16');
      expect(v, '16|28',
          reason: '★★★ TMDB 多值：`|` = OR、`,` = AND\n'
              '    本仓库实测过：`10764,10767` → 1 条 vs `10764|10767` → 8 条\n'
              '    用逗号会要求"同时属于两个 genre" ⇒ 几乎必然 0 条');
    });

    test('★★ 去重：类别 genre 与用户 genre 重合时只发一次', () {
      // 「动漫」自带 16，用户又选「动画」= 16 ⇒ 必须是 '16' 而不是 '16|16'
      final v = BrowseGenre.animation.toParam(categoryGenre: '16');
      expect(v, '16', reason: '★ `16|16` 虽不报错，但语义冗余');
    });

    test('★★ `with_genres` 确实用了 `toParam`（不是旧的 category.genreId）', () {
      final i = cal.indexOf('Future<List<CalendarEntry>> fetchBrowse(');
      expect(i, greaterThan(0));
      final seg = cal.substring(i, (i + 12000).clamp(0, cal.length));
      expect(seg.contains('genre.toParam(categoryGenre: category.genreId)'),
          isTrue,
          reason: '★★ 必须合并"类别 genre"与"用户 genre"');
    });
  });

  group('D：用户可选排序', () {
    test('★★★ 每个 `BrowseSort` 都能解析出**合法**的 TMDB 值', () {
      // 合法值集合来自 Overseerr 的 `SortOptions`（实测）
      const legal = {
        'popularity.asc', 'popularity.desc',
        'release_date.asc', 'release_date.desc',
        'revenue.asc', 'revenue.desc',
        'primary_release_date.asc', 'primary_release_date.desc',
        'original_title.asc', 'original_title.desc',
        'vote_average.asc', 'vote_average.desc',
        'vote_count.asc', 'vote_count.desc',
        'first_air_date.asc', 'first_air_date.desc',
      };
      for (final s in BrowseSort.values) {
        for (final kind in ['movie', 'tv']) {
          final v = s.paramFor('popularity.desc', kind: kind);
          expect(legal.contains(v), isTrue,
              reason: '★★★ `${s.name}` 在 kind=$kind 下解析成 `$v`，\n'
                  '    **不在** TMDB 合法集合内（会 400 或被忽略）');
        }
      }
    });

    test('★★★ movie/tv 的「最新」必须用**各自的**日期字段', () {
      // 电影 = primary_release_date；剧集 = first_air_date
      expect(BrowseSort.newest.paramFor('x', kind: 'movie'),
          'primary_release_date.desc');
      expect(BrowseSort.newest.paramFor('x', kind: 'tv'),
          'first_air_date.desc',
          reason: '★★★ 剧集**没有** `primary_release_date` 字段\n'
              '    ⇒ 发错会被 TMDB 忽略/400（两个 namespace 的字段名不同）');
    });

    test('★★★ `categoryDefault` 必须**原样回落**到传入值（零回归）', () {
      expect(BrowseSort.categoryDefault.paramFor('first_air_date.desc',
              kind: 'tv'),
          'first_air_date.desc',
          reason: '★★★ 这是"不选排序时行为不变"的**唯一保证**\n'
              '    （否则所有类别会退回同一个默认 ⇒ 根因①复发）');
    });

    test('★★ 「最热」必须是 `popularity.desc`（用户显式要求时才对）', () {
      expect(BrowseSort.popular.paramFor('x', kind: 'tv'), 'popularity.desc');
    });

    test('★★★ `needsVoteFloor` 只对评分排序为真', () {
      expect(BrowseSort.rating.needsVoteFloor, isTrue);
      for (final s in BrowseSort.values) {
        if (s == BrowseSort.rating) continue;
        expect(s.needsVoteFloor, isFalse,
            reason: '★ `${s.name}` 不该加票数门槛（会无谓缩量）\n'
                '    ⚠️ 尤其 `votes`（最多人看）—— 它**本身就是票数排序**');
      }
    });
  });

  group('★★★ 缓存键：两层都必须覆盖新维度（根因④的教训）', () {
    test('★★★ 磁盘缓存键（`fetchBrowse`）必须含 genre 与 sort', () {
      final i = cal.indexOf("final cacheKey = 'browse:");
      expect(i, greaterThan(0));
      // ⚠️ 边界用**第一个 `;`**，不要拍长度（我第一版用 `i + 1600`，
      //    越界吃进了后面的代码 ⇒ 断言看到的内容不是键的全貌）。
      final seg = cal.substring(i);
      final key = seg.substring(0, seg.indexOf(';'));
      // ⚠️ 断言要查**键段的标记**（`:g`），不是裸词 `genre`。
      //    实测教训：把 `':g${genre.id}'` 改成 `''` 后，
      //    行内仍留 `'${genre.id >= 0 ? '' : ''}'`
      //    ⇒ `contains('genre')` **仍为真** ⇒ 假绿。
      expect(key.contains(':g'), isTrue,
          reason: '★★★ 漏 genre 键段 ⇒ 切类型命中旧缓存 ⇒ "点了没反应"');
      expect(key.contains('paramFor'), isTrue,
          reason: '★★★ 漏 sort ⇒ 切排序命中旧缓存');
    });

    test('★★★ 页面内缓存键（`browse_page._key`）也必须含两者', () {
      final m = RegExp(r"String get _key =>\s*'([^']*)'").firstMatch(browse);
      expect(m, isNotNull, reason: '找不到 `_key`');
      final k = m!.group(1)!;
      expect(k.contains('_genre'), isTrue, reason: '★★★ `_key` 漏 `_genre`');
      expect(k.contains('_sort'), isTrue, reason: '★★★ `_key` 漏 `_sort`');
    });

    test('★★★ 换类别时必须**同时**重置 region 与 genre', () {
      final i = browse.indexOf('void _pick(BrowseCategory c)');
      expect(i, greaterThan(0));
      final seg = browse.substring(i, (i + 900).clamp(0, browse.length));
      final body = seg.substring(0, seg.indexOf('\n  }'));
      expect(body.contains('_region = BrowseRegion.all'), isTrue);
      expect(body.contains('_genre = BrowseGenre.all'), isTrue,
          reason: '★★★ 不重置 genre ⇒ 给剧集发电影的 id（28）⇒ **筛出 0 条**\n'
              '    （movie/tv 是两套独立 genre id）');
    });
  });

  group('★★★ 失败必须显式抛出（"失败 vs 空"的接线）', () {
    test('★★★ `browse_page` 调用 `fetchBrowse` 时必须传 `throwOnError: true`',
        () {
      // ⚠️ 这行曾经"以为加了、其实没加"（脚本写第二个文件前失败退出，
      //    我没核实就报了"已修"）⇒ 用户仍看到"这个分类下没有内容"
      //    而真实原因是网络失败。**只跑 analyze 发现不了**
      //    （可选参数不传也能编译）。
      expect(browse.contains('throwOnError: true'), isTrue,
          reason: '★★★ 不传 ⇒ `fetchBrowse` 内部 `if (throwOnError)` 恒假\n'
              '    ⇒ 仍然 `return const []` ⇒ 违反 §7.8（失败伪装成空）');
    });

    test('★★★ `browse_page` 传了 `genre` 与 `sort`（两个新参数的接线）', () {
      expect(browse.contains('genre: genre'), isTrue,
          reason: '★ 不传 ⇒ 类型 chips 点了没效果（UI 有但数据层拿不到）');
      expect(browse.contains('sort: sort'), isTrue,
          reason: '★ 不传 ⇒ 排序 chips 点了没效果');
    });
  });
}
