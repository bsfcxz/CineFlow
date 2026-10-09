// 电影合集（BoxSet）："同系列其他部"的解析与链路守卫。
//
// ## 用户报障
// "当我观看复仇者联盟时，列表并没有显示它的下一部。没有列出它的部数。"
//
// ## 根因
// 电影不是 Episode（没有 `seriesId`）⇒ 走 `openPlayerResolved` 的
// "非剧集 → 直接播"分支 ⇒ 播放器认为只有这一条 ⇒ 列表空。
// 而漫威这类系列在 Emby 里是 **BoxSet（合集）** —— 唯一的兄弟片来源。
//
// ## 字段名的坑（本测试要钉死）
// Emby 用 **`Collections`**（`[]NameLongIdPair`），
// **不是** Jellyfin 的 `BoxSetIds`。
// 依据：Emby 官方 Go SDK `Clients/Go/model_base_item_dto.go`：
//     Collections  []NameLongIdPair  `json:"Collections,omitempty"`
// 照 Jellyfin 写会**永远拿到 null**，且不报错 —— 正是"静默失效"的形态。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/models.dart';

/// 剥注释后读源码（§8.4：断言不得被注释满足）。
String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

void main() {
  group('★ MediaItem.collectionIds 解析', () {
    test('Emby 形状：Collections 是 [{Name, Id}] 对象数组', () {
      // 官方 SDK：[]NameLongIdPair
      final j = jsonDecode('''
        {"Id":"m1","Name":"复仇者联盟","Type":"Movie",
         "Collections":[{"Name":"漫威电影宇宙","Id":"box1"}]}
      ''') as Map<String, dynamic>;
      final item = MediaItem.fromJson(j);
      expect(item.collectionIds, ['box1'],
          reason: '★ 必须从 Collections[].Id 取到合集 id');
    });

    test('多个合集都要拿到（一部片可属于多个合集）', () {
      final j = jsonDecode('''
        {"Id":"m1","Name":"x","Type":"Movie",
         "Collections":[{"Name":"A","Id":"boxA"},{"Name":"B","Id":"boxB"}]}
      ''') as Map<String, dynamic>;
      expect(MediaItem.fromJson(j).collectionIds, ['boxA', 'boxB']);
    });

    test('字段缺失 ⇒ 空列表（不抛、不崩）', () {
      final j = jsonDecode('{"Id":"m1","Name":"x","Type":"Movie"}')
          as Map<String, dynamic>;
      expect(MediaItem.fromJson(j).collectionIds, isEmpty);
    });

    test('形状异常也要容错（空 Id / null 元素 / 字符串形态）', () {
      final j = jsonDecode('''
        {"Id":"m1","Name":"x","Type":"Movie",
         "Collections":[{"Name":"空Id","Id":""},{"Name":"无Id"},null,"rawId"]}
      ''') as Map<String, dynamic>;
      // 空 Id 与无 Id 被滤掉；字符串形态容错保留
      expect(MediaItem.fromJson(j).collectionIds, ['rawId']);
    });
  });

  group('★★ 真实源码必须与测试同构（防脱钩）', () {
    test('★ 字段名必须是 Emby 的 Collections（不是 BoxSetIds）', () {
      final m = code('lib/data/models.dart');
      expect(m.contains("j['Collections']"), isTrue,
          reason: '★★ Emby 的合集字段是 `Collections`；\n'
              '    Jellyfin 才叫 `BoxSetIds` —— 写错会永远拿到 null 且不报错。\n'
              '    依据：官方 Go SDK model_base_item_dto.go。');
      expect(m.contains("j['BoxSetIds']"), isFalse,
          reason: '★ 不得用 Jellyfin 的字段名（Emby 不返回它）');
    });

    test('★ 请求必须显式要 Collections 字段（否则服务端不返回）', () {
      final p = code('lib/data/emby_provider.dart');
      expect(p.contains('CommunityRating,UserData,Collections'), isTrue,
          reason: '★ 列表请求的 Fields 必须带 Collections');
      expect(p.contains('CommunityRating,Collections'), isTrue,
          reason: '★ 详情请求的 Fields 必须带 Collections');
    });

    test('★★ "继续观看"必须带 Collections（真机主入口，最容易漏）', () {
      // ## 为什么单独守这一条（本轮真实踩到）
      // 我先只补了 `getItems` / `getItemDetail`，以为够了 —— 但
      // **"继续观看"（`getResume`）才是用户点进电影的主入口**
      // （真机截图确认：从首页"继续观看"卡片进的播放器）。
      // 那条路径不带 `Collections` ⇒ 合集分支只能降级成单条播放 ⇒
      // **"列表没有下一部"在真实使用路径上依然复现** ——
      // 修了但没修全，且单测全绿（因为单测不经过真机入口）。
      final p = code('lib/data/emby_provider.dart');
      expect(p.contains('BasicSyncInfo,Collections'), isTrue,
          reason: '★★ getResume 的 Fields 必须带 Collections ——\n'
              '    "继续观看"是电影的主要播放入口（home_page.dart:76 调 '
              'openPlayerResolved）。漏了这里 = 修了但没修全。');
    });

    test('★ "最近添加/轮播"也要带（同一类入口）', () {
      final p = code('lib/data/emby_provider.dart');
      expect(p.contains('DateCreated,Collections'), isTrue,
          reason: '★ getLatest 的 Fields 同样要带 Collections');
    });

    test('★ 端点必须是官方 /Collections/{Id}/Items', () {
      final p = code('lib/data/emby_provider.dart');
      expect(p.contains("'/Collections/\$collectionId/Items'"), isTrue,
          reason: '★★ 依据官方 Go SDK api_collection_service.go：\n'
              '    localVarPath = BasePath + "/Collections/{Id}/Items"');
    });

    test('★ 电影必须走合集解析（不能再"直接播"）', () {
      final o = code('lib/pages/open_player_resolved.dart');
      expect(o.contains('getCollectionItems'), isTrue,
          reason: '★ 电影分支必须尝试取合集成员 —— 否则"没有下一部"');
      expect(o.contains('episodes: siblings'), isTrue,
          reason: '★ 必须把合集成员作为播放列表传给播放器（否则列表仍空）');
    });

    test('★ 无合集时优雅降级（仍能单条播放）', () {
      final o = code('lib/pages/open_player_resolved.dart');
      // 至少两处 openPlayer(context, item) 兜底（无合集 / 取失败）
      final n = RegExp(r'openPlayer\(context, item\)').allMatches(o).length;
      expect(n, greaterThanOrEqualTo(2),
          reason: '★ 不能在"没有合集"或"取合集失败"时打不开电影');
    });
  });
}
