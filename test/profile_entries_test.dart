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

  group('★★ 入口顺序与增删（用户要求）', () {
    test('★★★ 「继续观看」必须**已从我的页移除**（用户 2026-10-11）', () {
      // 它已移到「追剧」Tab 的第二个分页（与"追剧日历"并列）。
      // 同一内容两处入口会让用户困惑"哪个才是我要看的"。
      final c = code('lib/pages/profile_page.dart');
      expect(c.contains("title: '继续观看'"), isFalse,
          reason: '★★★ 用户："删除继续观看"');
      // ⚠️ `HistoryPage` 仍在（被「追剧」Tab 复用），只是不从这里进
      final t = code('lib/pages/tracking_page.dart');
      expect(t.contains('HistoryPage'), isTrue,
          reason: '★ 它被追剧 Tab 复用，不能一起删');
    });

    test('★★★ 「服务端播放列表」必须**已移除**（用户 2026-10-11）', () {
      final c = code('lib/pages/profile_page.dart');
      expect(c.contains("title: '服务端播放列表'"), isFalse,
          reason: '★★★ 用户："删除服务端播放列表"');
      expect(c.contains('getPlaylists'), isFalse,
          reason: '★ 入口没了就不该再调它');
    });

    test('★★★ 统计四格必须**已移除**（用户 2026-10-11）', () {
      // 用户："删除我的底栏内容中的已看电影、追剧中、已看分集、收藏"
      final c = code('lib/pages/profile_page.dart');
      for (final label in ['已看电影', '追剧中', '已看分集', '收藏']) {
        expect(c.contains("'$label'"), isFalse,
            reason: '★★★ 统计卡「$label」必须已删');
      }
      // 三个只服务四格的方法也要删（死代码比没有更贵）
      for (final m in ['_statGrid', '_statCard', '_openList']) {
        expect(c.contains(m), isFalse,
            reason: '★★ $m 只服务那四格，留着是死代码');
      }
      // ⚠️ statsProvider 保留（_headCard 用它的库规模数字）
      expect(c.contains('statsProvider'), isTrue,
          reason: '★ 库规模数字（电影/剧集总数）仍在用');
    });

    test('★★★ 「制片公司」必须**已移除**（用户要求）', () {
      // ## 用户原话（2026-10-11）
      // > "去除我的中的制片公司"
      //
      // ⚠️ 断言的是**入口不存在**，而不是"底层能力不存在" ——
      //    `getStudios` / `getStudioItems` 要保留，只是不再从「我的」进入。
      final c = code('lib/pages/profile_page.dart');
      expect(c.contains("title: '制片公司'"), isFalse,
          reason: '★★★ 用户明确要求移除该入口');
      expect(c.contains('Icons.apartment_rounded'), isFalse,
          reason: '★ 图标也不该留着（死代码）');
    });

    test('★★ 标题必须叫「继续观看」（不是「播放历史」）—— 在追剧 Tab 里', () {
      // ⚠️ 入口已从「我的」页移除（用户 2026-10-11），
      //    但**页面标题**仍要是「继续观看」—— 它在追剧 Tab 的分页里。
      final t = File('lib/pages/history_page.dart').readAsStringSync();
      expect(t.contains("const Text('继续观看',"), isTrue,
          reason: '★★ 用户："播放历史对应的内容应该是继续观看内容"\n'
              '    ⇒ 名字也要跟着改，否则与数据源不符');
      // 不能再出现播放历史这个旧名
      expect(t.contains("'播放历史'"), isFalse,
          reason: '★★ 旧名会与数据源不符（IsPlayed ≠ Resume）');
    });
  });

  group('★★★ 详情页：收藏 → 追剧（用户要求）', () {
    test('★★★ 「已看」（小眼睛）按钮必须**已移除**', () {
      // 用户原话："去除右侧的已看按钮 就是这个小眼睛"
      final c = code('lib/pages/detail_page.dart');
      expect(c.contains('Icons.visibility_rounded'), isFalse,
          reason: '★★★ 用户明确要求移除');
      expect(c.contains('Icons.visibility_outlined'), isFalse);
      // ⚠️ 底层能力保留（`MediaProvider.togglePlayed` 仍在），
      //    只是详情页不再调它
      expect(c.contains('togglePlayed('), isFalse,
          reason: '★ 按钮没了就不该再调它');
    });

    test('★★★ 收藏按钮必须改成「追剧」', () {
      final c = code('lib/pages/detail_page.dart');
      // 用户："你将我从 emby 服务端中 api 的收藏按钮改为追剧"
      expect(c.contains('_following'), isTrue,
          reason: '★★★ 要有"是否已追"状态');
      expect(c.contains('toggleCalendarSubscription('), isTrue,
          reason: '★★★ 点击写**本地订阅**（不再是 Emby 收藏）');
      // ★ 用户 2026-10-11（追加要求）：
      //   "我点的详情页的追剧小星星如果在服务端的库内存在的应该同步进去"
      //   ⇒ 订阅时**同时**写 Emby 收藏（这样换设备/网页端也能看到）
      //   ⇒ 所以 `toggleFavorite` **是有意保留**的，不能断言它不存在。
      expect(c.contains('toggleFavorite('), isTrue,
          reason: '★★★ 追剧要同步到服务端库（用户明确要求）');
      // 但要确认它**不是**主行为（主行为是本地订阅）
      expect(c.contains('toggleCalendarSubscription('), isTrue,
          reason: '★★★ 主行为仍是本地订阅');
      // 顺序：先本地订阅，再同步服务端（本地成功才算追剧成功）
      final iLocal = c.indexOf('toggleCalendarSubscription(');
      final iServer = c.indexOf('toggleFavorite(');
      expect(iLocal, lessThan(iServer),
          reason: '★★ 先写本地（主行为），再同步服务端 ——\n'
              '    否则服务端失败会导致本地也没订上');
    });

    test('★★★ 追剧状态 = 本地订阅 ∪ Emby 收藏（并集）', () {
      final c = code('lib/pages/detail_page.dart');
      // 用户："追剧日历中的订阅**也包括** emby 服务端的收藏"
      // ⇒ 已在 Emby 收藏的剧必须也显示"已追"，否则用户以为数据丢了
      expect(c.contains('_following = item.isFavorite'), isTrue,
          reason: '★★★ Emby 收藏那一路不能丢');
      expect(c.contains('_syncLocalSubscription('), isTrue,
          reason: '★★★ 本地订阅那一路也要叠加');
    });

    test('★★ 详情页订阅要按"有无 tmdb id"分别落键', () {
      final c = code('lib/pages/detail_page.dart');
      // 实测：Emby 条目 87–100% 有 tmdb id
      // 有 ⇒ 用 tmdb 作 sourceId（与日历订阅同一条）
      // 无 ⇒ 退回 emby id（仍可订阅，只是跨源身份弱）
      expect(c.contains("'tmdb' : 'emby'"), isTrue,
          reason: '★★ 两种来源要分开（不编造 id）');
    });
  });
}
