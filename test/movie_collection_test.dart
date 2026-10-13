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
      expect(
            // 常量形态（`_listFields`）或字面量形态都算通过
            fieldsHas(p, 'Collections', viaConst: '_listFields'),
            isTrue,
          reason: '★ 列表请求的 Fields 必须带 Collections');
      expect(
            fieldsHas(p, 'Collections', viaConst: '_detailFields'),
            isTrue,
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
      expect(
            fieldsHas(p, 'Collections', viaConst: '_listFields') ||
                p.contains('DateCreated,Collections'),
            isTrue,
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

    test('★★ 详情页"立即播放"也必须走合集（真机抓到的漏修）', () {
      // ## 为什么单独守这一条（本轮真机实测抓到）
      // 上一轮只改了 `openPlayerResolved`（"继续观看"入口），
      // 而**详情页的"立即播放"仍直接 `openPlayer`** ⇒
      // "搜索 → 详情 → 立即播放"这条**主路径**上依然没有下一部。
      //
      // 真机取证：从搜索进《复仇者联盟》详情页 → 点立即播放 →
      // 底栏**无计数**（应当有，该系列 4 部都在库里）。
      final d = code('lib/pages/detail_page.dart');
      expect(d.contains('_playMovieWithCollection'), isTrue,
          reason: '★★ 详情页电影播放必须走合集解析 ——\n'
              '    "搜索→详情→立即播放"是用户找电影的主路径，\n'
              '    只修"继续观看"那条等于没修（真机实测确认）。');
      // 反向：电影分支不得再直接 openPlayer 而跳过合集
      final i = d.indexOf('void onPrimary()');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 onPrimary');
      final seg = d.substring(i, i + 900);
      expect(seg.contains('_playMovieWithCollection(item)'), isTrue,
          reason: '★ onPrimary 的电影分支必须调合集解析');
    });

    test('★★ 详情页保留 mediaSourceId（多版本选择不能丢）', () {
      // 走合集的同时**必须**带上版本选择，否则"切了版本播的还是默认版本"。
      //
      // ⚠️ 不能只断言"方法里出现过 mediaSourceId" ——
      //    该方法有 **4 个** openPlayer 调用点（主分支 + 3 个降级），
      //    只改其中一个仍会满足裸 contains（§8.4 第 2 条：同一串出现多处）。
      //    ⇒ 断言**出现次数**必须等于调用点数量。
      final d = code('lib/pages/detail_page.dart');
      final i = d.indexOf('_playMovieWithCollection(MediaItem item)');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到该方法');
      final seg = d.substring(i, i + 2200);
      final openCalls = RegExp(r'openPlayer\(').allMatches(seg).length;
      final withSource =
          RegExp(r'mediaSourceId: _selectedVersionId').allMatches(seg).length;
      expect(openCalls, greaterThanOrEqualTo(2),
          reason: '该方法应有"主分支 + 降级分支"多个调用点');
      expect(withSource, openCalls,
          reason: '★★ 每个 openPlayer 调用点都要带 mediaSourceId ——\n'
              '    只改一个仍满足裸 contains（同串多处，§8.4）。\n'
              '    实测: $openCalls 个调用点，$withSource 个带参数。');
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


/// **Fields 是否含某字段** —— 同时支持两种写法。
///
/// ## 为什么需要（本轮重构引发）
/// `emby_provider.dart` 的 `Fields` 从**就地字面量**提成了具名常量
/// （`_listFields` / `_detailFields`，见那里的注释：这个串已栽 4 次）。
/// 而本文件的断言原本只认字面量 ⇒ 重构后全部变红。
///
/// ## 为什么不能删断言
/// 这些断言防的是"有人把 `Collections` 从 Fields 里去掉"——
/// 删了就失去保护。⇒ 改成**两种形态都认**。
///
/// ## 判据
/// · 字面量形态：源码里直接出现 `needle`
/// · 常量形态：源码里出现了常量名，**且常量定义里含 `needle`**
///   （在 `_listFields = ...` / `_detailFields = ...` 的赋值块内）
bool fieldsHas(String src, String needle, {String? viaConst}) {
  if (src.contains(needle)) return true;
  if (viaConst == null) return false;
  final i = src.indexOf(viaConst);
  if (i < 0) return false;
  // 常量定义块：从常量名往后 400 字符（足够覆盖多行拼接的串）
  final block = src.substring(i, (i + 400).clamp(0, src.length));
  return block.contains(needle);
}
