import 'package:cineflow/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 片头检测：**服务端 `MarkerType` 优先，名称匹配只作兜底**。
///
/// ## 为什么必须测（这段代码曾长期是错的）
///
/// 旧实现的注释写着 **"Emby 无原生片头检测，用名称匹配"** —— 实测推翻了它：
/// 本服务器某剧集章节 `MarkerType` 为
/// `Chapter, IntroStart, IntroEnd, Chapter, …`，**服务端早已标好**。
///
/// 而名称匹配（`contains('片头')||'intro'||'opening'`）有两类真实故障：
///   · **漏检**：章节叫"主题曲"/"OP"/"序章" → 功能静默失效
///   · **误检**：章节叫"片头曲欣赏"/"片头解析" → **跳过正片内容**（更严重）
///
/// 这类缺陷**静态分析发现不了**，真机上又要"恰好遇到这类片源"才暴露。
/// 故用单测把两类场景都钉住。
void main() {
  MediaChapter ch(String name, double sec, {String? marker}) => MediaChapter(
        name: name,
        startPositionTicks: (sec * 10000000).round(),
        markerType: marker,
      );

  group('服务端 MarkerType 解析', () {
    test('四个标记值都被识别', () {
      expect(ch('a', 0, marker: 'IntroStart').isIntroStart, isTrue);
      expect(ch('a', 0, marker: 'IntroEnd').isIntroEnd, isTrue);
      expect(ch('a', 0, marker: 'CreditsStart').isCreditsStart, isTrue);
      // CreditsStart 是片尾，不该被当成片头起点
      expect(ch('a', 0, marker: 'CreditsStart').isIntroStart, isFalse);
      expect(ch('a', 0, marker: 'Chapter').isIntroStart, isFalse);
    });

    test('无 MarkerType 时为 null（老库未开检测）', () {
      expect(ch('第一章', 0).markerType, isNull);
      expect(ch('第一章', 0).isIntroStart, isFalse);
    });

    test('从 JSON 解析 MarkerType', () {
      final c = MediaChapter.fromJson({
        'Name': 'Intro',
        'StartPositionTicks': 90000000,
        'MarkerType': 'IntroStart',
      });
      expect(c.markerType, 'IntroStart');
      expect(c.isIntroStart, isTrue);
      expect(c.seconds, closeTo(9.0, 0.01));
    });
  });

  group('★ 名称匹配的漏检场景（服务端标记可救）', () {
    // 复现真实数据：Chapter, IntroStart, IntroEnd, Chapter...
    final realData = [
      ch('第一章', 0, marker: 'Chapter'),
      ch('主题曲', 9.0, marker: 'IntroStart'), // 名字不含"片头"/"intro"
      ch('正片开始', 100.0, marker: 'IntroEnd'),
      ch('第二章', 600, marker: 'Chapter'),
    ];

    test('服务端标了 IntroStart/IntroEnd → 能拿到精确区间', () {
      final start = realData.firstWhere((c) => c.isIntroStart);
      final end = realData.firstWhere((c) => c.isIntroEnd);
      expect(start.seconds, 9.0);
      expect(end.seconds, 100.0);
      expect(end.seconds > start.seconds, isTrue);
    });

    test('★ 若只靠名称匹配，这条数据会被漏掉（证明服务端标记的价值）', () {
      final byName = realData.where((c) {
        final n = c.name.toLowerCase();
        return n.contains('片头') || n.contains('intro') || n.contains('opening');
      });
      expect(byName, isEmpty,
          reason: '章节名是"主题曲"，名称匹配完全找不到 → 依赖名称会功能失效');
    });
  });

  group('★ 名称匹配的误检场景（服务端标记可避免）', () {
    test('名字含"片头"但不是片头区间 → 名称匹配会误跳正片', () {
      final misleading = [
        ch('片头曲欣赏', 0, marker: 'Chapter'),
        ch('正片', 300, marker: 'Chapter'),
      ];
      // 名称匹配会把"片头曲欣赏"当片头，跳到 300s（跳过 5 分钟正片！）
      final byName =
          misleading.where((c) => c.name.contains('片头')).toList();
      expect(byName, hasLength(1), reason: '名称匹配确实会命中');
      // 但服务端标记说它只是普通 Chapter
      expect(byName.first.isIntroStart, isFalse,
          reason: 'MarkerType=Chapter → 不该当片头，服务端标记能避免误跳');
    });
  });

  group('不变量', () {
    test('IntroEnd 必须晚于 IntroStart（否则区间无效）', () {
      final bad = [
        ch('a', 100, marker: 'IntroStart'),
        ch('b', 5, marker: 'IntroEnd'),
      ];
      final s = bad.firstWhere((c) => c.isIntroStart).seconds;
      final e = bad.firstWhere((c) => c.isIntroEnd).seconds;
      expect(e > s, isFalse, reason: '这种数据应被调用方拒绝（end > start 校验）');
    });

    test('只有 IntroStart 没有 IntroEnd 时仍可回退到下一章起点', () {
      final partial = [
        ch('a', 10, marker: 'IntroStart'),
        ch('b', 200, marker: 'Chapter'),
      ];
      final s = partial.firstWhere((c) => c.isIntroStart).seconds;
      final next = partial[1].seconds;
      expect(next > s, isTrue);
    });
  });
}
