import 'dart:io';

import 'package:cineflow/core/router.dart';
import 'package:cineflow/data/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 路由与会话门控的单元测试。
///
/// ## 为什么用纯函数断言而不是 pumpWidget
///
/// 会话门控原先在 `main.dart` 的 `_SessionGate` 里（一个 `session.when`）。
/// 迁到 go_router 后它变成 redirect 回调里的多分支逻辑，
/// 分支写错的表现是"白屏"或"登录后被弹回登录页"——真机上要逐屏肉眼确认。
///
/// 第一版测试曾用 `pumpWidget(MaterialApp.router(...))` 去跑真实页面，
/// **失败原因是页面本身需要 ProviderScope 并发网络请求**——
/// 那样测的其实是"整个 app 能不能启动"，与本逻辑无关，
/// 且会因为无关原因红。改成断言 `resolveRedirect` 这个纯函数后：
/// 覆盖全部分支、毫秒级、零网络依赖。
///
/// 其中 `isLoading` 那一支尤其重要：冷启动时会话还没恢复完，
/// 若不特判就会先判成"未登录"→ 跳登录页 → 恢复完再跳回首页，
/// 用户看到的是**登录页一闪**。只有断言返回值才守得住。
void main() {
  group('Routes 路径构造', () {
    test('detailOf 生成 /detail/{id}', () {
      expect(Routes.detailOf('abc123'), '/detail/abc123');
    });

    test('playOf 无 index 时只有 id', () {
      expect(Routes.playOf('abc123'), '/play/abc123');
    });

    test('playOf 带 index 时附查询参数', () {
      expect(Routes.playOf('abc123', index: 3), '/play/abc123?index=3');
    });

    test('各路径常量不重复（防手误复制粘贴）', () {
      const all = [
        Routes.login,
        Routes.home,
        Routes.search,
        Routes.detail,
        Routes.player,
      ];
      expect(all.toSet().length, all.length, reason: '存在重复路径常量');
    });

    test('不再有 /splash 路由（2026-10 用户要求去掉启动页）', () {
      // 这条断言守的是"别把它加回来"：/splash 会让冷启动出现
      // 第三个尺寸不同的 logo（系统启动图 → splash → 登录页），
      // 肉眼就是"图标跳一下再变一次"。
      expect(
        Routes.login,
        '/login',
        reason: '登录页路径不该被改动',
      );
      // 用源码断言守住：router.dart 里不应再出现 splash 字样
      final src = File('lib/core/router.dart').readAsStringSync();
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        code.contains('/splash'),
        isFalse,
        reason: 'router.dart 里又出现了 /splash 路由。\n'
            '冷启动到登录页之间的过渡页会导致 logo 尺寸跳变，\n'
            '会话预热已移到 main.dart（首帧前恢复完，加载态不出现）。',
      );
    });
  });

  group('会话门控 resolveRedirect', () {
    const loading = AsyncLoading<MediaSession?>();
    const anon = AsyncData<MediaSession?>(null);
    final authed = AsyncData<MediaSession?>(_session);

    test('未登录 → 登录页', () {
      expect(
        resolveRedirect(session: anon, location: Routes.home),
        Routes.login,
      );
    });

    test('未登录且已在登录页 → 不再跳（否则无限重定向）', () {
      expect(
        resolveRedirect(session: anon, location: Routes.login),
        isNull,
        reason: '返回登录页本身会导致 go_router 反复重定向',
      );
    });

    test('已登录 → 首页放行', () {
      expect(
        resolveRedirect(session: authed, location: Routes.home),
        isNull,
      );
    });

    test('已登录但停在登录页 → 回首页（登录成功后的跳转）', () {
      expect(
        resolveRedirect(session: authed, location: Routes.login),
        Routes.home,
      );
    });

    test('会话恢复中 → 落登录页（不落首页，首页非空依赖 api 会红屏）', () {
      expect(
        resolveRedirect(session: loading, location: Routes.home),
        Routes.login,
        reason: '冷启动时会话尚未恢复（SessionNotifier.build 是异步的）。\n'
            '此时**不能**放行首页：HomePage 里是 `ref.read(embyApiProvider)!`，\n'
            '而该 provider 依赖 sessionProvider.value（此刻为 null）\n'
            '→ 直接抛 Null check operator used on a null value（红屏）。\n'
            '登录页只用 sessionProvider.notifier，恢复期间渲染它是安全的。',
      );
    });

    test('会话恢复中且已在登录页 → 不重复跳（避免无限重定向）', () {
      expect(
        resolveRedirect(session: loading, location: Routes.login),
        isNull,
        reason: '返回登录页本身会导致 go_router 反复重定向',
      );
    });

    test('已登录访问详情页 → 不被门控干扰', () {
      expect(
        resolveRedirect(session: authed, location: Routes.detailOf('it9')),
        isNull,
        reason: '门控只该管登录/首页，不该把正常页面弹走',
      );
    });

    test('未登录访问详情页（深链）→ 拦到登录页', () {
      expect(
        resolveRedirect(session: anon, location: Routes.detailOf('it9')),
        Routes.login,
      );
    });

    test('未登录访问播放器深链 → 拦到登录页', () {
      expect(
        resolveRedirect(session: anon, location: Routes.playOf('it9')),
        Routes.login,
      );
    });

    test('会话出错（AsyncError）→ 按未登录处理，不卡死', () {
      const err = AsyncError<MediaSession?>('boom', StackTrace.empty);
      expect(
        resolveRedirect(session: err, location: Routes.home),
        Routes.login,
        reason: '错误态必须能落到登录页，否则用户卡在 splash',
      );
    });
  });
}

final _session = MediaSession(
  serverUrl: 'http://test.local',
  accessToken: 'tok',
  user: const MediaUser(id: 'u1', name: 'tester'),
  deviceId: 'dev1',
);
