// 第一批 + 第二批 Emby API 扩展的守卫测试。
//
// ## 本文件守什么
// 这些功能**全部依赖"端点写对了"**，而端点错了的表现是
// "数据永远为空"——**不报错、不崩溃**（本仓库已栽过：
// track-list 格式不对导致面板空白、`Collections` 字段没请求导致
// 电影没有下一部）。故必须用源码断言把**端点与参数**钉住。
//
// ## 依据来源（不是猜的）
// Emby 官方 Go SDK `MediaBrowser/Emby.ApiClients` 的 `Clients/Go/api_*.go`
// 里的 `localVarPath` 与 `*Opts` 字段（AGENTS §10.6 白名单）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥注释读源码（§8.4 第 1 条：断言不得被注释满足）。
String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

void main() {
  late String prov;
  late String mp;

  setUpAll(() {
    prov = code('lib/data/emby_provider.dart');
    mp = code('lib/data/media_provider.dart');
  });

  group('★ 第一批① 演职员作品（/Persons/{Id}/Credits）', () {
    test('端点与参数正确', () {
      expect(prov.contains("'/Persons/\$personId/Credits'"), isTrue,
          reason: '★ 依据官方 SDK api_persons_service.go 的 localVarPath');
      // 带 UserId：作品列表要显示"已看/看到 N%"
      expect(prov.contains("'UserId': session.user.id,"), isTrue);
    });

    test('★ 详情页演员必须可点（原来是死区）', () {
      final d = code('lib/pages/detail_page.dart');
      expect(d.contains('PersonCreditsPage('), isTrue,
          reason: '★ 演员头像原来只是 SizedBox（点了没反应），'
              '必须导航到作品页');
      expect(d.contains('onTap: () => Navigator.of(context).push'), isTrue);
    });

    test('★ 用 InkWell 而不是裸 GestureDetector（命中区与反馈）', () {
      final d = code('lib/pages/detail_page.dart');
      final i = d.indexOf('PersonCreditsPage(');
      expect(i, greaterThan(0));
      // 往前找包裹的手势
      final ctx = d.substring((i - 400).clamp(0, i), i);
      expect(ctx.contains('InkWell('), isTrue,
          reason: '★ 裸 GestureDetector 无按压反馈，本仓库已有 5 处教训');
    });
  });

  group('★ 第一批② 预告片（LocalTrailers）', () {
    test('端点正确且是 Local（能被播放器播）', () {
      expect(prov.contains('/LocalTrailers'), isTrue,
          reason: '★ 依据官方 SDK api_user_library_service.go');
      expect(prov.contains('/RemoteTrailers'), isFalse,
          reason: '★ Remote 是外部链接，本项目播放器不为它服务');
    });

    test('★ 没有预告时按钮不显示（避免死按钮）', () {
      final t = code('lib/widgets/trailer_button.dart');
      expect(t.contains('if (!_loaded || _trailers.isEmpty)'), isTrue,
          reason: '★ 剧集通常没有预告 —— 常显会挂一个永远点不动的图标');
      expect(t.contains('SizedBox.shrink()'), isTrue);
    });

    test('★ 预告按独立条目播放（不传 episodes）', () {
      final t = code('lib/widgets/trailer_button.dart');
      expect(t.contains('openPlayer(context, t)'), isTrue,
          reason: '★ 预告是独立短片，不继承主片的选集上下文');
    });
  });

  group('★ 第一批③ 相似推荐（/Movies/Recommendations）', () {
    test('端点正确', () {
      expect(prov.contains("'/Movies/Recommendations'"), isTrue,
          reason: '★ 依据官方 SDK api_movies_service.go');
      expect(prov.contains("'/Items/\$itemId/Similar'"), isFalse,
          reason: '★ 旧的 /Similar 只给平铺列表，服务端的分类信息被丢掉');
    });

    test('★ 必须兼容两种返回形状（分组数组 / 平铺）', () {
      final i = prov.indexOf('getSimilar');
      final seg = prov.substring(i, i + 2400);
      expect(seg.contains('if (d is List)'), isTrue,
          reason: '★ 官方形状是分组数组 [{RecommendationType, Items}]');
      expect(seg.contains('else if (d is Map'), isTrue,
          reason: '★ 平铺形状也要吃（不同版本可能不同）');
    });

    test('★ 要按 id 去重（分组之间会重复推荐同一部）', () {
      final i = prov.indexOf('getSimilar');
      final seg = prov.substring(i, i + 2400);
      expect(seg.contains('seen.add('), isTrue);
    });
  });

  group('★★ 第一批④ 搜索历史（服务端只有写入侧）', () {
    test('★ 上报端点正确', () {
      expect(prov.contains('/SearchedItems/'), isTrue,
          reason: '★ 依据官方 SDK api_user_library_service.go（POST）');
    });

    test('★ 清空端点正确', () {
      expect(prov.contains('/RecentlySearched/Delete'), isTrue,
          reason: '★ 依据官方 SDK api_user_service.go');
    });

    test('★★ 不得实现"读取服务端历史"（该端点不存在）', () {
      // 全 SDK 410 文件核实：含 Searched 的端点只有
      //   POST   /Users/{uid}/SearchedItems/        ← 上报
      //   DELETE /Users/{uid}/RecentlySearched      ← 清空
      //   POST   /Users/{uid}/RecentlySearched/Delete ← 清空
      // **没有 GET** ⇒ 编一个会得到"历史永远为空"的假实现。
      expect(prov.contains('getRecentlySearched'), isFalse,
          reason: '★★ Emby 没有 GET 搜索历史的端点 ——\n'
              '    实现读取会得到永远为空的"假功能"。\n'
              '    读取必须继续用本地 SessionStore.loadSearchHistory。');
      expect(mp.contains('getRecentlySearched'), isFalse);
    });

    test('★ 搜索时必须上报（写入侧才有效）', () {
      final s = code('lib/pages/search_page.dart');
      expect(s.contains('reportSearched('), isTrue,
          reason: '★ 只写本地 ⇒ 服务端无记录 ⇒ 与官方客户端不一致');
    });

    test('★ 清空历史必须同时清服务端（隐私预期）', () {
      final s = code('lib/pages/search_page.dart');
      expect(s.contains('clearRemoteSearchHistory()'), isTrue,
          reason: '★ 只清本地 ⇒ 记录仍在服务端（官方客户端照样看到）');
    });
  });

  group('★ 第二批⑤ 制片公司（/Studios）', () {
    test('端点正确', () {
      expect(prov.contains("_dio.get('/Studios'"), isTrue,
          reason: '★ 依据官方 SDK api_studios_service.go');
    });

    test('★ 公司**不能**被 isPlayable 过滤（它是容器）', () {
      final i = prov.indexOf('getStudios');
      final seg = prov.substring(i, i + 900);
      expect(seg.contains('isPlayable'), isFalse,
          reason: '★ Studio 不在 isPlayable 白名单 ⇒ 过滤会把结果清空');
    });

    test('★ 公司作品用 Items 的 Studios 参数', () {
      expect(prov.contains("'Studios': studioName"), isTrue,
          reason: '★ 依据官方 SDK api_items_service.go 的 GetItemsOpts.Studios');
    });
  });

  group('★ 第二批⑥ 服务端播放列表（/Playlists）', () {
    test('端点正确且不带 /Users 前缀', () {
      expect(prov.contains("_dio.get('/Playlists'"), isTrue,
          reason: '★ 依据官方 SDK api_playlist_service.go');
      // 播放列表是服务端级资源，不是用户级
      expect(prov.contains("'/Users/\${session.user.id}/Playlists'"), isFalse,
          reason: '★ 带 /Users 前缀会 404（与 /Collections 同类结论）');
    });

    test('成员端点正确', () {
      expect(prov.contains("'/Playlists/\$playlistId/Items'"), isTrue);
    });
  });

  group('★ 第二批⑦ 追剧日历（/Shows/Upcoming）', () {
    test('端点正确', () {
      expect(prov.contains("_dio.get('/Shows/Upcoming'"), isTrue,
          reason: '★ 依据官方 SDK api_tv_shows_service.go');
    });

    test('★ 日期必须带时区（否则偏一天）', () {
      // ⚠️ 用 indexOf 取"第一个 getUpcoming"会命中别处（如注释/接口声明）
      //    ⇒ 断言不能依赖位置，直接断言"存在 toUtc 链式调用"。
      //    这正是 §8.4 说的"断言要落在必然会变的那一行"。
      expect(prov.contains('DateTime.now().toUtc().add('), isTrue,
          reason: '★ 服务端按 UTC 解读 —— 裸本地时间会偏一整天');
      expect(prov.contains('until.toIso8601String()'), isTrue,
          reason: '★ ISO8601 才被服务端接受');
    });

    test('★ 与 NextUp 是两个概念（别混用）', () {
      // NextUp = 已入库的"下一集"；Upcoming = 未来的日历。
      // 两者端点不同，若有人"顺手统一"会把追剧日历变成重复的下一集。
      expect(prov.contains("'/Shows/NextUp'"), isTrue,
          reason: '★ NextUp 应仍然存在（评分推荐用它）');
      expect(prov.contains("'/Shows/Upcoming'"), isTrue);
    });
  });
}
