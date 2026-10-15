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
  int? _traktExpiresAt;

  /// 供测试断言用（真实实现不需要暴露 —— 这里是为了让 fake 的
  /// `refresh` 字段**真的被读到**，否则 analyze 报 unused_field，
  /// 而删掉它又会让 fake 与真实行为不一致）。
  String? get traktRefreshForTest => _traktRefresh;

  // ---- 3 个功能开关（`SessionStore` 新增接口，见 session_store.dart）----
  //
  // ⚠️ **加接口方法必须同步补假实现** —— 否则整个测试文件编译失败
  //    （本仓库踩过多次：`_FakeStore implements SessionStore` 是**全量**契约）。
  final _traktFlags = <String, bool>{};

  @override
  Future<bool> traktFlag(String key) async => _traktFlags[key] ?? false;

  @override
  Future<void> setTraktFlag(String key, bool on) async {
    _traktFlags[key] = on;
  }

  @override
  Future<({bool track, bool sync, bool resume})> traktFlags() async => (
        track: _traktFlags[SessionStore.kTraktTrackKey] ?? false,
        sync: _traktFlags[SessionStore.kTraktSyncKey] ?? false,
        resume: _traktFlags[SessionStore.kTraktResumeKey] ?? false,
      );

  @override
  Future<String?> loadTraktClientId() async => _traktClientId;

  @override
  Future<void> saveTraktClientId(String id) async {
    final v = id.trim();
    _traktClientId = v.isEmpty ? null : v;
  }

  /// ⚠️ **第 4 次**因本替身漏方法而编译不过了。
  /// 规矩（已写进 AGENTS §6.10）：**改 `SessionStore` 的公开方法，
  /// 必须同步改本替身**（它 `implements SessionStore`，接口一加就缺实现）。
  @override
  Future<String?> resolveTraktClientId() async {
    // 替身里不碰真实 builtin_secret（那要原生通道）⇒ 直接返回自填值
    final v = _traktClientId;
    return (v == null || v.isEmpty) ? null : v;
  }

  @override
  Future<String?> loadTraktAccessToken() async => _traktAccess;

  /// ⚠️ **加 `SessionStore` 的新方法时必须同步补这里**
  /// （这是第 2 次：上次加 `traktFlags()` 时也漏了 ⇒ 编译不过）。
  /// 替身 `implements SessionStore` ⇒ 接口一加方法它就缺实现。
  @override
  Future<String?> loadTraktRefreshToken() async => _traktRefresh;

  /// ⚠️ **第 3 次**因 `_FakeStore` 漏方法而编译不过了
  /// （traktFlags / loadTraktRefreshToken / 本次 saveTraktExpiresAt+traktExpiresInMs）。
  /// ⇒ 规矩：**改 `SessionStore` 的公开方法，必须同步改本替身**。
  @override
  Future<void> saveTraktExpiresAt(int epochMs) async {
    _traktExpiresAt = epochMs;
  }

  @override
  Future<int?> traktExpiresInMs() async {
    final at = _traktExpiresAt;
    if (at == null) return null;
    return at - DateTime.now().millisecondsSinceEpoch;
  }

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
