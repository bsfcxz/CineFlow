/// **内置凭据的签名绑定解封**（用户要求：把 Trakt Client ID 内置进 APK）。
///
/// ## ⚠️ 先看清楚：这是**混淆（obfuscation）**，不是加密（encryption）
///
/// 我们的做法：
/// ```text
/// key = SHA-256(签名证书SHA-256 | packageName | "cineflow.trakt.v1")
/// 密文 = base64(明文 XOR key)
/// ```
/// · ✅ 挡住：**换签名重打包**、改包名搬运、`grep` 顺手拿走
/// · ❌ **挡不住反编译** —— 签名指纹本身就在 APK 里（`META-INF/*.RSA`），
///      会逆向的人能算出 key 并解出明文
///
/// ⇒ **不要把它当安全机制**。它只是"提高顺手拿走的门槛"。
///   真正的不泄露只有一条路：**凭据放服务端**（当前未采用）。
///
/// ## 与 Trakt 官方说法的关系
/// Trakt 自己在 PKCE 应用的页面写着：
/// > 客户端秘密 **未发放**。这个应用用 PKCE 登录用户，所以**没有秘密要守护**。
///
/// 实测也印证了 Client ID **不是秘密**：
/// · 它在 `POST /oauth/device/code` 的 body 里**明文传输**
/// · 换任何 UA / 伪造 Referer 都能拿到授权码（服务端**不校验来源**）
/// · 别人拿它登录只能拿到**他们自己**账号的 token（你的数据由账号密码保护）
///
/// ⇒ 所以本文件解决的是"**不想让 Client ID 明文躺在仓库/APK 里**"这个诉求，
///   而**不是**"防止别人用你的应用身份"（那做不到，见上）。
///
/// ## 与用户自填的关系（两者并存，内置优先）
/// 用户仍可在设置页填自己的 Client ID（存 `secure_storage`）。
/// · 填了 ⇒ **用他填的**（尊重用户）
/// · 没填 ⇒ 尝试解封**内置**的
/// ⇒ 这样开箱即用，同时保留可替换性。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 内置 Client ID 的**密文**（由 `tool/gen_builtin_secret.ps1` 生成）。
///
/// ## 怎么重新生成（换签名或换 Client ID 时）
/// ```bash
/// # 1. 从 APK 取签名指纹（权威工具，别用 dumpsys —— 那是另一个摘要）
/// apksigner verify --print-certs app-release.apk
/// # 2. 设环境变量后运行生成脚本
/// CF_TRAKT_CID='<你的 Client ID>' python tool/gen_builtin_secret.py
/// # 3. 把输出的 base64 贴回这里
/// ```
/// ⚠️ **生成脚本不把明文写进仓库**（只输出密文）。
const String _kBuiltinTraktCidCipher =
    'QjysjgKcTZkkErSNLAq6/N5LE/gT825CQ7KybsDr/AwEFsGoFJ99ln5zlA==';

/// 派生密钥用的盐（换盐会让所有密文失效 ⇒ 必须与生成脚本一致）。
const String _kSalt = 'cineflow.trakt.v1';

/// 签名指纹通道（Kotlin 侧 `SigningChannel`）。
const MethodChannel _signingChannel =
    MethodChannel('com.cineflow.app/signing');

/// 缓存的签名指纹（同一进程内不变，避免每次登录都过通道）。
String? _cachedSignature;

/// 取本 APK 签名证书的 SHA-256（hex 小写；null = 拿不到）。
///
/// ## 为什么拿不到时返回 null 而不是空串
/// 空串会**派生出一个错误的 key** ⇒ 解出乱码 Client ID ⇒
/// 后续请求全部 403 且**原因极难定位**（表现为"内置凭据不能用"）。
/// ⇒ 宁可返回 null，让调用方**明确知道"解封不可用"**并回退到"用户自填"。
Future<String?> signatureSha256() async {
  if (_cachedSignature != null) return _cachedSignature;
  try {
    final v = await _signingChannel.invokeMethod<String>('sha256');
    if (v == null || v.isEmpty) return null;
    _cachedSignature = v;
    return v;
  } on PlatformException catch (e) {
    // Kotlin 侧拿不到指纹时返回 error（见 SigningChannel）
    debugPrint('[BuiltinSecret] 取签名指纹失败: ${e.code}');
    return null;
  } catch (e) {
    debugPrint('[BuiltinSecret] 签名通道异常: $e');
    return null;
  }
}

/// **解封内置 Client ID**（失败返回 null，**不抛异常**）。
///
/// ## 为什么失败要静默返回 null
/// 解封失败的情形都是"环境不符"（换签名打包 / 桌面平台 / 通道不可用），
/// 那**不是错误** —— 调用方会回退到"用户自填"这条正路。
/// 抛异常会让追剧页在测试环境（`flutter test` 无原生通道）直接崩。
///
/// ## 未实测项（如实标注）
/// 该函数在**真机**上的成功路径需要"设备上装的包用的正是那个签名"，
/// 当前已用 `apksigner` 核对过本地 APK 的指纹与生成时一致；
/// **仍待真机跑通一次**（见验证记录）。
Future<String?> unsealBuiltinTraktClientId() async {
  try {
    final sig = await signatureSha256();
    if (sig == null || sig.isEmpty) {
      debugPrint('[BuiltinSecret] 无签名指纹 ⇒ 跳过硬编码凭据');
      return null;
    }
    final pkg = await _packageName();
    if (pkg == null || pkg.isEmpty) {
      debugPrint('[BuiltinSecret] 无包名 ⇒ 跳过硬编码凭据');
      return null;
    }
    final key = sha256.convert(utf8.encode('$sig|$pkg|$_kSalt')).bytes;
    final cipher = base64.decode(_kBuiltinTraktCidCipher);
    final plain = Uint8List(cipher.length);
    for (var i = 0; i < cipher.length; i++) {
      plain[i] = cipher[i] ^ key[i % key.length];
    }
    final s = utf8.decode(plain);
    if (s.isEmpty) return null;
    // 长度自检：Trakt 的 Client ID 是 64 位 hex（实测 64 字符；
    // 用户给的那个是 43 字符 base64url 形态）⇒ 只做"别太短"的下限检查，
    // 不写死长度（免得上游规则变化后失效）
    if (s.length < 20) {
      debugPrint('[BuiltinSecret] 解出的凭据长度异常(${s.length}) ⇒ 视为失败');
      return null;
    }
    return s;
  } catch (e) {
    // 解封失败**不是错误**（环境不符）⇒ 静默回退
    debugPrint('[BuiltinSecret] 解封失败（回退到用户自填）: $e');
    return null;
  }
}

/// 取包名（用于派生 key；改包名会让密文失效 —— 这是**有意**的防搬运）。
Future<String?> _packageName() async {
  try {
    return await _signingChannel.invokeMethod<String>('packageName');
  } catch (_) {
    return null;
  }
}
