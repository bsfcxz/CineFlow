// ══════════════════════════════════════════════════════════════════════
//  守卫测试：Trakt **同类调用点必须成对**（2026-10-15 用户报障驱动）
// ══════════════════════════════════════════════════════════════════════
//
// ## 用户报障
// > "trakt 同步剧集还是有问题的 你查看一下咋解决"
//
// ## 查到的真 bug（本文件锁死它）
// `_syncToTrakt` 里**两处**调用 `resolveEpisode`：
// ```
// 1690 行（推"已看"）      ✅ 传了 expectYear
// 1740 行（推"继续观看"）  ❌ **没传**  ← 只修了一处
// ```
// ⇒ 对「仙逆」这类"中文名 vs Trakt 英文名"的剧：
// · 推"已看"能成功
// · 推"继续观看"**被误判错配 ⇒ 静默跳过**（只体现为 `skipCount++`）
//
// ## 为什么这个 bug 特别难发现
// **不崩溃、不报错** —— 用户提示只多一句"1 集未收录（跳过）"，
// 看起来像"Trakt 没收录"，而实际是**我们自己的校验器拦的**。
// ⇒ 只有对比"**同一方法内同类调用**"才能看出不一致。
//
// ## 为什么该规则值得长期守
// 这是本仓库第 N 次栽在"改了一处忘了另一处"（对照 §6.10 的接线完整性）。
// **凡是"同一个 API 在多处调用"的，参数必须一致**（除非有明确注释说明差异）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

/// 找出所有 `resolveEpisode(` 调用，返回每处的**参数文本**。
///
/// 从调用点起，括号配对到匹配的 `)`。
List<String> _resolveEpisodeCalls(String src) {
  final out = <String>[];
  var from = 0;
  while (true) {
    final i = src.indexOf('resolveEpisode(', from);
    if (i < 0) break;
    // 从 `(` 开始配对
    final open = i + 'resolveEpisode'.length;
    var depth = 0;
    var j = open;
    for (; j < src.length; j++) {
      if (src[j] == '(') depth++;
      if (src[j] == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    out.add(src.substring(open, j + 1));
    from = j + 1;
  }
  return out;
}

void main() {
  late String detail;
  late String player;

  setUpAll(() async {
    detail = _stripComments(
        await File('lib/pages/detail_page.dart').readAsString());
    player = _stripComments(
        await File('lib/player/player_flow_page.dart').readAsString());
  });

  group('★★★ 同类调用点必须成对（用户报障的真 bug）', () {
    test('★★★ `detail_page` 两处 `resolveEpisode` 都必须传 `expectYear`', () {
      final calls = _resolveEpisodeCalls(detail);
      expect(calls.length, greaterThanOrEqualTo(2),
          reason: '`_syncToTrakt` 应有"推已看"与"推继续观看"两处调用');
      for (var i = 0; i < calls.length; i++) {
        expect(calls[i].contains('expectYear'), isTrue,
            reason: '★★★ 第 ${i + 1} 处 `resolveEpisode` **没传** `expectYear`：\n'
                '${calls[i].trim()}\n'
                '    ⇒ `plausiblyMatches` 的年份判据进不去\n'
                '    ⇒ 「仙逆」vs `Renegade Immortal`（中英文名无重叠）\n'
                '       会被误判错配 ⇒ **静默跳过**（只表现为 skipCount++）\n'
                '    ⚠️ 这个 bug 不崩溃、不报错，只修一处时会"看起来正常"');
      }
    });

    test('★★★ `player_flow_page` 那处**必须不传** `expectYear`（有意为之）', () {
      final calls = _resolveEpisodeCalls(player);
      expect(calls.length, greaterThanOrEqualTo(1));
      expect(calls.first.contains('expectYear'), isFalse,
          reason: '★★★ 播放器里的 `item` 是 **Episode**（不是 Series）：\n'
              '    `Episode.ProductionYear` 是**该集**的年份，\n'
              '    而 Trakt 的 `show.year` 是**首播年** ⇒ 长剧后半季会差好几年\n'
              '    ⇒ 传它会让判据②（年份都已知且不一致）**误杀**正确结果\n'
              '    ⇒ 比不传更糟！\n'
              '    ⚠️ **不要"顺手补上"** —— 见该方法内的详细注释');
    });

    test('★★★ 三处调用必须各有一句注释说明"为什么传/不传"', () async {
      // 这是"防止后人顺手改"的护栏：有注释才不会被无意间改掉
      final d = await File('lib/pages/detail_page.dart').readAsString();
      final p = await File('lib/player/player_flow_page.dart').readAsString();
      // detail_page 应至少 2 处"必须传年份"的说明
      final dHits = RegExp(r'必须传年份').allMatches(d).length;
      expect(dHits, greaterThanOrEqualTo(2),
          reason: '★ 两处调用都要有"必须传年份"的注释（实测 $dHits 处）');
      // player 应有"故意不传"的说明
      expect(p.contains('故意不传'), isTrue,
          reason: '★ 播放器那处要写明"故意不传"，否则后人会以为漏了');
    });
  });

  group('★★★ 「继续观看」目标集的选取（跨季不能只看季号）', () {
    test('★★★ 选取必须**先按进度**降序（不是只看季号）', () {
      // 旧实现：`b.season.compareTo(a.season)` 优先 ⇒ 跨季时挑"季号最大"
      // 而不管进度 ⇒ S2E1(2%) 会盖过 S1E5(40%)
      final i = detail.indexOf('final partial = allEps');
      expect(i, greaterThan(0), reason: '找不到 partial 定义');
      final seg = detail.substring(i, (i + 900).clamp(0, detail.length));
      final body = seg.substring(0, seg.indexOf('if (partial.isNotEmpty)'));
      // ⚠️ 断言要**精确到比较表达式**，不能只查"有没有 progress 这个词"
      //    —— 实测：把 `progress.compareTo` 那行删掉后，
      //    `e.progress > 1` 里仍有 `progress` ⇒ 裸词断言**仍为真**（假绿）。
      expect(body.contains('b.progress.compareTo(a.progress)'), isTrue,
          reason: '★★★ 排序必须**先按进度**降序：\n'
              '    跨季场景 `S1E5 看了 40%` vs `S2E1 看了 2%`\n'
              '    旧逻辑挑季号大的 S2E1 ⇒ Trakt「继续观看」指错集');
      // 且该比较必须在"早退"位置（进度不同就返回，不看季号）
      expect(
          RegExp(r'byP\s*=\s*b\.progress\.compareTo\(a\.progress\)')
              .hasMatch(body),
          isTrue,
          reason: '★★ 进度比较的结果必须被用于**提前返回**\n'
              '    （否则算出来不用 ⇒ 季号仍然优先）');
      expect(body.contains('if (byP != 0) return byP;'), isTrue,
          reason: '★★ 必须"进度不同就返回"，否则季号会先决定');
      // 进度的判断必须**早于**季号
      final pi = body.indexOf('b.progress.compareTo');
      final si = body.indexOf('b.season.compareTo');
      expect(pi, greaterThan(0));
      expect(si, greaterThan(0));
      expect(pi, lessThan(si),
          reason: '★★ 进度的判断必须**早于**季号（否则季度优先仍会选错）');
    });

    test('★★ 只在 1–79% 区间内选（契约：<1% 会 422、>80% 变已看）', () {
      expect(
          RegExp(r'e\.progress > 1 && e\.progress < 80').hasMatch(detail),
          isTrue,
          reason: '★ 契约 `scrobble/index.ts:50-55`：\n'
              '    <1% ⇒ 422 被忽略；>80% ⇒ 标为已看\n'
              '    ⇒ 只有 1–79% 能作为「继续观看」');
    });
  });

  group('★★ 电影分流不能回退', () {
    test('★★ `item.type == \'Movie\'` 的分流仍在（否则电影再走剧集路径 ⇒ 404）',
        () {
      expect(detail.contains("item.type == 'Movie'"), isTrue,
          reason: '★ 电影没有季/集 ⇒ 走 `getSeasons(电影id)` 必 404\n'
              '    （用户报障："生化危机爆发夜"点同步报 404）');
    });
  });
}
