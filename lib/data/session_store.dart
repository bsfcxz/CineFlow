/// 会话 / 已存服务器 / 设备 ID 的安全存储（flutter_secure_storage）
library;
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/uuid.dart';
import '../danmaku/danmaku_config.dart';
import 'models.dart';

class SavedServer {
  final String name; // 展示名（host）
  final String url; // 无尾部斜杠
  final String username;
  final String? password; // 仅当用户勾选「记住密码」时保存（安全存储内）

  const SavedServer({
    required this.name,
    required this.url,
    required this.username,
    this.password,
  });

  factory SavedServer.fromJson(Map<String, dynamic> j) => SavedServer(
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        username: j['username'] as String? ?? '',
        password: j['password'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'username': username,
        if (password != null) 'password': password,
      };
}

/// 键值存储的最小接口。
///
/// ## 为什么要抽这层（而不是直接用 FlutterSecureStorage）
///
/// `FlutterSecureStorage` 是个方法很多的普通类，测试里没法只实现用到的那几个
/// （Dart 要求实现全部成员）——伪造它既啰嗦又脆弱。
/// 抽成三方法的接口后：
///   - 生产：一个薄适配器包住 `FlutterSecureStorage`
///   - 测试：一个内存 Map 即可，**且测的是真实读写路径**
///     （弹幕配置的 JSON 序列化曾经出过"默认值/存储层不同步"类 bug，
///      只有闭环读写能发现——所以不能让测试绕过这段逻辑）
///
/// 参数用命名形式，与 `FlutterSecureStorage` 的调用风格一致，
/// 这样适配器与调用点都无需改动。
abstract interface class SecureKv {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<void> delete({required String key});
}

/// 生产实现：包住 flutter_secure_storage（Android Keystore）。
class SecureKvImpl implements SecureKv {
  const SecureKvImpl([this._inner = const FlutterSecureStorage()]);

  final FlutterSecureStorage _inner;

  @override
  Future<String?> read({required String key}) => _inner.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _inner.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _inner.delete(key: key);
}

class SessionStore {
  static const _sessionKey = 'cf_session';
  static const _serversKey = 'cf_servers';
  static const _deviceIdKey = 'cf_device_id';
  static const _historyKey = 'cf_search_history';

  /// 可注入的存储后端（默认用 Android Keystore）。
  SessionStore({SecureKv? storage}) : _storage = storage ?? const SecureKvImpl();

  final SecureKv _storage;

  Future<String> deviceId() async {
    var v = await _storage.read(key: _deviceIdKey);
    if (v == null || v.isEmpty) {
      v = uuidV4();
      await _storage.write(key: _deviceIdKey, value: v);
    }
    return v;
  }

  Future<MediaSession?> loadSession() async {
    final raw = await _storage.read(key: _sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return MediaSession.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession(MediaSession s) =>
      _storage.write(key: _sessionKey, value: jsonEncode(s.toJson()));

  Future<void> clearSession() => _storage.delete(key: _sessionKey);

  Future<List<SavedServer>> loadServers() async {
    final raw = await _storage.read(key: _serversKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SavedServer.fromJson)
          .toList();
      return list;
    } catch (_) {
      return const [];
    }
  }

  /// 按 url 去重置顶，最多保留 8 个
  Future<void> upsertServer(SavedServer s) async {
    final list = [s, ...await loadServers()];
    final seen = <String>{};
    final deduped = <SavedServer>[];
    for (final x in list) {
      if (seen.add(x.url)) deduped.add(x);
      if (deduped.length >= 8) break;
    }
    await _storage.write(
        key: _serversKey, value: jsonEncode([for (final x in deduped) x.toJson()]));
  }

  /// 搜索历史（置顶去重，最多 10 条）
  Future<List<String>> loadSearchHistory() async {
    final raw = await _storage.read(key: _historyKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [for (final e in jsonDecode(raw) as List? ?? const []) e.toString()];
    } catch (_) {
      return const [];
    }
  }

  Future<void> pushSearchHistory(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final list = [q, ...await loadSearchHistory()];
    final seen = <String>{};
    final deduped = <String>[];
    for (final x in list) {
      if (seen.add(x)) deduped.add(x);
      if (deduped.length >= 10) break;
    }
    await _storage.write(key: _historyKey, value: jsonEncode(deduped));
  }

  Future<void> clearSearchHistory() =>
      _storage.delete(key: _historyKey);

  // ---- 播放偏好（KV）----
  /// 偏好键前缀。public 供单元测试锁定，避免键名写错导致偏好静默失效
  /// （如 default_rate 曾因缺少写入入口而长期失效，见 AGENTS.md §7.5）。
  static const prefPrefix = 'cf_pref_';
  static const _prefPrefix = prefPrefix;

  Future<String?> getPref(String key) =>
      _storage.read(key: '$_prefPrefix$key');

  Future<void> setPref(String key, String value) =>
      _storage.write(key: '$_prefPrefix$key', value: value);

  // ---- 弹幕配置 ----
  //
  // ⚠️ 存这里而不是普通 SharedPreferences：配置里含 **AppSecret**
  // （官方弹弹play 的签名密钥）。`SessionStore` 底层是 flutter_secure_storage
  // （Android Keystore），与 Emby 凭据同一套保护。放进明文 prefs
  // 等于把密钥写给任何能读应用数据的进程。
  static const _danmakuKey = 'cf_danmaku_config';

  Future<DanmakuConfig> loadDanmakuConfig() async {
    try {
      final raw = await _storage.read(key: _danmakuKey);
      if (raw == null || raw.isEmpty) return const DanmakuConfig();
      final m = jsonDecode(raw);
      if (m is! Map) return const DanmakuConfig();

      // ⚠️ **逐字段**取默认值，不要整段靠 try/catch 兜。
      //
      // 首版是"一个 try 包全部字段"，测试抓出问题：只要**任一字段**类型不符
      // （如 opacity 写成了字符串），异常就会跳到 catch，
      // 于是**所有字段**都退回默认值——用户合法设置的字号、屏蔽词
      // 会因为一个坏字段被连累丢失。
      //
      // 这也正是 Cmby 版本历史里那类"设置显示一个值、实际用另一个"的成因。
      double dbl(Object? v, double fallback) =>
          v is num ? v.toDouble() : fallback;
      String str(Object? v) => v is String ? v : '';

      return DanmakuConfig(
        kind: DanmakuProviderKind.values.firstWhere(
          (k) => k.name == m['kind'],
          orElse: () => DanmakuProviderKind.off,
        ),
        baseUrl: str(m['baseUrl']),
        appId: str(m['appId']),
        appSecret: str(m['appSecret']),
        enabled: m['enabled'] is bool ? m['enabled'] as bool : true,
        opacity: dbl(m['opacity'], 1.0),
        fontScale: dbl(m['fontScale'], 1.0),
        showArea: dbl(m['showArea'], 1.0),
        blockedWords: (m['blockedWords'] as List?)
                ?.whereType<String>()
                .toList(growable: false) ??
            const [],
        useAsync: m['useAsync'] is bool ? m['useAsync'] as bool : true,
      );
    } catch (_) {
      // 走到这里只剩"整个 JSON 都解析不了"（如截断、非 JSON），
      // 那种情况才整体回退默认——配置坏了不该让应用起不来。
      return const DanmakuConfig();
    }
  }

  Future<void> saveDanmakuConfig(DanmakuConfig c) => _storage.write(
        key: _danmakuKey,
        value: jsonEncode({
          'kind': c.kind.name,
          'baseUrl': c.baseUrl,
          'appId': c.appId,
          'appSecret': c.appSecret,
          'enabled': c.enabled,
          'opacity': c.opacity,
          'fontScale': c.fontScale,
          'showArea': c.showArea,
          'blockedWords': c.blockedWords,
          'useAsync': c.useAsync,
        }),
      );
}
