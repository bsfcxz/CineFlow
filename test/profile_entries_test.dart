// 「我的」页的 4 组用户报障 —— 守卫测试。
//
// ## 用户原话
// > "播放历史对应的内容应该是 emby 服务端的继续观看内容，你识别有问题，
// >  收藏对应的也是 emby 服务端的收藏，而且在 cineflow 中点收藏和已观看后
// >  好像没有保留在我的中里面，已看电影可以、追剧中、已看分级、收藏都应该
// >  可以点击且能看到具体内容，将下面的播放历史移动到收藏后面，
// >  点击服务端的地址可以测试延迟。多账号聚合地址和内容没增加进去。查看一下。"
//
// ## 为什么这些必须由测试守（单测测不出"看起来没生效"）
// 我已经实测确认：**服务端写入是成功的**（`POST FavoriteItems` 后
// `IsFavorite=True`，读-写闭环通过）。所以这**不是服务端问题**，
// 是客户端"数据刷新"与"入口指向"的问题 —— 这类问题**不报错**，
// 只能靠断言代码形状来防回归。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉注释（§8.4：断言不得被注释满足）。
String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

void main() {
  group('★★★ 继续观看：必须用 Resume（不是 IsPlayed）', () {
    test('★★★ history_page 必须走 getResume（服务端续播列表）', () {
      final c = code('lib/pages/history_page.dart');
      // ## 用户报障："播放历史对应的内容应该是 emby 服务端的继续观看内容"
      //
      // 旧实现：`filters: 'IsPlayed'` —— 那是「**已看完**」，
      // 与"继续观看"是两个概念（看完的点进去从头播没意义）。
      //
      // 实测（两台真实服务器）：
      //   /Users/{uid}/Items/Resume → 200，12 条（带 PlayedPercentage）
      //   /Items/Resume?userId=     → **404**（必须走 /Users/{uid}/ 前缀）
      expect(c.contains('getResume('), isTrue,
          reason: '★★★ 必须用 Resume 端点（服务端"继续观看"）');
      expect(c.contains("filters: 'IsPlayed'"), isFalse,
          reason: '★★★ IsPlayed = 已看完，不是"继续观看" ——\n'
              '    这正是用户报的"你识别有问题"');
    });

    test('★★ getResume 必须走 /Users/{uid}/Items/Resume（404 陷阱）', () {
      final c = code('lib/data/emby_provider.dart');
      // 实测：`/Items/Resume?userId=` → HTTP 404
      //       `/Users/{uid}/Items/Resume` → HTTP 200
      expect(c.contains("'/Users/\${session.user.id}/Items/Resume'"), isTrue,
          reason: '★★ 实测 `/Items/Resume` 会 404');
      expect(c.contains("'/Items/Resume'"), isFalse,
          reason: '★★ 不能省略 /Users/{uid} 前缀');
    });

    test('★★ 必须限制 MediaTypes=Video（否则混入音频/图片）', () {
      final c = code('lib/data/emby_provider.dart');
      expect(c.contains("'MediaTypes': 'Video'"), isTrue,
          reason: '★★ 不限制会在"继续观看"里出现歌单封面');
    });
  });

  group('★★★ 统计卡必须可点（4 张都能看内容）', () {
    test('★★★ 四张卡都要有 onTap（**四张**，不是"至少一张"）', () {
      final c = code('lib/pages/profile_page.dart');
      // 用户："已看电影可以、追剧中、已看分级、收藏都应该可以点击且能看到具体内容"
      //
      // 每张卡对应一个服务端查询（全部实测验证）：
      //   已看电影 → Movie + IsPlayed         (s2: 11 条)
      //   追剧中   → Series + IsUnplayed      (s2: 5322)
      //   已看分集 → Episode + IsPlayed       (s2: 916)
      //   收藏     → Movie,Series,Episode + IsFavorite (s2: 2 条)
      for (final label in ['已看电影', '追剧中', '已看分集', '收藏']) {
        expect(c.contains("'$label',"), isTrue, reason: '★ 缺卡片 $label');
      }
      // ⚠️ 反向注入发现：只断言 `contains('onTap: () => _openList(')` 是**假守卫**
      //    —— 4 张卡里**任意一张**还在就通过（注入时命中 4 处，无法只改一张）。
      //    ⇒ 必须断言**出现次数 = 4**（每张卡各一次）。
      final n = 'onTap: () => _openList('.allMatches(c).length;
      expect(n, 4,
          reason: '★★★ 必须**四张卡都可点**（实测 $n 处 onTap）；\n'
              '    只断言 "contains" 时改掉 3 张仍会通过 —— 假守卫');
      expect(c.contains('void _openList('), isTrue);
    });

    test('★★★ 每个列表 loader 的 Filter 必须与卡片语义**一一对应**', () {
      final c = code('lib/pages/profile_page.dart');
      // ## 实测（本轮，两台真实服务器）：Filters 参数**确实生效**
      //   s1: Movie+IsPlayed 2 / 2754
      //   s2: Movie+IsPlayed 11 / 11126，Series+IsUnplayed 5322，Favorite 2
      //
      // ## ⚠️ 反向注入发现的**假守卫**
      // 原来只断言 `contains("filters: 'IsFavorite'")` —— 把**收藏卡**的
      // filter 改成 `IsPlayed` 后测试**仍然全绿**，因为
      // `statsProvider`（统计数字的查询）里还有一处 `IsFavorite` 满足了断言。
      // ⇒ 必须断言**具体 loader** 的组合（`includeTypes` + `filters` 成对出现）。
      const pairs = [
        ("includeTypes: 'Movie',\n              filters: 'IsPlayed',",
         '已看电影'),
        ("includeTypes: 'Series',\n              filters: 'IsUnplayed',",
         '追剧中'),
        ("includeTypes: 'Episode',\n              filters: 'IsPlayed',",
         '已看分集'),
        ("includeTypes: 'Movie,Series,Episode',\n              filters: 'IsFavorite',",
         '收藏'),
      ];
      for (final (needle, card) in pairs) {
        expect(c.contains(needle), isTrue,
            reason: '★★★ 卡片「$card」的 includeTypes 与 filters 必须成对正确\n'
                '    （只断言单个 filter 会被别处的同名 filter 满足 —— 假守卫）');
      }
    });
  });

  group('★★★ 服务端地址可点测延迟', () {
    test('★★★ 地址必须是可点组件（不是纯 Text）', () {
      final c = code('lib/pages/profile_page.dart');
      expect(c.contains('_AddressChip('), isTrue,
          reason: '★★★ 用户："点击服务端的地址可以测试延迟"');
      expect(c.contains('onTap: session == null'), isTrue);
    });

    test('★★★ 延迟测试必须用 /System/Info/Public（/Users/Me 是 500）', () {
      final c = code('lib/pages/profile_page.dart');
      // ## 实测（关键：选错端点会更糟）
      //   /System/Info/Public → ✅ HTTP 200（s1: 536ms / s2: 53ms）
      //   /Users/Me           → ❌ HTTP **500** ← 不能用它测延迟
      //
      // 且 `/System/Info/Public` **不需要 token** ⇒ 能区分
      // "服务器不可达" 与 "登录态过期" 两种情况。
      expect(c.contains('/System/Info/Public'), isTrue,
          reason: '★★★ 实测唯一可靠的测速端点');
      expect(c.contains('/Users/Me'), isFalse,
          reason: '★★★ /Users/Me 实测返回 500，不能用来测延迟');
    });

    test('★★★ 延迟结果必须**就地显示**（不是 3 秒就消失的 SnackBar）', () {
      final c = code('lib/pages/profile_page.dart');
      // ## 为什么改（两个理由，第二个是关键）
      // ① UX：延迟是**状态**，不是一次性通知 —— 用户点完想再看就没了
      // ② **可验证性**：原来的 SnackBar 只活 3 秒，而 uiautomator dump
      //    要 2–4 秒 ⇒ 我连续 4 轮真机验证都抓不到它，一直在怀疑实现。
      //    这正是 §8.4 的验证手段本身没被验证。
      // ⇒ 改成 State + 常驻文本，dump 随时能读到。
      expect(c.contains('_latencyMs'), isTrue,
          reason: '★★★ 延迟要存 State 并常驻显示');
      expect(c.contains('latencyMs: _latencyServerUrl'), isTrue);
      // 测试标签必须显示测试中…（否则用户不知道点了没反应）
      expect(c.contains("'测试中…'"), isTrue);
    });

    test('★★ 必须取多次最小值（单次含 DNS/TLS 冷启动会偏高）', () {
      final c = code('lib/pages/profile_page.dart');
      expect(c.contains('i < 3'), isTrue,
          reason: '★★ 测 3 次');
      expect(c.contains('reduce((a, b) => a < b ? a : b)'), isTrue,
          reason: '★★ 取最小值（ping 类工具的常见做法）');
    });
  });

  group('★★★ 收藏/已看后统计必须刷新（IndexedStack 陷阱）', () {
    test('★★★ 切到「我的」时必须 invalidate 统计', () {
      final c = code('lib/pages/home_shell.dart');
      // ## 用户报障："在 cineflow 中点收藏和已观看后好像没有保留在我的中里面"
      //
      // ## 根因（两条叠加，缺一不会出问题）
      // ① `IndexedStack` 让三个页面**全部常驻** ⇒ 「我的」页永不 rebuild
      // ② `statsProvider` 是 `FutureProvider.autoDispose` ⇒ 只有"没人监听"
      //    才销毁重算；而 IndexedStack 让它**一直被监听**
      // ⇒ 统计数字永远停在首次进入时的值。
      //
      // ⚠️ **服务端写入是成功的**（已实测读-写闭环：POST FavoriteItems 后
      //    IsFavorite=True）⇒ 不是服务端问题，是客户端刷新问题。
      expect(c.contains('ref.invalidate(statsProvider)'), isTrue,
          reason: '★★★ 不 invalidate ⇒ 用户以为"收藏没保留"');
      expect(c.contains('ref.invalidate(accountsProvider)'), isTrue,
          reason: '★ 账号变更也要刷新');
    });

    test('★★ statsProvider 必须公开（否则 home_shell 无法 invalidate）', () {
      final c = code('lib/pages/profile_page.dart');
      expect(c.contains('final statsProvider'), isTrue,
          reason: '★★ 私有 provider 无法被其他页面 invalidate');
    });

    test('★★ IndexedStack 必须保留（不要为了刷新改成重建）', () {
      final c = code('lib/pages/home_shell.dart');
      // IndexedStack 的"常驻"是**要保留的特性**（首页滚动位置、
      // 排行榜分组选择不该被打回初始态）⇒ 用 invalidate 而不是重建页面。
      expect(c.contains('IndexedStack'), isTrue,
          reason: '★★ 改成重建会丢失滚动位置（回归）');
    });
  });

  group('★★ 多账号聚合显示', () {
    test('★★ 必须有账号列表（>1 台时显示）', () {
      final c = code('lib/pages/profile_page.dart');
      // 用户："多账号聚合地址和内容没增加进去"
      //
      // 实测：设备上目前只有 **1 台**（`已登录 1 台`），
      // 但代码层面头部只显示 `sessionProvider`（当前会话）
      // ⇒ 登录多台时用户看不到另外几台。
      expect(c.contains('_accountList('), isTrue,
          reason: '★★ 多账号要能看到全部地址');
      expect(c.contains('accountsProvider'), isTrue);
      expect(c.contains('list.length <= 1'), isTrue,
          reason: '★ 只有 1 台时不显示（避免视觉冗余）');
    });

    test('★★ 必须高亮"当前账号"（否则分不清在用哪台）', () {
      final c = code('lib/pages/profile_page.dart');
      expect(c.contains('SessionStore.accountKey(cur)'), isTrue,
          reason: '★★ 用 accountKey 比对才能正确识别当前账号');
    });
  });

  group('★★ 入口顺序（用户要求"播放历史移动到收藏后面"）', () {
    test('★★ 「继续观看」必须在「制片公司」之前', () {
      final s = File('lib/pages/profile_page.dart').readAsStringSync();
      final iWatch = s.indexOf("title: '继续观看'");
      final iStudio = s.indexOf("title: '制片公司'");
      expect(iWatch, greaterThan(0), reason: '★ 入口必须存在');
      expect(iStudio, greaterThan(0));
      expect(iWatch, lessThan(iStudio),
          reason: '★★ 用户："将下面的播放历史移动到收藏后面"');
    });

    test('★★ 标题必须叫「继续观看」（不是「播放历史」）', () {
      final s = File('lib/pages/profile_page.dart').readAsStringSync();
      final i = s.indexOf("title: '继续观看'");
      expect(i, greaterThan(0),
          reason: '★★ 用户："播放历史对应的内容应该是继续观看内容"\n'
              '    ⇒ 名字也要跟着改，否则与数据源不符');
    });
  });
}
