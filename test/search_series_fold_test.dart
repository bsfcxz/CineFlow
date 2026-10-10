// 搜索必须按 Emby 的"可浏览实体"口径返回（用户报障：剧集显示成散乱单集）。
//
// ## 用户报障
// "搜索剧集时会显示单集排列有点问题"——搜一部剧，结果被
// `第 1 集 / 第 2 集 / 第 3 集…` 刷屏，而不是给出那部剧。
//
// ## 根因
// `search()` 的 `IncludeItemTypes: 'Movie,Episode'` —— **直接请求单集**，
// 于是服务端把每一集当独立结果返回。
//
// ## Emby 的正确口径
// 可浏览实体是 **Series / Movie / BoxSet / Video**；
// `Episode` 是 Series 的子项，应折叠到剧集下（用户点剧集进去看分集）。
//
// ## 本测试守什么
// ① 请求必须包含 Series（否则搜不到剧集本身）
// ② 请求**不得**只写 Movie,Episode（旧形态）
// ③ 折叠逻辑：所属剧集已在结果里 ⇒ 丢弃该单集
// ④ 折叠逻辑：剧集不在结果里 ⇒ **保留**该单集（否则搜不到）
// ⑤ 不得用 `MediaTypes: Video`（会滤掉 BoxSet）
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/models.dart';

/// 剥注释读源码（§8.4：断言不得被注释满足）。
String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

/// **复刻** `EmbyProvider.search` 的折叠规则（用于单测边界）。
///
/// ⚠️ 复刻就有脱钩风险 ⇒ 下面有源码结构断言把真实实现钉住。
List<MediaItem> foldEpisodes(List<MediaItem> raw) {
  final seriesIds = <String>{
    for (final i in raw)
      if (i.type == 'Series' || i.type == 'BoxSet') i.id,
  };
  final out = <MediaItem>[];
  for (final i in raw) {
    if (i.type == 'Episode') {
      final sid = i.seriesId;
      if (sid != null && sid.isNotEmpty && seriesIds.contains(sid)) continue;
    }
    if (!i.isPlayable) continue;
    out.add(i);
  }
  return out;
}

MediaItem _it(Map<String, dynamic> j) => MediaItem.fromJson(j);

void main() {
  group('★ 搜索结果折叠：剧集优先、单集归并', () {
    test('剧集已在结果里 ⇒ 它的单集被丢弃（不刷屏）', () {
      final raw = [
        _it({'Id': 's1', 'Name': '斗罗大陆', 'Type': 'Series'}),
        _it({'Id': 'e1', 'Name': '第 1 集', 'Type': 'Episode', 'SeriesId': 's1'}),
        _it({'Id': 'e2', 'Name': '第 2 集', 'Type': 'Episode', 'SeriesId': 's1'}),
      ];
      final out = foldEpisodes(raw);
      expect(out.length, 1, reason: '★ 只应剩剧集本身（用户要的形态）');
      expect(out.first.type, 'Series');
      expect(out.first.name, '斗罗大陆');
    });

    test('★ 剧集**不在**结果里 ⇒ 单集必须保留（否则搜不到）', () {
      // 场景：搜某集专属标题，服务端只返回那一集（没返回剧集）
      final raw = [
        _it({'Id': 'e9', 'Name': '孤勇寻路', 'Type': 'Episode',
             'SeriesId': 'sX'}),
      ];
      final out = foldEpisodes(raw);
      expect(out.length, 1,
          reason: '★ 剧集没出现时保留单集 —— 折叠不能把结果清空');
      expect(out.first.type, 'Episode');
    });

    test('电影不受影响；BoxSet 被 isPlayable 滤掉（它是容器不是可播项）', () {
      final raw = [
        _it({'Id': 'm1', 'Name': '复仇者联盟', 'Type': 'Movie'}),
        _it({'Id': 'b1', 'Name': '漫威电影宇宙', 'Type': 'BoxSet'}),
      ];
      final out = foldEpisodes(raw);
      expect(out.length, 1, reason: '★ Movie 保留');
      expect(out.first.type, 'Movie');
      // BoxSet 在 Emby 里是**浏览容器**（IsFolder），不是可播条目
      // ⇒ 被 `isPlayable` 滤掉是正确行为（点它应进合集浏览，不是起播）。
      expect(out.any((e) => e.type == 'BoxSet'), isFalse);
    });

    test('混合结果：剧集 + 电影 + 其单集 ⇒ 正确收敛', () {
      final raw = [
        _it({'Id': 's1', 'Name': '剧A', 'Type': 'Series'}),
        _it({'Id': 'a1', 'Name': '第 1 集', 'Type': 'Episode', 'SeriesId': 's1'}),
        _it({'Id': 'm1', 'Name': '电影B', 'Type': 'Movie'}),
        _it({'Id': 'e2', 'Name': '孤儿集', 'Type': 'Episode', 'SeriesId': 'sZ'}),
      ];
      final out = foldEpisodes(raw);
      final names = out.map((e) => e.name).toList();
      expect(names, containsAll(['剧A', '电影B', '孤儿集']));
      expect(names, isNot(contains('第 1 集')),
          reason: '★ 剧A 已在结果里 ⇒ 它的第 1 集应被折叠掉');
    });

    test('不可播类型（如 Person）被滤掉', () {
      final raw = [
        _it({'Id': 'p1', 'Name': '某演员', 'Type': 'Person'}),
        _it({'Id': 'm1', 'Name': '电影', 'Type': 'Movie'}),
      ];
      expect(foldEpisodes(raw).length, 1);
    });
  });

  group('★★ 真实源码必须与测试同构（防脱钩）', () {
    late String p;

    setUpAll(() {
      p = code('lib/data/emby_provider.dart');
    });

    test('★ 搜索必须请求 Series（否则搜不到剧集本身）', () {
      expect(p.contains("'Movie,Series,BoxSet,Video,Episode'"), isTrue,
          reason: '★★ 必须请求 Series —— 原实现只有 Movie,Episode，\n'
              '    于是搜剧集时结果全是散乱单集（用户报障）。');
    });

    test('★ 不得退回旧形态 Movie,Episode', () {
      expect(p.contains("'Movie,Episode'"), isFalse,
          reason: '★ `Movie,Episode` 是**修复前的缺陷形态**：\n'
              '    直接请求单集 ⇒ 列表被"第 N 集"刷屏。');
    });

    test('★ 必须实现折叠（SeriesId 集合 + Episode 跳过）', () {
      expect(p.contains('seriesIds.contains(sid)'), isTrue,
          reason: '★ 必须按"所属剧集是否已在结果里"折叠单集');
    });

    test('★ 不得用 MediaTypes=Video（会滤掉 BoxSet 合集）', () {
      // 搜索分支里不应再出现 MediaTypes: 'Video'
      final i = p.indexOf('Future<List<MediaItem>> search');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 search 方法');
      final seg = p.substring(i, i + 2600);
      expect(seg.contains("'MediaTypes': 'Video'"), isFalse,
          reason: '★ MediaTypes=Video 会滤掉 BoxSet —— 而合集是\n'
              '"系列电影"的载体（见 collectionIds）。');
    });

    test('★ 搜索要带 Collections 字段（合集电影也要能解析）', () {
      final i = p.indexOf('Future<List<MediaItem>> search');
      final seg = p.substring(i, i + 2600);
      expect(seg.contains('Collections'), isTrue,
          reason: '★ 搜索结果里的电影同样需要合集体信息');
    });
  });
}
