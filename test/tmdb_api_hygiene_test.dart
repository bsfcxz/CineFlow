// ══════════════════════════════════════════════════════════════════════
//  守卫测试：B/C/E/F 四项技术改进（2026-10-15）
// ══════════════════════════════════════════════════════════════════════
//
// ## 背景
// 用户问"能不能用 pub 上的 tmdb_api"，调研结论是**不用**（GPL-3.0），
// 但调研中发现 4 项可借鉴的技术改进：
//
// | # | 项 | 依据 |
// |---|---|---|
// | B | 海报尺寸**按用途区分** | Jellyfin `TmdbClientManager.ThumbnailSizes` |
// | C | 缓存写入**必须带 TTL** | Jellyfin `CacheDurationInHours`（我们的磁盘缓存靠 TTL 兜底）|
// | E | discover 列表用**短 TTL** | Overseerr 的 discover **完全不缓存**；6h 太长 |
// | F | `vote_average` 排序配 `vote_count.gte` | TMDB 知名坑：1 票 10 分排最前 |
//
// ⚠️ 这些改动的共同点：**都不报错、analyze 全绿、功能"看起来正常"**，
//    但效果是错的（图发虚 / 榜单不更新 / 评分榜全是冷门片）。
//    ⇒ 只有断言参数本身才能防回归。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉**注释**（但**不碰字符串里的 `//`**）。
///
/// ## ⚠️ 这里踩过一个致命坑（§8.4 第 1 类假象的**新形态**）
/// 我第一版用的是最朴素的写法：
/// ```dart
/// s = s.replaceAll(RegExp(r'//[^\n]*'), '');   // ❌ 灾难
/// ```
/// **它会吃掉 `https://` 后面的一切** —— 因为 URL 里的 `//` 也被当成注释起点！
/// 后果：
/// ```
/// 'https://image.tmdb.org/t/p/$posterSize${it['poster_path']}'
///   ↓ 剥注释后
/// 'https:
/// ```
/// ⇒ 本文件"不许硬编码 `/t/p/w数字`"那条断言**永远为真**（`0 == 0`）
/// ⇒ **反向注入仍绿**（我实测过：把 `$posterSize` 换回 `w300`，测试照样通过）。
///
/// ## 正确做法
/// 逐字符扫描，跟踪**是否在字符串字面量里**：
/// · 在 `'` / `"` 里 ⇒ 原样保留（`//` 不是注释）
/// · 不在字符串里 ⇒ `//` 到行尾是注释，`/* */` 是块注释
String _stripComments(String src) {
  final out = StringBuffer();
  var inS = false;          // 在单引号字符串里
  var inD = false;          // 在双引号字符串里
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
        // 行注释：跳到行尾（保留换行）
        while (i < src.length && src[i] != '\n') {
          i++;
        }
        continue;
      } else if (c == '/' && nxt == '*') {
        // 块注释
        i += 2;
        while (i + 1 < src.length &&
            !(src[i] == '*' && src[i + 1] == '/')) {
          i++;
        }
        i += 2;
        continue;
      }
    } else {
      // 字符串内部：处理转义，遇到配对的引号就退出
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
  late String src;

  setUpAll(() async {
    src = _stripComments(
        await File('lib/data/calendar_client.dart').readAsString());
  });

  group('B：海报尺寸必须按用途区分（不许再硬编码）', () {
    test('★★★ 不许再出现硬编码的 `/t/p/w数字`', () {
      // ⚠️ `src` 已剥注释 ⇒ 匹配到的一定是真代码
      final hard = RegExp(r"/t/p/w\d{2,4}").allMatches(src).length;
      expect(hard, 0,
          reason: '★★★ 硬编码会让"列表用 w300 但实际显示 500px"⇒ **图发虚**\n'
              '    （1080p 手机 2 列布局时每张海报约 500px 宽）\n'
              '    应改用 `posterSize` / `posterLargeSize` / `backdropSize`');
    });

    test('★★★ 三个尺寸常量必须存在', () {
      for (final k in ['posterSize', 'posterLargeSize', 'backdropSize']) {
        expect(RegExp("static const $k = 'w").hasMatch(src), isTrue,
            reason: '★ 缺 `$k`（借鉴 Jellyfin 的 ThumbnailSizes 分用途设计）');
      }
    });

    test('★★ 列表用 w342、详情用 w500（官方的相邻档位）', () async {
      final t = await File('lib/data/calendar_client.dart').readAsString();
      expect(t.contains("posterSize = 'w342'"), isTrue);
      expect(t.contains("posterLargeSize = 'w500'"), isTrue);
      expect(t.contains("backdropSize = 'w780'"), isTrue);
    });
  });

  group('C：磁盘缓存的每次写入都必须带 TTL', () {
    test('★★★ 所有 `cache?.put(` 都必须有 `ttl:` 参数', () {
      // ⚠️ 我们的缓存是 **SQLite 磁盘表**（不是 Jellyfin 的内存 LRU）
      //    ⇒ **TTL 是唯一的上限**。漏一个 ttl 就是"该条永不失效"
      //      ⇒ 磁盘慢慢涨 + 用户永远看不到更新。
      final lines = src.split('\n');
      var bad = <String>[];
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (!l.contains('cache?.put(')) continue;
        // 允许同行带 ttl，或下一行带（多行调用）
        final joined = l + (i + 1 < lines.length ? lines[i + 1] : '');
        if (!joined.contains('ttl:')) bad.add(l.trim());
      }
      expect(bad, isEmpty,
          reason: '★★★ 这些写入**没有 TTL** ⇒ 该条缓存**永不失效**：\n${bad.join('\n')}');
    });
  });

  group('E：discover 列表必须用短 TTL', () {
    test('★★★ 列表 TTL 常量必须存在且 < 详情 TTL', () async {
      final t = await File('lib/data/calendar_client.dart').readAsString();
      expect(RegExp(r"listTtl = Duration\(minutes: \d+\)").hasMatch(t), isTrue,
          reason: '★ 缺 `listTtl`（discover 列表按日期/热度排序，每天在变）');
      // 解析出具体值比较
      final m = RegExp(r'listTtl = Duration\(minutes: (\d+)\)').firstMatch(t);
      expect(m, isNotNull);
      final minutes = int.parse(m!.group(1)!);
      expect(minutes, lessThan(6 * 60),
          reason: '★★ 列表 TTL（${minutes}min）必须**短于** 6h\n'
              '    否则"早上看到的榜单，晚上还是同一批"\n'
              '    （Overseerr 的做法是 discover 完全不缓存）');
    });

    test('★★ `fetchBrowse` 用的是 `listTtl` 而不是 `cacheTtl`', () {
      // 定位 fetchBrowse 的 cache.put 那一行
      final i = src.indexOf('Future<List<CalendarEntry>> fetchBrowse(');
      expect(i, greaterThan(0));
      final seg = src.substring(i, (i + 9000).clamp(0, src.length));
      final putLines = seg
          .split('\n')
          .where((l) => l.contains('cache?.put('))
          .toList();
      expect(putLines, isNotEmpty, reason: '找不到 fetchBrowse 的 cache.put');
      expect(putLines.first.contains('listTtl'), isTrue,
          reason: '★★ 用 6h 会让"最新/流行"榜单**半天不更新**');
    });
  });

  group('F：评分排序必须配最小票数门槛', () {
    test('★★★ `vote_average` 排序时必须发 `vote_count.gte`', () {
      expect(src.contains("params['vote_count.gte']"), isTrue,
          reason: '★★★ TMDB 的 `sort_by=vote_average.desc` 会把\n'
              '    "**1 票 10 分**"的新片排在最前 —— 那不是"评分最高"，\n'
              '    那是"样本最少"（纪录片类别会整类都是冷门片）');
    });

    test('★★ 门槛是 50（太严会滤空纪录片，太松挡不住刷分）', () {
      final m = RegExp(r"params\['vote_count\.gte'\] = '(\d+)'").firstMatch(src);
      expect(m, isNotNull);
      final v = int.parse(m!.group(1)!);
      expect(v, greaterThanOrEqualTo(20), reason: '★ 太松挡不住刷分');
      expect(v, lessThanOrEqualTo(200), reason: '★ 太严会把纪录片整类滤空');
    });

    test('★★★ `vote_count` 也必须进缓存键（它影响结果）', () {
      final i = src.indexOf("final cacheKey = 'browse:");
      expect(i, greaterThan(0));
      final seg = src.substring(i, (i + 900).clamp(0, src.length));
      final keyEnd = seg.indexOf(';');
      final key = seg.substring(0, keyEnd);
      expect(key.contains('vote_count') || key.contains('vc'),
          isTrue,
          reason: '★★★ 教训（本轮实测）：**缓存键必须覆盖所有影响结果的输入**\n'
              '    —— Jellyfin 的 12 个缓存键全部带 `language` 是同一原则。\n'
              '    漏了它 ⇒ 改了门槛却命中旧缓存 ⇒ **改了看不到效果**');
    });
  });
}
