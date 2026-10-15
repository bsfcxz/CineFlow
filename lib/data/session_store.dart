/// 会话 / 已存服务器 / 设备 ID 的安全存储（flutter_secure_storage）
library;
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/uuid.dart';
import '../danmaku/danmaku_config.dart';
import 'builtin_secret.dart';
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

  // ═══════════════════════════════════════════════════════════════
  // 多账号（用户要求："增加多 emby 账号登录和资源整合"）
  // ═══════════════════════════════════════════════════════════════
  //
  // ## 设计取舍：**保留"当前会话"不变，另存一份账号列表**
  // `cf_session`（当前会话）是**所有既有代码**的读取点
  //（`sessionProvider` → `embyApiProvider` → 首页/详情/播放器）。
  // 若把它改成"列表 + 当前索引"，整条链路都要动 —— 风险远大于收益。
  //
  // 故新增 `cf_accounts`（**所有**已登录账号），而 `cf_session`
  // 仍表示"当前生效的那个"。两者关系：
  //   · 登录 → 写入 accounts（去重）+ 覆盖 session
  //   · 切换 → 从 accounts 取该账号写回 session
  //   · 退出 → 只清 session（**保留** accounts，便于再切回来）
  //   · 彻底移除 → 从 accounts 删除
  //
  // ⇒ 搜索聚合读 accounts（多台都搜）；播放走 session（单台）。
  //   这正是用户确认的方案："搜索聚合 + 首页保持单服务器切换"。
  static const _accountsKey = 'cf_accounts';

  /// 账号唯一键：`serverUrl|userId`。
  ///
  /// ⚠️ **必须含 userId 而不是只用 serverUrl**：同一台服务器可以
  /// 有多个 Emby 用户（家庭共享），它们的库/权限/进度都不同 ——
  /// 只用 url 去重会把第二个用户挤掉。
  static String accountKey(MediaSession s) =>
      '${s.serverUrl}|${s.user.id}';

  Future<List<MediaSession>> loadAccounts() async {
    final raw = await _storage.read(key: _accountsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(MediaSession.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 写入/更新一个账号（按 [accountKey] 去重，最多 8 个）。
  Future<void> upsertAccount(MediaSession s) async {
    final list = [s, ...await loadAccounts()];
    final seen = <String>{};
    final out = <MediaSession>[];
    for (final x in list) {
      if (seen.add(accountKey(x))) out.add(x);
      if (out.length >= 8) break;
    }
    await _storage.write(
        key: _accountsKey, value: jsonEncode([for (final x in out) x.toJson()]));
  }

  /// 移除一个账号（"退出登录"里选"彻底移除"时用）。
  Future<void> removeAccount(MediaSession s) async {
    final key = accountKey(s);
    final out = [
      for (final x in await loadAccounts())
        if (accountKey(x) != key) x
    ];
    await _storage.write(
        key: _accountsKey, value: jsonEncode([for (final x in out) x.toJson()]));
  }

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

  // ---- 追剧日历：TMDB API key ----
  //
  // ⚠️ 存这里（secure_storage）而不是明文 prefs / **绝不入库**：
  //    API key 属凭据（本仓库安全红线）。用户自己填、自己用。
  //    ⚠️ 仓库里**连占位符都不放**（与弹幕 AppSecret 同一策略）。
  static const _tmdbKeyKey = 'cf_tmdb_key';

  Future<String?> loadTmdbKey() async {
    final v = await _storage.read(key: _tmdbKeyKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> saveTmdbKey(String key) async {
    final v = key.trim();
    if (v.isEmpty) {
      await _storage.delete(key: _tmdbKeyKey);
    } else {
      await _storage.write(key: _tmdbKeyKey, value: v);
    }
  }

  // ---- Trakt（★ 凭据：只进 secure_storage，仓库里不放任何值）----
  //
  // ## 为什么三样分开存
  // · `client_id`  —— 用户自己申请的应用标识（公开但仍是凭据）
  // · `access_token` / `refresh_token` —— **登录态等价物**
  // ⇒ 三者都不得入库（§红线）；与 `loadTmdbKey` 同一策略。
  //
  // ## 为什么不用一个 JSON 存
  // 分开存便于**单独失效**：token 过期时只清 token、保留 client_id
  // （用户不用重新填 Client ID）。
  static const _traktClientIdKey = 'cf_trakt_client_id';
  static const _traktAccessKey = 'cf_trakt_access_token';
  static const _traktRefreshKey = 'cf_trakt_refresh_token';

  /// **access token 的到期时刻**（epoch 毫秒）。
  ///
  /// ## 为什么要单独存（借鉴小幻影视的 `set_TraktExpiresTimestamp`）
  /// Trakt 的 token 响应给 `created_at`（epoch 秒）+ `expires_in`（秒）
  /// ⇒ 能**本地算出**到期时刻 ⇒ **不必等 401 才发现过期**。
  /// 好处：可以"提前刷新"，少一次必然失败的请求 + 少一条误导性的错误日志。
  ///
  /// ⚠️ 它不是凭据（只是个时间戳）⇒ 存这里是为了**集中**，
  ///    不是因为需要 Keystore 保护。
  static const _traktExpiresKey = 'cf_trakt_expires_at';

  // ---- Trakt 的 3 个功能开关（「实时追踪」/「同步已看」/「续播检查」）----
  //
  // ## 为什么用 pref 而不是内存变量
  // 它们是**用户偏好**：① 重启后必须仍生效 ② 别的页面（播放器、详情页）
  // 要能读 ⇒ 与 `theme_index` / `bg_kind` 同一模式。
  //
  // ## 为什么默认全关（`false`）
  // 这三个功能会**写数据到用户 Trakt 账号**（scrobble / history）。
  // 未经用户明确开启就写别人的账号是不对的 ⇒ 默认关闭，让用户主动开。
  static const kTraktTrackKey = 'trakt_track';   // 实时追踪
  static const kTraktSyncKey = 'trakt_sync';     // 同步已看状态
  static const kTraktResumeKey = 'trakt_resume'; // 续播检查

  /// **深色模式**开关（用户 2026-10-14："关闭始终用深色模式主题"）。
  ///
  /// ## 为什么与 `bg_kind` 分开存（会有状态打架吗？）
  /// · `bg_kind` = **用户选的具体底色**（深色/黑色/透明/浅白/白色/自定义）
  /// · `dark_mode` = **亮/暗总开关**
  /// ⇒ 两者**不是同一维度**：关闭深色模式时把 `bg_kind` 切到浅白，
  ///   但**记住**用户原来选的深色档 ⇒ 重新打开时能切回去。
  ///   这就是为什么要单独存一个键（否则"关掉再打开"回不到原来那档）。
  static const kDarkModeKey = 'app_dark_mode';

  /// 关闭深色模式前用的底色（用于"重新打开"时恢复）。
  static const kDarkModePrevBgKey = 'app_dark_mode_prev_bg';

  /// 读一个开关（未设置 ⇒ `false`）。
  Future<bool> traktFlag(String key) async =>
      (await getPref(key)) == 'true';

  /// 写一个开关。
  Future<void> setTraktFlag(String key, bool on) =>
      setPref(key, on ? 'true' : 'false');

  /// 三个开关一次性读出（播放器/详情页要同时判断）。
  ///
  /// ## 为什么一次读（而不是三次 await）
  /// 播放器在**起播路径**上调用它 —— 顺序 await 会累积延迟
  /// （底层是 Keystore 加解密，每次几毫秒到几十毫秒）。
  Future<({bool track, bool sync, bool resume})> traktFlags() async {
    final r = await Future.wait([
      traktFlag(kTraktTrackKey),
      traktFlag(kTraktSyncKey),
      traktFlag(kTraktResumeKey),
    ]);
    return (track: r[0], sync: r[1], resume: r[2]);
  }

  Future<String?> loadTraktClientId() async {
    final v = await _storage.read(key: _traktClientIdKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> saveTraktClientId(String id) async {
    final v = id.trim();
    if (v.isEmpty) {
      await _storage.delete(key: _traktClientIdKey);
    } else {
      await _storage.write(key: _traktClientIdKey, value: v);
    }
  }

  /// 读 **refresh token**（一次性；刷新后必须替换）。
  ///
  /// ## 为什么必须能读出来（用户 2026-10-14 规格第 4 步）
  /// 不做自动刷新的话，access token **7 天后**（官方文档）失效
  /// ⇒ 用户所有 Trakt 功能**静默失效**（表现为"同步不动了"，很难查）。
  ///
  /// ⚠️ 它等价于登录态（能换出新 token）⇒ 只进 secure_storage，**不打日志**。
  /// **取"有效"的 Trakt Client ID**（用户自填优先，否则解封内置的）。
  ///
  /// ## ★ 为什么必须有这个方法（2026-10-14 用户报障的根因）
  /// 三处调用点原先各自写：
  /// ```dart
  /// final cid = await store.loadTraktClientId();   // ❌ 只读用户自填的
  /// if (cid == null || cid.isEmpty) { /* 判"未登录" */ }
  /// ```
  /// 而**内置 Client ID**（"Client ID 以后内置在我的应用中"）**不在存储里** ——
  /// 它在 `builtin_secret.dart` 里按需解封。
  /// ⇒ `loadTraktClientId()` 恒为空 ⇒ **授权成功也被判"未登录"**
  ///   ⇒ 实时追踪 / 同步已看 / 续播检查**全部静默跳过**。
  ///   用户现象："显示我没登录、同步不了相关数据"。
  ///
  /// ## 为什么要收口到一处
  /// 三处重复逻辑必然漏改（本仓库既有教训：我本轮就因三处各自读 token
  /// 而差点让刷新成死代码）⇒ 与 `TraktSync.fromStore` 同一思路。
  ///
  /// ## 返回
  /// `null` = 两种来源都没有 ⇒ 调用方应判"未配置 Client ID"。
  Future<String?> resolveTraktClientId() async {
    // ① 用户自填优先（尊重用户特意填的 —— 他可能想用自己的 Trakt 应用）
    final mine = await loadTraktClientId();
    if (mine != null && mine.isNotEmpty) return mine;
    // ② 回退到内置（签名绑定解封；换签名重打包时会失败 ⇒ 返回 null）
    final builtin = await unsealBuiltinTraktClientId();
    return (builtin == null || builtin.isEmpty) ? null : builtin;
  }

  Future<String?> loadTraktRefreshToken() async =>
      (await _storage.read(key: _traktRefreshKey));

  /// 存 access token 的**到期时刻**（epoch 毫秒）。
  Future<void> saveTraktExpiresAt(int epochMs) => _storage.write(
      key: _traktExpiresKey, value: epochMs.toString());

  /// 读到期的**剩余毫秒**（null = 没记录 ⇒ 调用方应保守处理）。
  Future<int?> traktExpiresInMs() async {
    final v = await _storage.read(key: _traktExpiresKey);
    final at = int.tryParse(v ?? '');
    if (at == null) return null;
    return at - DateTime.now().millisecondsSinceEpoch;
  }

  Future<String?> loadTraktAccessToken() async {
    final v = await _storage.read(key: _traktAccessKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 保存登录结果（`refresh` 为 null 时**保留原值**）。
///
/// ## ⚠️ 与官方文档对齐（我原来的假设是**错的**）
/// 我原来写"刷新流程**可能不给**新 refresh" —— 官方文档说的是**相反**：
/// > Refresh tokens are **single-use**. Every successful refresh returns a
/// > new `access_token` **and `refresh_token`**. The refresh token used in
/// > the request is **immediately invalidated**, so always replace your
/// > stored tokens with the values from the response.
///
/// ⇒ 所以：
/// · 刷新成功时**必须**传入响应里的新 `refresh`（否则旧的那个已失效 ⇒ 下次刷新必失败）
/// · 本方法的 `refresh == null ⇒ 保留原值` 只适用于**非刷新路径**
///   （如重复保存同一份授权结果），**不能**用在刷新流程里。
/// · ✅ **自动续期已实现**（2026-10-15 更正本条 —— 原文写"待实现"，已过时）：
///   `TraktSync.refresh()` → `POST /oauth/token`；
///   触发点见 `TraktSync.fromStore`（提前刷新）与构造器的 401 拦截器。
///   ⚠️ 刷新**成功后**必须调本方法传入新 `refresh` ——
///   否则存的是**已作废**的旧值（官方："immediately invalidated"）。
  Future<void> saveTraktTokens({
    required String access,
    String? refresh,
  }) async {
    await _storage.write(key: _traktAccessKey, value: access.trim());
    if (refresh != null && refresh.trim().isNotEmpty) {
      await _storage.write(key: _traktRefreshKey, value: refresh.trim());
    }
  }

  /// **退出登录**：清 token，**保留 client_id**（用户不必重填）。
  Future<void> clearTraktTokens() async {
    await _storage.delete(key: _traktAccessKey);
    await _storage.delete(key: _traktRefreshKey);
  }

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
          // ★ 未知/缺失时回退到 **DanmakuConfig 的默认值**，不写死某个 kind。
          //
          // ## 为什么不能写死 `off`
          // 默认值只在 `DanmakuConfig` 里定义一处。若这里写死 `off`：
          //   · 改了默认值 ⇒ 存储层仍回退到旧值 ⇒ **两处默认值不一致**
          //   · 而"未知 kind 回退"与"首次使用的默认"应该是**同一个值**，
          //     否则升级路径上会出现"明明默认是 A，读到脏数据变成 B"。
          // 测试已按此断言（`danmaku_persist_test` 的"未知 kind 回退"），
          // 它在本轮**正确抓到了这处硬编码**。
          orElse: () => const DanmakuConfig().kind,
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
        // 对照 B 站新增项：**逐字段**取默认，任一坏掉不连累其它
        modes: DanmakuDisplayModes(
          scroll: m['modeScroll'] is bool ? m['modeScroll'] as bool : true,
          top: m['modeTop'] is bool ? m['modeTop'] as bool : true,
          bottom: m['modeBottom'] is bool ? m['modeBottom'] as bool : true,
        ),
        speed: dbl(m['speed'], 1.0),
        bold: m['bold'] is bool ? m['bold'] as bool : false,
        avoidSubtitle:
            m['avoidSubtitle'] is bool ? m['avoidSubtitle'] as bool : true,
        // 简繁转换：存 name（可读、可降级）。
        // 未知字面量回退**默认值**（与 kind 同一原则：
        // 默认值只在 DanmakuConfig 定义一处，存储层不写死）。
        chConvert: DanmakuChConvert.values.firstWhere(
          (x) => x.name == m['chConvert'],
          orElse: () => const DanmakuConfig().chConvert,
        ),
        // 过滤等级 0-4，越界钳制（防手改配置导致崩溃）
        filterLevel: (m['filterLevel'] is num)
            ? (m['filterLevel'] as num).toInt().clamp(0, 4)
            : const DanmakuConfig().filterLevel,
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
          // 对照 B 站新增的显示项（缺了会导致"设置改了但重启就回去"）
          'modeScroll': c.modes.scroll,
          'modeTop': c.modes.top,
          'modeBottom': c.modes.bottom,
          'speed': c.speed,
          'bold': c.bold,
          'avoidSubtitle': c.avoidSubtitle,
          // 简繁转换存 name：可读（便于排查）、可降级（未知值回退默认）
          'chConvert': c.chConvert.name,
          'filterLevel': c.filterLevel,
        }),
      );
}
