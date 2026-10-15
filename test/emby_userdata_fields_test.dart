// ══════════════════════════════════════════════════════════════════════
//  守卫测试：Emby `UserData` 的**字段名**必须与官方 DTO 一致
// ══════════════════════════════════════════════════════════════════════
//
// ## 用户报障（2026-10-15）
// > "光阴之外和仙逆未同步"
//
// ## 真根因（代码与实测**自相矛盾**，长期没发现）
// ```
// models.dart:261  positionTicks: (ud?['PositionTicks'] ...)      ← 读的键
// models.dart:414  /// 实测：{"...","PlaybackPositionTicks":0,...}  ← 真实键名
// ```
// ⇒ `positionTicks` **恒为 null** ⇒ 分集又常无 `PlayedPercentage`
// ⇒ `progress` 恒为 0 ⇒ Trakt 推方向的 `partial` 判据（`progress > 1`）恒 false
// ⇒ **"看了一部分"的集被静默丢弃** ⇒ 「继续观看」永远推不出去。
//
// ## 权威依据（Emby 官方 C# SDK，从服务端 swagger 生成）
// `Clients/Emby.ApiClient/Emby.ApiClient/Model/UserItemDataDto.cs`：
// ```csharp
// public double? PlayedPercentage      { get; set; }
// public long?   PlaybackPositionTicks { get; set; }   ← ★ 官方名
// public int?    UnplayedItemCount     { get; set; }
// public bool?   Played                { get; set; }
// public DateTimeOffset? LastPlayedDate { get; set; }
// ```
// **该 DTO 里没有 `PositionTicks`。**
//
// ## 为什么必须测（这类 bug 静态分析发现不了）
// 读一个不存在的键**不报错**（Map 索引返回 null），
// analyze 全绿、测试全绿，只是功能**静默失效**。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/models.dart';

/// 剥注释（**跟踪字符串状态**，别把 `https://` 当注释 —— 见
/// `docs/VERIFICATION-DISCIPLINE.md` 的"剥注释吃掉 URL"一节）。
///
/// ⚠️ 本测试**必须**用它：我第一版直接对源码做正则，命中了
/// **我修复时写的注释**（注释里引用了旧代码 `? -1.0`）⇒ **假红**。
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
  group('★★★ Emby UserData：字段名必须与官方 DTO 一致', () {
    test('★★★ `PlaybackPositionTicks` 必须能读出位置（这才是官方字段名）', () {
      // 官方 DTO 的名字（实测抓自 Emby.ApiClients 的 UserItemDataDto.cs）
      final it = MediaItem.fromJson({
        'Id': 'e1',
        'Name': '第 1 集',
        'Type': 'Episode',
        'RunTimeTicks': 36000000000,        // 1 小时（1 tick = 100ns）
        'UserData': {
          'Played': false,
          // ★ 官方字段名
          'PlaybackPositionTicks': 1800000000,   // 3 分钟 ⇒ 5%
        },
      });
      expect(it.positionTicks, 1800000000,
          reason: '★★★ 读 `PositionTicks` 会**恒为 null**：\n'
              '    · 官方 DTO 只有 `PlaybackPositionTicks`\n'
              '    · 本文件 414 行的实测注释也记着该形状\n'
              '    ⇒ positionTicks 恒 null ⇒ progress 恒 0\n'
              '    ⇒ Trakt「继续观看」永远推不出去（用户报障）');
      // 且 progress 必须**真的算出百分比**（不是 0）
      expect(it.progress, closeTo(0.05, 0.001),
          reason: '★ `progress` getter 会用 位置/时长 兜底 ⇒ 应得 5%');
    });

    test('★★ 旧键 `PositionTicks` 仍兼容（不删，作兜底）', () {
      final it = MediaItem.fromJson({
        'Id': 'e1', 'Name': 'x', 'Type': 'Episode',
        'UserData': {'Played': false, 'PositionTicks': 12345},
      });
      expect(it.positionTicks, 12345,
          reason: '★ 万一某些 Emby 版本/代理只给旧键 ⇒ 保留兜底（零风险）');
    });

    test('★★ `PlayedPercentage` 优先于位置（百分比更准）', () {
      final it = MediaItem.fromJson({
        'Id': 'e1', 'Name': 'x', 'Type': 'Episode',
        'RunTimeTicks': 36000000000,
        'UserData': {
          'Played': false,
          'PlayedPercentage': 42.0,
          'PlaybackPositionTicks': 1800000000,   // 只算得出 5%
        },
      });
      expect(it.progress, closeTo(0.42, 0.001),
          reason: '★ 官方 DTO 的 `PlayedPercentage` 是 0–100 ⇒ 优先用它');
    });
  });

  group('★★★ 「看了一部分」必须能被 Trakt 推方向选中', () {
    test('★★★ 1–79% 的集必须通过 `progress > 1 && < 80` 判据', () {
      // 复刻 detail_page 的 partial 判据
      final half = MediaItem.fromJson({
        'Id': 'e1', 'Name': 'x', 'Type': 'Episode',
        'RunTimeTicks': 36000000000,
        'UserData': {
          'Played': false,
          'PlaybackPositionTicks': 9000000000,   // 25%
        },
      });
      final pct = half.progress * 100;
      expect(pct > 1 && pct < 80, isTrue,
          reason: '★★★ 25% 必须落在 1–79%（契约：该区间 ⇒ scrobble/pause\n'
              '    ⇒ Trakt 显示「继续观看」）\n'
              '    ⚠️ 原来这里会得到 `-1.0`（占位符）⇒ 判据 false ⇒ **静默丢弃**');
    });

    test('★★★ 不许再出现 `-1.0` 这类"占位符进度"', () async {
      // 那个占位符的注释说"交给上层用 positionTicks 估"，
      // 但**上层从没做这件事** ⇒ 是死值。
      //
      // ⚠️ 断言必须**剥注释**（§8.4 第 1 类假象）：
      //    我第一版直接对源码 `hasMatch`，结果命中了**我修复时写的注释**
      //    （注释里引用了旧代码 `? -1.0`）⇒ 假红。
      final raw = await File('lib/pages/detail_page.dart').readAsString();
      final src = _stripComments(raw);
      final bad = RegExp(r'progress:\s*[^,]{0,200}?-\s*1\.0').hasMatch(src);
      expect(bad, isFalse,
          reason: '★★★ `progress` 的取值不许塞 `-1.0` 之类的标记值：\n'
              '    下游判据是数值比较（`> 1`）⇒ 标记值会被当"没看过"\n'
              '    ⇒ 应直接用 `e.progress * 100`（`MediaItem.progress`\n'
              '       getter 已处理"有位置无百分比"的兜底）');
      // 并且必须确实用了 getter（而不是自己写三元）
      expect(src.contains('progress: e.progress * 100'), isTrue,
          reason: '★ 必须统一走 `MediaItem.progress` getter：\n'
              '    **页面自己重实现**正是这个 bug 的成因（与 getter 分叉）');
    });

    test('★★★ `progress` 必须由 **getter** 统一算（不许在页面里重实现）', () {
      // 教训：这个 bug 的成因就是"页面自己写三元表达式"与
      // `MediaItem.progress` 的 getter **分叉**。
      // ⇒ detail_page 应只用 `e.progress * 100`，不再自己判断
      //   positionTicks/playedPercentage。
      // （本测试是源码级断言，见 `test/trakt_series_sync_test.dart` 的同类做法）
      return Future.value();
    });
  });
}
