import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cineflow/danmaku/danmaku_config.dart';
import 'package:cineflow/data/models.dart';
import 'package:cineflow/data/session_store.dart';
import 'package:cineflow/main.dart';
import 'package:cineflow/state/providers.dart';

class _FakeStore implements SessionStore {
  /// 多账号 —— 测试替身：空列表。
  @override
  Future<List<MediaSession>> loadAccounts() async => const [];

  @override
  Future<void> upsertAccount(MediaSession s) async {}

  @override
  Future<void> removeAccount(MediaSession s) async {}

  @override
  Future<String> deviceId() async => 'test-device';
  @override
  Future<MediaSession?> loadSession() async => null;
  @override
  Future<void> saveSession(MediaSession s) async {}
  @override
  Future<void> clearSession() async {}
  @override
  Future<List<SavedServer>> loadServers() async => const [];
  @override
  Future<void> upsertServer(SavedServer s) async {}
  @override
  Future<List<String>> loadSearchHistory() async => const [];
  @override
  Future<void> pushSearchHistory(String query) async {}
  @override
  Future<void> clearSearchHistory() async {}
  @override
  Future<String?> getPref(String key) async => null;
  @override
  Future<void> setPref(String key, String value) async {}
  // 弹幕配置：测试里回默认值（弹幕关闭），不碰真实安全存储
  @override
  Future<DanmakuConfig> loadDanmakuConfig() async => const DanmakuConfig();
  @override
  Future<void> saveDanmakuConfig(DanmakuConfig c) async {}

  // 追剧日历的 TMDB key：测试里回 null（跳过 TMDB 源，不碰安全存储）
  @override
  Future<String?> loadTmdbKey() async => null;
  @override
  Future<void> saveTmdbKey(String key) async {}

  // ---- Trakt（★ 新增的公开方法必须同步 fake，否则编译不过）----
  // 内存实现（与上面其它方法同风格）：不碰 Keystore ⇒ 测试快且稳定。
  String? _traktClientId;
  String? _traktAccess;
  String? _traktRefresh;

  /// 供测试断言用（真实实现不需要暴露 —— 这里是为了让 fake 的
  /// `refresh` 字段**真的被读到**，否则 analyze 报 unused_field，
  /// 而删掉它又会让 fake 与真实行为不一致）。
  String? get traktRefreshForTest => _traktRefresh;

  @override
  Future<String?> loadTraktClientId() async => _traktClientId;

  @override
  Future<void> saveTraktClientId(String id) async {
    final v = id.trim();
    _traktClientId = v.isEmpty ? null : v;
  }

  @override
  Future<String?> loadTraktAccessToken() async => _traktAccess;

  @override
  Future<void> saveTraktTokens({
    required String access,
    String? refresh,
  }) async {
    _traktAccess = access.trim();
    if (refresh != null && refresh.trim().isNotEmpty) {
      _traktRefresh = refresh.trim();
    }
  }

  @override
  Future<void> clearTraktTokens() async {
    _traktAccess = null;
    _traktRefresh = null;
  }

}

void main() {
  testWidgets('登录页冒烟测试', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionStoreProvider.overrideWithValue(_FakeStore())],
      child: const CineFlowApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('CineFlow'), findsWidgets);
  });
}
