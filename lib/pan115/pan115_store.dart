/// 115 凭据的安全存储与 riverpod 接线。
///
/// ## 安全约定（AGENTS.md 安全红线）
///
/// 115 的凭据四项（UID/CID/SEID/KID）**等价于账号登录态**——
/// 拿到它就等于登进了用户的网盘。因此：
///   - 只存 `flutter_secure_storage`（Android Keystore），与 Emby 凭据同一套保护
///   - **绝不写入 drift/SQLite、绝不写日志、绝不入库**
///   - Go 侧只在内存里持有（进程退出即消失）
///
/// ## 为什么凭据存在 Dart 侧而不是 Go 侧
///
/// Go 侧的会话表在原生内存中，进程结束就没了。若让 Go 负责持久化，
/// 就等于把凭据交给原生层写文件，既绕过了平台的安全存储，
/// 也让"清除凭据"变得难以保证。放 Dart 侧由 `flutter_secure_storage` 管理，
/// 冷启动时再通过 `pan115.session.restore` 交回 Go。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/go_core.dart';
import '../data/session_store.dart';
import '../state/providers.dart' show sessionStoreProvider;
import 'pan115_client.dart';

/// 115 凭据的读写。
///
/// 复用 `SessionStore` 的安全存储后端：它在生产下是
/// `flutter_secure_storage`（Android Keystore），与 Emby 凭据同一套保护；
/// 在测试下 `SessionStore` 可注入内存实现（见 danmaku_persist_test）。
///
/// > 注意这里包的是 `SessionStore` 而**不是** `SecureKv`：
/// > `sessionStoreProvider` 的类型就是 `Provider<SessionStore>`，
/// > 它的 `provider` 是私有的，外部拿不到底层 KV。
/// > 通过 `SessionStore` 暴露的两个方法转发即可，无需访问其内部。
class Pan115Store {
  const Pan115Store(this._store);

  final SessionStore _store;

  // getPref/setPref 内部会统一加 cf_pref_ 前缀，故这里不要重复前缀。
  // 实际存储键为 cf_pref_pan115_cred。
  static const _key = 'pan115_cred';

  /// 读取已存凭据；没有或损坏时返回 null。
  ///
  /// 损坏时返回 null 而不是抛异常：一个坏的存储值不该让"我的"页崩掉，
  /// 最坏情况是用户重新扫码。
  Future<Pan115Credential?> loadCredential() async {
    try {
      final raw = await _store.getPref(_key);
      if (raw == null || raw.isEmpty) {
        // 打日志：这一句能区分"从没存过"与"存了但读不出来"——
        // 两者在界面上都表现为"尚未登录"，不打日志就只能靠猜。
        debugPrint('[Pan115] 本地无凭据（key=$_key）');
        return null;
      }
      final m = jsonDecode(raw);
      if (m is! Map) {
        debugPrint('[Pan115] 本地凭据不是对象，已忽略');
        return null;
      }
      final cred = Pan115Credential.fromJson(Map<String, dynamic>.from(m));
      // 只打印字段是否存在，绝不打印值（安全红线）
      debugPrint('[Pan115] 本地凭据读取: '
          'uid=${(m['uid'] ?? m['UID']) != null} '
          'cid=${(m['cid'] ?? m['CID']) != null} '
          'seid=${(m['seid'] ?? m['SEID']) != null} → '
          '${cred == null ? "无效" : "有效"}');
      return cred;
    } catch (e) {
      debugPrint('[Pan115] 本地凭据读取异常: $e');
      return null;
    }
  }

  Future<void> saveCredential(Pan115Credential c) => _store.setPref(
        _key,
        jsonEncode({
          'uid': c.uid,
          'cid': c.cid,
          'seid': c.seid,
          'kid': c.kid,
          'userName': c.userName,
        }),
      );

  /// 清除凭据（退出登录）。
  ///
  /// 同时清 Go 侧内存会话：只清存储不清内存的话，
  /// 用户"退出登录"后当前进程仍能用旧凭据访问网盘——属安全缺陷。
  Future<void> clear() => _store.setPref(_key, '');
}

final pan115StoreProvider = Provider<Pan115Store>(
  (ref) => Pan115Store(ref.watch(sessionStoreProvider)),
);

/// 115 客户端。
final pan115ClientProvider = Provider<Pan115Client>((ref) {
  return const Pan115Client();
});

/// 115 客户端的全局开关与额度（供 UI 显示与切换）。
///
/// 独立成一个 provider 而不是塞进 [pan115SessionProvider]：
/// 开关**不依赖登录状态**（未登录也要能看/改），
/// 混在一起会让"未登录时无法停用"这种反直觉行为出现。
final pan115SwitchProvider = FutureProvider<
    ({bool enabled, int usedToday, int dailyCap, bool capReached})?>((ref) async {
  // Go 不可用时无法读取开关；返回 null 让 UI 显示为"停用"（最安全的一侧）。
  if (!GoCore.available) return null;
  return ref.watch(pan115ClientProvider).pan115Switch();
});

/// 当前是否已登录 115。
///
/// 冷启动时会尝试用安全存储里的凭据恢复 Go 侧会话。
///
/// ## ⚠️ 只有"确定凭据失效"才清除本地凭据（踩过坑）
///
/// 首版写的是"`userInfo` 拿不到就清凭据"，结果**误删了有效凭据**：
/// 当时 `user.info` 因为一个**解析 bug**（`face` 字段形状）失败，
/// 而清理逻辑把它当成"凭据失效"，于是用户刚扫码成功就被踢回未登录。
///
/// 教训：**"我解析失败"与"凭据真的失效"是两件事**，
/// 自动清理必须只在前者被排除后才做——否则一个客户端 bug 会
/// 累积成"用户反复扫码也进不去"。
///
/// 因此现在的判定是：Go 侧**明确报出需要重新登录**（`needsRelogin`
/// 那类错误码，文案里会带"需要重新扫码登录"）才清；
/// 其它失败（网络不通、解析异常、被风控）都**保留凭据**并如实报错。
final pan115SessionProvider = FutureProvider<Pan115UserInfo?>((ref) async {
  // 依赖 Go 核心层；不可用时直接降级为"未登录"
  if (!GoCore.available) {
    debugPrint('[Pan115] Go 核心层不可用，跳过会话恢复');
    return null;
  }

  final store = ref.watch(pan115StoreProvider);
  final client = ref.watch(pan115ClientProvider);

  final saved = await store.loadCredential();
  if (saved == null) return null;

  // 把凭据交回 Go 侧（冷启动后 Go 的内存会话是空的）
  await client.restoreSession(saved);

  // 拉账号信息：既拿到展示数据，也顺带校验凭据。
  final info = await client.userInfo();
  if (info != null) return info;

  // 拿不到 —— 必须区分原因，**不能一律清凭据**。
  if (Pan115Client.lastErrorNeedsRelogin) {
    debugPrint('[Pan115] 凭据已失效（服务端明确要求重新登录），清除本地凭据');
    await store.clear();
    await client.clearSession();
    return null;
  }

  // 其它失败：保留凭据，让用户能重试（下次进页面会再试一次）。
  // 返回 null 让界面显示"尚未登录"，但**不清凭据**——
  // 这样网络恢复后重进页面就能自动恢复登录。
  debugPrint('[Pan115] 账号信息获取失败但凭据保留：${Pan115Client.lastError}');
  return null;
});
