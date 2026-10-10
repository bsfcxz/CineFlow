/// 弹幕源的配置与持久化。
///
/// ## 两种部署形态（认证方式完全不同）
///
/// 用户提供的两个项目与官方服务是**三种不同的接入形态**：
///
/// | 形态 | 认证 | 说明 |
/// |---|---|---|
/// | 官方 `api.dandanplay.net` | **请求头签名**（AppId+AppSecret） | 官方强制认证；客户端不得硬编码密钥 |
/// | danmu_api（自建） | **URL 路径 token**（`/{token}/api/v2/...`） | 无 header 签名；token 默认 `87654321` 可省略 |
/// | misaka_danmu_server（自建） | **URL 路径 token** | 同上，路径为 `/api/v1/{token}/api/v2/...` |
///
/// 三者**协议形状相同**（都兼容 `/api/v2/comment/{episodeId}`），
/// 差别只在 base URL 与认证方式——所以用同一个客户端 + 一个 base 前缀即可。
///
/// ## 凭据不入库（官方要求 + 本仓库红线）
///
/// 官方文档第 7 节明确：开源客户端**不应硬编码 AppSecret**，
/// 应在构建时从机密读取或用占位符。本项目更进一步——
/// **凭据完全由用户在设置页填写**，存 `flutter_secure_storage`，
/// 仓库里连占位符都不放（避免被误当成可用的默认值）。
library;

/// 弹幕源类型。
enum DanmakuProviderKind {
  /// **公共代理（内置、开箱即用、无需注册）** —— 用户要求"直接内置"。
  ///
  /// ## 为什么值得内置
  /// 官方 `api.dandanplay.net` **强制签名**（AppId+AppSecret），
  /// 而普通用户拿不到也不需要去申请 —— 结果就是"弹幕装了但用不了"。
  /// 公共代理免注册、直接可用 ⇒ 这是**默认**选项。
  ///
  /// ## 实测确认的端点形状（2026-10-10，非猜测）
  /// ```
  /// GET /api/v2/search/anime?keyword=<标题>
  ///     → {"animes":[{"animeId":17449,"animeTitle":"我推的孩子",…}]}
  /// GET /api/v2/bangumi/{animeId}
  ///     → {"bangumi":{…,"episodes":[{"episodeId":174490001,
  ///        "episodeTitle":"第1话 …","episodeNumber":"1"},…]}}
  /// GET /api/v2/comment/{episodeId}
  ///     → {"count":2,"comments":[{"cid":…,"p":"250.00,1,16647426,8ae07348","m":"…"}]}
  /// ```
  /// ## ⚠️ 与官方的**关键差异**（接错的直接后果）
  /// 官方有 `/api/v2/search/episodes?anime=&episode=` **一步**拿到
  /// episodeId；**公共代理没有这个端点**（实测 404）。
  /// 必须走 **search/anime → bangumi/{id} → episodes[]** 两步。
  /// ⇒ 客户端要按源类型分支，不能假定都是同一个搜索路径。
  ///
  /// ## 风险（如实告知用户）
  /// 这是**第三方免费实例**（uosc_danmaku 项目维护），
  /// 可能限流、变更或停服 —— 故同时保留"自建"与"官方"两条路。
  publicProxy,

  /// 官方弹弹play 开放弹幕网络（需 AppId + AppSecret 签名）
  official,

  /// 自建兼容服务（danmu_api / misaka_danmu_server）——URL token 认证
  selfHosted,

  /// 关闭弹幕
  off;

  String get label => switch (this) {
        DanmakuProviderKind.publicProxy => '公共代理（免注册，开箱即用）',
        DanmakuProviderKind.official => '弹弹play 官方（需 AppId/Secret）',
        DanmakuProviderKind.selfHosted => '自建服务（danmu_api / 御坂）',
        DanmakuProviderKind.off => '关闭',
      };

  /// 该源是否**免配置**（选上就能用，无需填地址/凭据）。
  bool get isZeroConfig => this == DanmakuProviderKind.publicProxy;
}

/// 弹幕显示模式（对照 B 站的"弹幕类型"）。
///
/// B 站播放器的弹幕设置里有「滚动 / 顶部 / 底部」三个开关，
/// 用户可以关掉某几类（比如只看滚动、不要顶部遮挡）。
/// 本项目原先只能整体开关，粒度太粗 —— 顶部弹幕常在关键画面出现，
/// 很多人只想关它。这里按 B 站的做法给出分类开关。
class DanmakuDisplayModes {
  const DanmakuDisplayModes({
    this.scroll = true,
    this.top = true,
    this.bottom = true,
  });

  /// 滚动弹幕（B 站 `p` 字段 mode=1/2/3）
  final bool scroll;

  /// 顶部固定弹幕（mode=4）
  final bool top;

  /// 底部固定弹幕（mode=5）
  final bool bottom;

  static const all = DanmakuDisplayModes();

  bool get anyOff => !scroll || !top || !bottom;

  /// 该模式是否显示（mode 值与 B 站/弹弹play 一致）
  bool allows(int mode) => switch (mode) {
        4 => top,
        5 => bottom,
        _ => scroll, // 1/2/3 都是滚动（含逆向）
      };

  DanmakuDisplayModes copyWith({bool? scroll, bool? top, bool? bottom}) =>
      DanmakuDisplayModes(
        scroll: scroll ?? this.scroll,
        top: top ?? this.top,
        bottom: bottom ?? this.bottom,
      );
}

/// 弹幕源配置。
class DanmakuConfig {
  const DanmakuConfig({
    // ★★ 默认用**公共代理**（用户要求"直接内置"）
    //
    // ## 为什么改默认值（原来是 `off`）
    // 官方源**强制签名**（AppId+AppSecret）⇒ 普通用户拿不到凭据，
    // 默认 `off` 的实际效果是"装了弹幕但永远用不了"。
    // 公共代理免注册、实测可用 ⇒ 默认它 = **开箱即用**。
    //
    // ⚠️ 用户仍可切到"关闭"/"官方"/"自建" —— 给选择，不强制。
    this.kind = DanmakuProviderKind.publicProxy,
    this.baseUrl = '',
    this.appId = '',
    this.appSecret = '',
    this.enabled = true,
    this.opacity = 1.0,
    this.fontScale = 1.0,
    this.showArea = 1.0,
    this.blockedWords = const [],
    this.useAsync = true,
    this.modes = DanmakuDisplayModes.all,
    this.speed = 1.0,
    this.bold = false,
    this.avoidSubtitle = true,
  });

  final DanmakuProviderKind kind;

  /// 自建服务的基址。
  ///
  /// **应填到 token 段为止**（不含 `/api/v2`）：
  /// 例 `http://192.0.2.10:9321` 或 `http://192.0.2.10:9321/mytoken`。
  /// 调研显示 danmu_api 对 `/api/v2` 前缀容错极强（5 种写法都 200），
  /// 但我们统一按官方拼 `/api/v2/comment/...`，所以 base 里不要重复带。
  ///
  /// > 示例用 `192.0.2.x` —— 那是 **RFC 5737 的文档专用网段**
  /// > （TEST-NET-1，永不路由到真实主机）。
  /// > **不要**为了"更像真的"改用 `192.168.x.x`：那会命中
  /// > `scripts/check-secrets.ps1` 的内网地址规则（实测提交时被拦下），
  /// > 而给门禁加白名单等于削弱它。
  final String baseUrl;

  final String appId;
  final String appSecret;

  /// 弹幕总开关（与 [kind] 的区别：kind=off 是"没配置源"，
  /// enabled=false 是"配置了但用户临时关了"）
  final bool enabled;

  final double opacity;
  final double fontScale;

  /// 显示区域（0.2–1.0）
  final double showArea;

  final List<String> blockedWords;

  /// 是否使用异步生成（仅对支持 `?async=1` 的服务有效，
  /// 即 misaka_danmu_server 2.7.0+；其他服务会静默忽略该参数）
  final bool useAsync;

  // ---- 以下为「对照 B 站」新增的显示项 ----

  /// 显示模式分类开关（滚动 / 顶部 / 底部）
  final DanmakuDisplayModes modes;

  /// 弹幕速度倍率（B 站为"弹幕速度"滑条）。
  /// 1.0 = 默认；越大弹幕飞得越快、同屏越少。
  final double speed;

  /// 是否加粗（B 站的"弹幕加粗"，弱网/小屏下更易读）
  final bool bold;

  /// 是否避开字幕区（B 站的"防挡字幕"，默认开）。
  /// 关闭后弹幕可铺满全屏，可能压住字幕。
  final bool avoidSubtitle;

  bool get isUsable {
    if (!enabled) return false;
    return switch (kind) {
      DanmakuProviderKind.off => false,
      // ★ 公共代理**免配置** ⇒ 永远可用（这正是"开箱即用"的含义）
      DanmakuProviderKind.publicProxy => true,
      DanmakuProviderKind.official => appId.isNotEmpty && appSecret.isNotEmpty,
      DanmakuProviderKind.selfHosted => baseUrl.isNotEmpty,
    };
  }

  /// 实际请求用的 base（去掉结尾斜杠，避免出现 `//api/v2`）
  String get normalizedBase {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  DanmakuConfig copyWith({
    DanmakuProviderKind? kind,
    String? baseUrl,
    String? appId,
    String? appSecret,
    bool? enabled,
    double? opacity,
    double? fontScale,
    double? showArea,
    List<String>? blockedWords,
    bool? useAsync,
    DanmakuDisplayModes? modes,
    double? speed,
    bool? bold,
    bool? avoidSubtitle,
  }) =>
      DanmakuConfig(
        kind: kind ?? this.kind,
        baseUrl: baseUrl ?? this.baseUrl,
        appId: appId ?? this.appId,
        appSecret: appSecret ?? this.appSecret,
        enabled: enabled ?? this.enabled,
        opacity: opacity ?? this.opacity,
        fontScale: fontScale ?? this.fontScale,
        showArea: showArea ?? this.showArea,
        blockedWords: blockedWords ?? this.blockedWords,
        useAsync: useAsync ?? this.useAsync,
        modes: modes ?? this.modes,
        speed: speed ?? this.speed,
        bold: bold ?? this.bold,
        avoidSubtitle: avoidSubtitle ?? this.avoidSubtitle,
      );
}

/// 服务地址归一化与校验（纯逻辑，可单测）。
///
/// 用户手填地址极易出错：漏 `http://`、多尾斜杠、粘贴时带了
/// `/api/v2/...` 路径。这些都会让请求 404 且现象是"没有弹幕"——
/// 所以在这里统一纠正，并把情况反馈给 UI。
abstract final class DanmakuUrl {
  /// 规范化用户输入的基址。
  ///
  /// 返回 (规范化后的 base, 提示信息)。提示为 null 表示无需提醒。
  ///
  /// 处理规则：
  ///   - 无协议头 → 补 `http://`（自建服务多为内网 http，不像公网必须 https）
  ///   - 去掉尾部斜杠
  ///   - **剥掉误粘贴的 `/api/v2...` 及其后内容**（客户端会自己拼）
  static (String, String?) normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return ('', null);

    String? note;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
      note = '已自动补上 http://（自建服务通常为内网 http）';
    }

    // 剥掉误粘贴的接口路径。
    //
    // ⚠️ 必须取**所有标记中最早出现的位置**，不能"按标记列表顺序找到就停"：
    // 输入 `.../tok/api/v1/api/v2/x` 时，先查 `/api/v2` 会命中更靠后的位置，
    // 截断后残留 `/api/v1`。（这是首版被测试抓出来的 bug。）
    final lower = s.toLowerCase();
    var cut = -1;
    for (final marker in const ['/api/v2', '/api/v1', '/api/']) {
      final idx = lower.indexOf(marker);
      if (idx > 0 && (cut < 0 || idx < cut)) cut = idx;
    }
    if (cut > 0) {
      s = s.substring(0, cut);
      note = '已自动去掉末尾的接口路径（只需填到地址/token 为止）';
    }

    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return (s, note);
  }

  /// 校验基址是否可用。
  ///
  /// 返回 null 表示可用，否则返回中文原因。
  static String? validate(String normalized) {
    if (normalized.isEmpty) return '请填写服务地址';
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return '地址格式不正确（示例：http://192.0.2.10:9321）';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '只支持 http / https 协议';
    }
    return null;
  }
}
