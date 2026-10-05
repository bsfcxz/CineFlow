import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cineflow/danmaku/danmaku_config.dart';
import 'package:cineflow/data/models.dart';
import 'package:cineflow/data/session_store.dart';
import 'package:cineflow/main.dart';
import 'package:cineflow/state/providers.dart';

class _FakeStore implements SessionStore {
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
}

void main() {
  testWidgets('登录页冒烟测试', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionStoreProvider.overrideWithValue(_FakeStore())],
      child: const CineFlowApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('连接你的服务器'), findsOneWidget);
  });
}
