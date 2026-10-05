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
  /// 官方弹弹play 开放弹幕网络（需 AppId + AppSecret 签名）
  official,

  /// 自建兼容服务（danmu_api / misaka_danmu_server）——URL token 认证
  selfHosted,

  /// 关闭弹幕
  off;

  String get label => switch (this) {
        DanmakuProviderKind.official => '弹弹play 官方',
        DanmakuProviderKind.selfHosted => '自建服务（danmu_api / 御坂）',
        DanmakuProviderKind.off => '关闭',
      };
}

/// 弹幕源配置。
class DanmakuConfig {
  const DanmakuConfig({
    this.kind = DanmakuProviderKind.off,
    this.baseUrl = '',
    this.appId = '',
    this.appSecret = '',
    this.enabled = true,
    this.opacity = 1.0,
    this.fontScale = 1.0,
    this.showArea = 1.0,
    this.blockedWords = const [],
    this.useAsync = true,
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

  bool get isUsable {
    if (!enabled) return false;
    return switch (kind) {
      DanmakuProviderKind.off => false,
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
