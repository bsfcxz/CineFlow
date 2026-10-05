/// 应用状态（riverpod）：会话、API 实例、首页数据
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/emby_provider.dart';
import '../data/home_repository.dart';
import '../data/media_provider.dart';
import '../data/models.dart';
import '../data/session_store.dart';

final sessionStoreProvider =
    Provider<SessionStore>((ref) => SessionStore());

/// 登录会话：null = 未登录；启动时自动恢复持久化会话
class SessionNotifier extends AsyncNotifier<MediaSession?> {
  @override
  Future<MediaSession?> build() =>
      ref.watch(sessionStoreProvider).loadSession();

  Future<void> login(String serverUrl, String username, String password,
      {bool remember = true}) async {
    final store = ref.read(sessionStoreProvider);
    final s = await EmbyProvider.authenticate(
      serverUrl: serverUrl,
      username: username,
      password: password,
      deviceId: await store.deviceId(),
    );
    await store.saveSession(s);
    await store.upsertServer(SavedServer(
      name: Uri.tryParse(serverUrl)?.host ?? serverUrl,
      url: serverUrl,
      username: username,
      password: remember ? password : null,
    ));
    ref.invalidate(embyApiProvider);
    state = AsyncData(s);
  }

  Future<void> logout() async {
    await ref.read(sessionStoreProvider).clearSession();
    ref.invalidate(embyApiProvider);
    state = const AsyncData(null);
  }
}

final sessionProvider =
    AsyncNotifierProvider<SessionNotifier, MediaSession?>(SessionNotifier.new);

/// 主题预设 index（外观页切换 → MaterialApp key 重建）
class ThemeIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final themeIndexProvider =
    NotifierProvider<ThemeIndexNotifier, int>(ThemeIndexNotifier.new);

/// 首页顶栏齿轮 → 切到「我的」Tab
class HomeTabNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final homeTabProvider =
    NotifierProvider<HomeTabNotifier, int>(HomeTabNotifier.new);

/// 当前可用的 MediaProvider（未登录为 null）
final embyApiProvider = Provider<MediaProvider?>((ref) {
  final s = ref.watch(sessionProvider).value;
  return s == null ? null : EmbyProvider(s);
});

/// 首页聚合数据（单区块失败不拖垮整页）
final homeProvider = FutureProvider.autoDispose<HomeData>((ref) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const MediaException('未登录');
  return HomeData.fetch(api);
});
