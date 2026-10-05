/// 115 网盘的 Dart 侧调用封装。
///
/// ## 为什么这里只是"薄封装"
///
/// 协议实现全在 **Go 核心层**（`go/internal/pan115/`），Dart 侧只做三件事：
///   1. 组装 payload / 解析信封
///   2. 把凭据交给安全存储（Go 侧不落盘）
///   3. 把播放直链的 **headers 原样透传**给播放器
///
/// 之所以不把协议写在 Dart：UA 绑定要求"取地址"与"播放"共用同一个 UA，
/// 放 Go 侧能让"取地址"与"产出播放头"同源产出（见 ADR 0007）。
///
/// ## ⚠️ 必须用 invokeAsync
///
/// 115 的方法都要发网络请求，扫码状态轮询更是**长轮询**（实测单次约 30 秒）。
/// `GoCore.invoke` 是**同步 FFI**，在 UI isolate 调它会冻住界面。
/// 故本文件所有方法都用 `invokeAsync`（在独立 isolate 执行）。
library;

import 'package:flutter/foundation.dart';

import '../core/go_core.dart';

/// 115 登录后得到的凭据（等价于登录 cookie）。
///
/// ⚠️ **这是敏感数据**（等价于账号登录态）：
/// 只应存入 `flutter_secure_storage`（Android Keystore），
/// **绝不写日志、绝不入库**（AGENTS.md 安全红线）。
class Pan115Credential {
  const Pan115Credential({
    required this.uid,
    required this.cid,
    required this.seid,
    this.kid = '',
    this.userName = '',
  });

  final String uid;
  final String cid;
  final String seid;
  final String kid;

  /// 仅用于界面展示，让用户确认登录的是哪个账号。
  final String userName;

  bool get isValid => uid.isNotEmpty && cid.isNotEmpty && seid.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'cid': cid,
        'seid': seid,
        // kid 允许为空：上游的校验里 UID/CID/SEID 是必需项，KID 兼容老 cookie
        'kid': kid,
      };

  /// 从 Go 侧返回的凭据 JSON 构造。
  ///
  /// ## ★ 大小写不敏感（踩过的真实缺陷）
  ///
  /// Go 侧发的是 **`UID`/`CID`/`SEID`/`KID`**（大写——这与 115 的 cookie 名一致，
  /// 见 `pan115_routes.go`），而这里原先读的是小写 `uid`/`cid`/…，
  /// 于是每个字段都取不到 → 全空 → `isValid` 为 false → 返回 null。
  ///
  /// **现象极具误导性**：扫码明明成功（轮询 status=2），却卡在最后一步；
  /// 日志显示"凭据不完整 uid=false cid=false…"像服务端没返回数据，
  /// 实际是**自己读错了键名**。而且"取不到"不会报错，只会静默变成空串。
  ///
  /// 修法选"大小写不敏感"而不是"统一改成大写"：
  /// 键名是这个跨语言边界的契约，两侧各自演进很容易再次错位
  /// （Go 用大写因为贴合 115 协议，Dart 侧习惯小写）。
  /// 兼容两种写法后，任一侧改名都不会再让登录静默失败。
  static Pan115Credential? fromJson(Map<String, dynamic> j) {
    String pick(String a, String b) =>
        (j[a] as String?) ?? (j[b] as String?) ?? '';

    final c = Pan115Credential(
      uid: pick('uid', 'UID'),
      cid: pick('cid', 'CID'),
      seid: pick('seid', 'SEID'),
      kid: pick('kid', 'KID'),
      userName: j['userName'] as String? ?? j['user_name'] as String? ?? '',
    );
    return c.isValid ? c : null;
  }

  @override
  String toString() =>
      // 刻意不输出任何凭据值——防止它被顺手打进日志
      'Pan115Credential(user: $userName, valid: $isValid)';
}

/// 扫码会话。
class Pan115QrSession {
  const Pan115QrSession({
    required this.uid,
    required this.time,
    required this.sign,
    required this.qrcode,
    required this.imageUrl,
  });

  final String uid;
  final int time;
  final String sign;

  /// 扫码内容（https URL）
  final String qrcode;

  /// **可直接显示**的二维码图片地址。
  ///
  /// 实测该端点返回 `image/png`（554 字节，PNG 魔数），
  /// 所以直接 `Image.network` 即可，**无需引入二维码生成库**。
  final String imageUrl;

  Map<String, dynamic> toPayload() => {'uid': uid, 'time': time, 'sign': sign};
}

/// 扫码状态。
class Pan115QrStatus {
  const Pan115QrStatus({
    required this.status,
    required this.label,
    required this.terminal,
    required this.allowed,
  });

  final int status;

  /// 中文描述（可直接展示）
  final String label;

  /// 是否已结束（可停止轮询）
  final bool terminal;

  /// 是否可换凭据（**必须为 true 才能调 finish**）
  ///
  /// ★ 这不是可选优化：实测一个真实但**未确认**的 uid 调 login 会返回
  /// `40101017 老乡验证失败`，与"完全非法 uid"的响应一模一样，
  /// 用户会看到误导性的"验证失败"。故必须等到 status==2。
  final bool allowed;
}

/// 115 文件条目。
class Pan115File {
  const Pan115File({
    required this.id,
    required this.name,
    required this.isDir,
    required this.size,
    required this.sizeLabel,
    required this.pickCode,
    required this.updateTime,
    this.thumbUrl = '',
    this.star = false,
  });

  final String id;
  final String name;
  final bool isDir;
  final int size;

  /// 已格式化的大小（与 Emby 侧口径一致：GB 保留 1 位小数）
  final String sizeLabel;

  /// 取播放/下载直链的钥匙（目录为空）
  final String pickCode;

  /// 原始时间字符串（115 有两种格式，解析交给展示层）
  final String updateTime;

  final String thumbUrl;
  final bool star;

  static Pan115File fromJson(Map<String, dynamic> j) => Pan115File(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        isDir: j['isDir'] == true,
        size: (j['size'] as num?)?.toInt() ?? 0,
        sizeLabel: j['sizeLabel'] as String? ?? '',
        pickCode: j['pickCode'] as String? ?? '',
        updateTime: j['updateTime'] as String? ?? '',
        thumbUrl: j['thumbUrl'] as String? ?? '',
        star: j['star'] == true,
      );

  bool get playable => !isDir && pickCode.isNotEmpty;
}

/// 一页文件列表。
class Pan115FilePage {
  const Pan115FilePage({
    required this.files,
    required this.total,
    required this.offset,
    required this.hasMore,
  });

  final List<Pan115File> files;
  final int total;
  final int offset;
  final bool hasMore;
}

/// 一次播放所需的全部信息。
///
/// ★ [headers] **必须**一起交给播放器（media_kit 的 `httpHeaders`）。
/// 115 的 CDN 直链与"取地址时所用的 UA"强绑定，且取地址响应可能回 Set-Cookie
/// （CDN 一次性凭证）。只传 URL 会 403，且现象是"地址取到了但播不了"，
/// 极难排查——所以类型上把 URL 与 headers 绑在一起，不给"只拿 URL"的机会。
class Pan115Playback {
  const Pan115Playback({
    required this.url,
    required this.headers,
    this.fileName = '',
    this.fileSize = 0,
    this.pickCode = '',
  });

  final String url;
  final Map<String, String> headers;
  final String fileName;
  final int fileSize;
  final String pickCode;
}

/// 115 账号信息（用于设置页展示与凭据有效性校验）。
class Pan115UserInfo {
  const Pan115UserInfo({
    this.userName = '',
    this.vipName = '',
    this.totalSize = 0,
    this.usedSize = 0,
  });

  final String userName;
  final String vipName;
  final int totalSize;
  final int usedSize;

  String get spaceLabel {
    if (totalSize <= 0) return '';
    String fmt(int b) {
      if (b >= 1073741824) return '${(b / 1073741824).toStringAsFixed(1)} GB';
      if (b >= 1048576) return '${(b / 1048576).round()} MB';
      return '${(b / 1024).round()} KB';
    }

    return '${fmt(usedSize)} / ${fmt(totalSize)}';
  }
}

/// 115 客户端（Go 核心层的 Dart 门面）。
///
/// 所有方法都是异步的，且**任何失败都返回 null / 空结果而不是抛异常**——
/// 与弹幕模块同一约定：网盘不可用不该让播放器或首页崩掉（AGENTS.md §5.5）。
class Pan115Client {
  const Pan115Client();

  /// Go 核心层是否可用。不可用时所有方法都返回空结果（降级）。
  bool get available => GoCore.available;

  // ---------------- 全局开关与额度（不发网络请求）----------------

  /// 读取/设置 115 功能的全局开关。
  ///
  /// [enabled] 为 null 时只读。
  ///
  /// ## 为什么要有这个开关
  ///
  /// 115 走的是**非公开接口**，访问代价落在**用户账号**上（风控）。
  /// 用户实测中报告"快要触发风控"，需要能立即止损。
  /// **Go 侧默认是关闭的**：应用启动后一个请求都不发，
  /// 直到用户主动打开——这比"默认开+手动关"安全（后者要求用户
  /// 先察觉异常，而那时风控往往已触发）。
  Future<({bool enabled, int usedToday, int dailyCap, bool capReached})?>
      pan115Switch({bool? enabled}) async {
    final r = await GoCore.invokeAsync('pan115.enabled',
        enabled == null ? null : {'enabled': enabled});
    if (!r.ok) return null;
    final m = _asMap(r.result);
    if (m == null) return null;
    return (
      enabled: m['enabled'] == true,
      usedToday: (m['usedToday'] as num?)?.toInt() ?? 0,
      dailyCap: (m['dailyCap'] as num?)?.toInt() ?? 0,
      capReached: m['dailyCapReached'] == true,
    );
  }

  // ---------------- 错误状态（供调用方做决策，而非只看 null）----------------
  //
  // ⚠️ 用**静态字段**而不是实例字段：`Pan115Client` 是 const 构造的
  // （provider 里没状态），加可变实例字段会破坏 const 语义。
  // 这不是"全局可变状态泛滥"——它只记录"最近一次失败的分类"，
  // 且**只被 UI 用来决定是否清除凭据**，不参与任何业务逻辑。

  static String? _lastError;
  static bool _needsRelogin = false;

  /// 最近一次失败的可读原因（供日志与提示）。
  static String? get lastError => _lastError;

  /// 最近一次失败是否属于"服务端明确要求重新登录"。
  ///
  /// ★ 这个区分至关重要：只有它为 true 时才允许**清除本地凭据**。
  /// 把"网络不通/解析异常"误判成"凭据失效"会把用户的登录状态误删——
  /// 实测踩过：一个解析 bug 被当成凭据失效，用户刚扫码就被踢回未登录。
  static bool get lastErrorNeedsRelogin => _needsRelogin;

  static void _record({String? error, bool needsRelogin = false}) {
    _lastError = error;
    _needsRelogin = needsRelogin;
  }

  static void _clearError() {
    _lastError = null;
    _needsRelogin = false;
  }

  // ---------------- 登录 ----------------

  /// 申请二维码（无需凭据）。
  Future<Pan115QrSession?> startQr() async {
    final r = await GoCore.invokeAsync('pan115.qr.start');
    if (!r.ok) return null;
    final m = _asMap(r.result);
    if (m == null) return null;
    final uid = m['uid'] as String? ?? '';
    if (uid.isEmpty) return null;
    return Pan115QrSession(
      uid: uid,
      time: (m['time'] as num?)?.toInt() ?? 0,
      sign: m['sign'] as String? ?? '',
      qrcode: m['qrcode'] as String? ?? '',
      imageUrl: m['imageUrl'] as String? ?? '',
    );
  }

  /// 查询扫码状态。
  ///
  /// ⚠️ 这是**长轮询**：实测单次最长约 30 秒才返回（服务端在状态未变时挂住）。
  /// 因此**不要**用短间隔（如 2 秒）反复调用，否则会堆叠出大量并发长请求
  /// ——既无意义又可能触发风控。正确做法是等上一次返回后再发下一次。
  Future<Pan115QrStatus?> pollQr(Pan115QrSession s) async {
    final r = await pollQrRaw(s);
    return r.status;
  }

  /// 同 [pollQr]，但**保留失败原因**。
  ///
  /// ## 为什么需要这个"原始"版本（踩过坑）
  ///
  /// [pollQr] 把失败压成 null，而"状态为 null"与"请求失败"在下游
  /// 会变成同一种表现。原先登录页的轮询循环只判断 `st == null` 就 `continue`，
  /// 结果**错误被完全吞掉**：用户看到永远停在"等待二维码…"，
  /// 日志里一个字都没有——这种"没反应也不报错"最难排查。
  ///
  /// 所以暴露这个方法让调用方能区分两者，并在连续失败时把原因显示出来。
  Future<({bool ok, Pan115QrStatus? status, String? error})> pollQrRaw(
      Pan115QrSession s) async {
    final r = await GoCore.invokeAsync('pan115.qr.poll', s.toPayload());
    if (!r.ok) {
      // 打日志是**必要的**：这个接口依赖外部服务，出问题时必须能在
      // `adb logcat` 里看到原因。踩过的坑是"静默失败"——
      // 界面上没反应、日志里也没有，只能靠猜。
      debugPrint('[Pan115] qr.poll 失败: ${r.error}');
      return (ok: false, status: null, error: r.error ?? '未知错误');
    }
    final m = _asMap(r.result);
    if (m == null) {
      debugPrint('[Pan115] qr.poll 返回格式异常: ${r.result}');
      return (ok: false, status: null, error: '返回格式异常');
    }
    final status = Pan115QrStatus(
      status: (m['status'] as num?)?.toInt() ?? 0,
      label: m['label'] as String? ?? '',
      terminal: m['terminal'] == true,
      allowed: m['allowed'] == true,
    );
    debugPrint('[Pan115] qr.poll ok status=${status.status} '
        'label="${status.label}" allowed=${status.allowed}');
    return (ok: true, status: status, error: null);
  }

  /// 用已确认的会话换取凭据。
  ///
  /// **必须**先轮询到 [Pan115QrStatus.allowed] 为 true 再调用（原因见该字段注释）。
  Future<Pan115Credential?> finishQr(Pan115QrSession s) async {
    debugPrint('[Pan115] qr.finish 开始…');
    final r =
        await GoCore.invokeAsync('pan115.qr.finish', s.toPayload());
    if (!r.ok) {
      debugPrint('[Pan115] qr.finish 失败: ${r.error}');
      return null;
    }
    final m = _asMap(r.result);
    final cred = _asMap(m?['credential']);
    if (cred == null) {
      debugPrint('[Pan115] qr.finish 返回中没有 credential 字段');
      return null;
    }
    final c = Pan115Credential.fromJson(cred);
    if (c == null) {
      // ⚠️ 只打印**字段是否存在与长度**，绝不打印值本身——
      // 凭据等价于登录态（AGENTS.md 安全红线）。
      debugPrint('[Pan115] qr.finish 凭据不完整: '
          'uid=${cred['uid'] != null} cid=${cred['cid'] != null} '
          'seid=${cred['seid'] != null} kid=${cred['kid'] != null}');
      return null;
    }
    debugPrint('[Pan115] qr.finish 成功（凭据已取得，值不打印）');
    return c;
  }

  /// 冷启动时把安全存储里的凭据交回 Go 侧。
  ///
  /// 不这么做的话每次冷启动都要用户重新扫码——凭据本身由 Dart 侧持久化，
  /// Go 侧只在内存里持有（进程退出即消失，符合安全约定）。
  Future<bool> restoreSession(Pan115Credential cred) async {
    final r =
        await GoCore.invokeAsync('pan115.session.restore', cred.toJson());
    return r.ok;
  }

  Future<bool> isLoggedIn() async {
    final r = await GoCore.invokeAsync('pan115.session.status');
    if (!r.ok) return false;
    return _asMap(r.result)?['loggedIn'] == true;
  }

  Future<void> clearSession() async {
    await GoCore.invokeAsync('pan115.session.clear');
  }

  /// 拉取账号信息（同时用于校验凭据是否仍然有效）。
  Future<Pan115UserInfo?> userInfo() async {
    final r = await GoCore.invokeAsync('pan115.user.info');
    if (!r.ok) {
      final err = r.error ?? '';
      // 打日志是必要的：这个失败会让"已登录"被判成"未登录"，
      // 而界面只会显示"尚未登录"，看不出真实原因。
      debugPrint('[Pan115] user.info 失败: $err');
      // ★ 只有 Go 侧明确标注"需要重新登录"才算凭据失效（见 lastErrorNeedsRelogin）。
      // Go 侧在错误文案里带这句提示（见 pan115_routes.go 的 errText）。
      _record(error: err, needsRelogin: err.contains('需要重新扫码登录'));
      return null;
    }
    final m = _asMap(r.result);
    if (m == null) {
      debugPrint('[Pan115] user.info 返回格式异常: ${r.result}');
      _record(error: '返回格式异常');
      return null;
    }
    _clearError();
    final info = Pan115UserInfo(
      userName: m['user_name'] as String? ?? '',
      vipName: m['vip_name'] as String? ?? '',
      totalSize: (m['total_size'] as num?)?.toInt() ?? 0,
      usedSize: (m['used_size'] as num?)?.toInt() ?? 0,
    );
    debugPrint('[Pan115] user.info ok user="${info.userName}" '
        'vip="${info.vipName}" 空间=${info.spaceLabel}');
    return info;
  }

  // ---------------- 文件浏览 ----------------

  /// 列出某目录下的条目。
  ///
  /// [dirId] 传 '0' 或空表示根目录。
  Future<Pan115FilePage> listFiles(
    String dirId, {
    int offset = 0,
    int limit = 200,
    bool showDir = true,
  }) async {
    final r = await GoCore.invokeAsync('pan115.files.list', {
      'dirId': dirId.isEmpty ? '0' : dirId,
      'offset': offset,
      'limit': limit,
      'showDir': showDir,
    });
    if (!r.ok) return const Pan115FilePage(files: [], total: 0, offset: 0, hasMore: false);
    final m = _asMap(r.result);
    if (m == null) {
      return const Pan115FilePage(files: [], total: 0, offset: 0, hasMore: false);
    }
    return Pan115FilePage(
      files: _fileList(m['files']),
      total: (m['total'] as num?)?.toInt() ?? 0,
      offset: (m['offset'] as num?)?.toInt() ?? 0,
      hasMore: m['hasMore'] == true,
    );
  }

  /// 一次拉全某目录（Go 侧自动翻页，**串行且限速**）。
  ///
  /// ⚠️ 115 对扫库式的大量分页有风控（上游有"Emby 扫库触发 WAF 418"的实例），
  /// 故 Go 侧按 2 请求/秒串行翻页。大库会慢，这是**刻意的取舍**——
  /// 被封的是用户的账号。
  Future<List<Pan115File>> listAll(String dirId,
      {int maxPages = 20, bool showDir = true}) async {
    final r = await GoCore.invokeAsync('pan115.files.all', {
      'dirId': dirId.isEmpty ? '0' : dirId,
      'maxPages': maxPages,
      'showDir': showDir,
    });
    if (!r.ok) return const [];
    return _fileList(_asMap(r.result)?['files']);
  }

  // ---------------- 播放 ----------------

  /// 解析播放直链。
  ///
  /// [pickCode] 优先；没有时传 [itemId]，Go 侧会去反查。
  Future<Pan115Playback?> resolvePlayback({
    String pickCode = '',
    String itemId = '',
  }) async {
    final r = await GoCore.invokeAsync('pan115.play.resolve', {
      'pickCode': pickCode,
      'itemId': itemId,
    });
    if (!r.ok) return null;
    final m = _asMap(r.result);
    if (m == null) return null;
    final url = m['url'] as String? ?? '';
    if (url.isEmpty) return null;
    return Pan115Playback(
      url: url,
      headers: _stringMap(m['headers']),
      fileName: m['fileName'] as String? ?? '',
      fileSize: (m['fileSize'] as num?)?.toInt() ?? 0,
      pickCode: m['pickCode'] as String? ?? '',
    );
  }

  /// 失效本地直链缓存。
  ///
  /// 调用时机（**别搞混这两个**）：
  ///   - CDN 返回 **401/410** → 地址过期 → 调本方法后重新取地址
  ///   - CDN 返回 **403** → **限流**，不是过期：应退避等待，
  ///     **不要**调本方法反复重取（重取只会加重限流）
  Future<void> invalidateLink(String pickCode) async {
    await GoCore.invokeAsync('pan115.play.invalidate', {'pickCode': pickCode});
  }

  // ---------------- 内部解析 ----------------

  static Map<String, dynamic>? _asMap(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  static Map<String, String> _stringMap(Object? v) {
    if (v is! Map) return const {};
    return {
      for (final e in v.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  }

  static List<Pan115File> _fileList(Object? v) {
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is Map) Pan115File.fromJson(Map<String, dynamic>.from(e)),
    ];
  }
}
