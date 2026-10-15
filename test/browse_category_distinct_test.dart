// ══════════════════════════════════════════════════════════════════════
//  ★★★ 守卫测试：「6 个类别点开就在一块」的三个根因
// ══════════════════════════════════════════════════════════════════════
//
// ## 用户报障（2026-10-15）
// > "首页中 6 个类别中点开其实**就在一块**。没有细分类别"
//
// ## 三个根因（都经真机 + 代码核实）
// ```
// ① 6 个类别 `sort_by` **全用 `popularity.desc`**
//    ⇒ TMDB 的热度榜是**全球通用**的 ⇒ 各类别前几条必然重叠
// ② 「电影」`genreId == null` ⇒ **不发 `with_genres`**
//    ⇒ discover/movie 返回"全站热门电影"（无筛选）
// ③ ★ **客户端又把结果按 `popularity` 重排了一遍**
//      `out.sort((a,b) => b.popularity.compareTo(a.popularity))`
//    ⇒ **把服务端的 `sort_by` 完全抹掉** ⇒ 改 ① 等于没改
// ```
// ③ 是最隐蔽的：只修 ①② 而留着 ③ ⇒ **看起来改了，实际没变**。
//
// ## 为什么必须测
// 这类 bug analyze 全绿、测试全绿（没有任何断言覆盖"排序维度"）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/calendar_client.dart';

String _stripComments(String src) {
  var s = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  s = s.replaceAll(RegExp(r'//[^\n]*'), '');
  return s;
}

/// 取方法体（按缩进配对）。
///
/// ## ⚠️ 两个必须避开的坑（我都栽过）
/// **① 泛型里的嵌套尖括号**
/// `Future<List<CalendarEntry>> fetchBrowse({` 有 `<>` 嵌套，
/// 用 `Future<[^>]*>` 匹配不了（`[^>]*` 在第一个 `>` 就停）
/// ⇒ 会**找不到方法**。改用 `Future<[^(]*`（到左括号为止）。
///
/// **② 多行函数签名的收尾 `}) async {`**
/// 本方法签名跨了 20+ 行（因为有大段注释），最后一行是
/// `    }) async {` —— 它以 **2 空格 + `}`** 开头，
/// 会被"缩进配对"判据**误认为方法结束** ⇒ body 只有 23 行（仅签名）。
/// ⇒ 判据必须是**真正的成员边界**：`^  }` 且**该行之后**是空行/新成员。
String? _methodBody(String src, String name) {
  final lines = src.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (RegExp(r'^\s+(?:Future<[^(]*|void|Widget|static)\s+' +
            RegExp.escape(name) +
            r'\s*\(')
        .hasMatch(lines[i])) {
      final indent = lines[i].length - lines[i].trimLeft().length;
      final buf = <String>[lines[i]];
      for (var k = i + 1; k < lines.length; k++) {
        final s = lines[k];
        // ⚠️ 只认"真正的成员边界"：缩进 ≤ 本方法 **且**
        //    形如 `Future<...> x(` / `void x(` / `Widget x(` / `@override`
        //    —— **不认** `}) async {`（那是签名收尾，不是结束）
        if (s.trim().isNotEmpty &&
            (s.length - s.trimLeft().length) <= indent &&
            RegExp(r'^\s+(?:@override|Future<|void\s|Widget\s|static\s|'
                    r'String\s|int\s|bool\s|double\s|Stream<)')
                .hasMatch(s)) {
          break;
        }
        buf.add(s);
        // 结束判据：本方法缩进级的 `  }`，且**下一行是空行或另一个成员**
        if (RegExp(r'^\s{0,' + '$indent' + r'\}\s*$').hasMatch(s) &&
            s.trim() == '}') {
          final nxt = k + 1 < lines.length ? lines[k + 1] : '';
          if (nxt.trim().isEmpty ||
              RegExp(r'^\s+(?:@override|Future<|void\s|Widget\s|static\s|'
                      r'///)')
                  .hasMatch(nxt)) {
            break;
          }
        }
      }
      return buf.join('\n');
    }
  }
  return null;
}

void main() {
  late String src;

  setUpAll(() async {
    src = _stripComments(
        await File('lib/data/calendar_client.dart').readAsString());
  });

  group('★★★ 根因①：每个类别的排序维度必须**互不相同**', () {
    test('★★★ 6 个类别不能全用 `popularity.desc`', () {
      final used = {for (final c in BrowseCategory.values) c.label: c.sortBy};
      expect(used.values.toSet().length, greaterThan(1),
          reason: '★★★ 全用同一个排序 ⇒ TMDB 的全球热度榜通用\n'
              '    ⇒ 各类别前几条必然重叠 ⇒ 用户看到"点开就在一块"。\n'
              '    当前：$used');
      // 热度排序**不应**再出现在任何类别（那是"全球通用榜"的根源）
      expect(used.values.any((v) => v.startsWith('popularity')), isFalse,
          reason: '★ 用 `popularity` 会让所有类别回到同一个榜\n'
              '    当前：$used');
    });

    test('★★ 电影必须用上映日期排序（用户想看新片，不是老热门）', () {
      expect(BrowseCategory.movie.sortBy, contains('primary_release_date'),
          reason: '★★ 电影若用 `popularity` ⇒ 返回全站热门老片\n'
              '    （它的 `genreId` 是 null，没有 genre 可筛）');
    });

    test('★★ 纪录片用评分排序（时效性弱，看质量）', () {
      expect(BrowseCategory.documentary.sortBy, contains('vote_average'),
          reason: '★ 纪录片按"最近在播"排没意义（时政/自然类时效性弱）');
    });
  });

  group('★★★ 根因③：客户端**不许**覆盖服务端排序', () {
    test('★★★ `fetchBrowse` 里不许再按 popularity 重排', () {
      final body = _methodBody(src, 'fetchBrowse');
      expect(body, isNotNull, reason: '找不到 fetchBrowse');
      expect(RegExp(r'out\.sort\s*\(').hasMatch(body!), isFalse,
          reason: '★★★ `out.sort((a,b)=>b.popularity...)` 会把服务端的\n'
              '    `sort_by` **完全抹掉** ⇒ 6 个类别又变回同一个顺序。\n'
              '    ⚠️ 这是最隐蔽的根因：只改 `sort_by` 而留着这行\n'
              '    ⇒ **改了等于没改**（对照实验已证实）');
    });

    test('★★ 其它方法的 popularity 排序**保留**（不要误删）', () {
      // 只删 fetchBrowse 那一处 —— 日历/热播的语义不同（它们就该按热度）
      final all = RegExp(r'popularity \?\? 0\)\.compareTo').allMatches(src).length;
      expect(all, greaterThan(0),
          reason: '★ 日历/热播的排序**依赖** popularity\n'
              '    （它们的服务端不保证顺序）⇒ 不该一并删掉');
    });
  });

  group('★★★ 根因②：电影的"无 genre"必须由排序+地区补偿', () {
    test('★★ 电影 genreId 为 null 是**有意的**（不是漏填）', () {
      expect(BrowseCategory.movie.genreId, isNull,
          reason: '★ 「电影」是与「剧集」并列的**大类**，不是 genre\n'
              '    硬塞一个（如 `28` 动作）会把"电影"偷偷变成"动作片"');
    });

    test('★★ 电影必须有地区可筛（补偿无 genre）', () {
      expect(BrowseCategory.movie.regions.length, greaterThan(1),
          reason: '★ 电影没有 genre 筛选 ⇒ 只能靠地区区分\n'
              '    （`with_origin_country`）');
    });
  });

  group('★ 请求参数必须带上类别的 sortBy', () {
    test('★★★ `fetchBrowse` 的 `sort_by` 必须**由 sort 参数解析**且默认回落到类别值',
        () {
      final body = _methodBody(src, 'fetchBrowse')!;
      // ⚠️ 2026-10-15（D 项）后实现从 `'sort_by': category.sortBy` 变成
      //    `'sort_by': sort.paramFor(category.sortBy, kind: category.kind)`
      //    （支持用户显式选排序，默认仍用类别值）。
      // ⇒ 断言**升级**为两条：
      //    ① 必须经过 `paramFor`（否则用户选了排序也不生效）
      //    ② 必须把 `category.sortBy` 传进去（否则默认值丢了 ⇒ 回到根因①）
      expect(body.contains("'sort_by': sort.paramFor(category.sortBy"),
          isTrue,
          reason: '★★★ `sort_by` 必须是 `sort.paramFor(category.sortBy, …)`：\n'
              '    · 硬编码字面量 ⇒ 所有类别同序（根因①复发）\n'
              '    · 只用 `sort.paramFor(x)` 而没传 `category.sortBy`\n'
              '      ⇒ 用户不选时**默认值丢失** ⇒ 同样复发根因①');
    });

    test('★★★ `BrowseSort.categoryDefault` 必须回落到类别的 sortBy', () {
      // 这是"零回归"的关键：不选排序时行为必须与修复后完全一致
      expect(
          src.contains('BrowseSort.categoryDefault => categoryDefault'), isTrue,
          reason: '★★★ `categoryDefault` 若不回落 ⇒ 不选排序的用户会\n'
              '    拿到错误的默认（如所有类别都变 popularity）');
    });
  });

  group('★★★ 根因④：缓存键必须覆盖"影响结果的全部输入"', () {
    test('★★★ 缓存键必须含 `sortBy`（否则改了排序看不到效果）', () {
      final body = _methodBody(src, 'fetchBrowse');
      expect(body, isNotNull);
      // 定位 cacheKey 那一行
      final m = RegExp(r"final cacheKey = 'browse:[^;]*;").firstMatch(body!);
      expect(m, isNotNull, reason: '找不到 cacheKey 定义');
      final keyLine = m!.group(0)!;
      expect(keyLine.contains('category.sortBy'), isTrue,
          reason: '★★★ 真机实测：改了 6 个类别的 `sort_by` 后，点「电影」\n'
              '    **立即出数据、零请求、零日志** ⇒ 命中**旧磁盘缓存**\n'
              '    ⇒ 改了等于没改，用户永远看不到修复（直到 TTL 过期）。\n'
              '    ⚠️ 规则：**缓存键必须覆盖所有影响结果的输入**\n'
              '    （sort_by / with_genres / with_origin_country / 日期窗口）');
    });

    test('★★ 电影还需把日期窗口写进缓存键（它也影响结果）', () {
      final body = _methodBody(src, 'fetchBrowse')!;
      final m = RegExp(r"final cacheKey = 'browse:[^;]*;").firstMatch(body)!;
      final keyLine = m.group(0)!;
      expect(
          keyLine.contains('primary_release_date') || keyLine.contains('year'),
          isTrue,
          reason: '★ 电影的 `primary_release_date.gte` 随年份变化\n'
              '    ⇒ 跨年后旧缓存会返回去年的窗口');
    });
  });
}
