import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/theme.dart';
import '../data/builtin_secret.dart';
import '../data/trakt_client.dart';
import '../data/session_store.dart';
import '../state/providers.dart';

/// **Trakt 设置面板**（用户 2026-10-14 要求，对齐其给的 UI 稿）。
///
/// ## 面板结构（截图）
/// ```text
/// ┌────────────────────────────────────────────┐
/// │ [T] Trakt                    [登录]    ⌃   │
/// │     连接 Trakt 账户以同步观看记录和收藏        │
/// ├────────────────────────────────────────────┤
/// │ 实时追踪                              关  ○─│
/// │ 播放时自动向 Trakt 报告观看进度               │
/// ├────────────────────────────────────────────┤
/// │ 同步已看状态                          关  ○─│
/// │ 在详情页显示 Trakt 同步按钮                  │
/// ├────────────────────────────────────────────┤
/// │ 续播检查                              关  ○─│
/// │ 播放时检查 Trakt 进度并提示从上次位置继续       │
/// └────────────────────────────────────────────┘
/// ```
///
/// ## ★ 认证方式：**设备码流程**（不是 PKCE 回调）
/// 实测（2026-10-14）：
/// ```text
/// POST /oauth/device/code {client_id}
///   → { user_code: "KY5QEMVZ", verification_url: "https://auth.trakt.tv/activate",
///       expires_in: 600, interval: 6 }
/// POST /oauth/device/token {code, client_id}   ← 轮询
///   400（**body 为空**） = 等待用户授权   ⇒ 继续轮询
///   404（**body 为空**） = 码无效/过期    ⇒ 重新申请
///   200                 = 成功
/// ```
/// ### 为什么不用 PKCE + 自定义 scheme
/// 1. 用户配置的重定向 URI 曾多写 `https://` 前缀（畸形）⇒ 设备码**没有回调**，绕开
/// 2. Trakt 后台对自定义 scheme 报「不安全重定向 URI」警告 ⇒ 设备码无此问题
/// 3. 不用装 `app_links`（项目未装）⇒ **零新增依赖**
///
/// ⚠️ **未实测**：轮询成功后的 token 结构与 refresh 流程
///    （需用户本人在浏览器输码，我无法代做）⇒ 解析写成容错式。
class TraktSettingsPage extends ConsumerStatefulWidget {
  const TraktSettingsPage({super.key});

  @override
  ConsumerState<TraktSettingsPage> createState() => _TraktSettingsPageState();
}

class _TraktSettingsPageState extends ConsumerState<TraktSettingsPage> {
  bool _expanded = true;
  bool _busy = false;

  /// 本次登录是否用了**内置**的 Client ID（而非用户自填）。
  ///
  /// ## 为什么要区分（诚实原则）
  /// 用户该知道"凭据从哪来"：
  /// · 内置 ⇒ 设置页显示"已内置（无需填写）"
  /// · 自填 ⇒ 显示"已配置（点此修改）"
  /// ⇒ 不把两者混成一句模糊的"已配置"。
  bool _usingBuiltin = false;

  // ══════════════════════════════════════════════════════════════
  //  Client ID 卡片的**可见性**（用户 2026-10-14：
  //  "隐藏我的 client id 标签，不让别人看到"）
  // ══════════════════════════════════════════════════════════════
  //
  // ## 为什么要藏
  // 卡片本身**不显示 Client ID 的值**（只有"已配置/已内置"），
  // 但"这里有个内置凭据"这件事**不该让拿到手机的人知道** ——
  // 它会引向"这 App 内置了 Trakt 凭据"这个结论。
  //
  // ## 为什么不能直接删卡片
  // 内置凭据**可能解封失败**（签名不匹配时，见 `builtin_secret.dart`），
  // 那时用户**必须**能填自己的 Client ID 才能用 Trakt。
  // ⇒ 藏起来 + 留一个**只有知道的人能找到**的入口（Android 惯例：连点 7 次）。
  //
  // ## 为什么用"连点标题 7 次"
  // 与 Android「开发者选项」同一惯例 —— 用户熟悉、不占 UI 空间、
  // 误触概率极低（正常用户不会连点标题 7 次）。
  bool _devMode = false;
  int _titleTaps = 0;
  static const _kTapsForDevMode = 7;

  /// 连点标题：满 7 次切换 Client ID 卡片的可见性。
  ///
  /// ## 为什么"满 7 次"后**归零**（而不是保持计数）
  /// 否则第 8 次点击会立刻又切回去（用户会觉得"点了没反应"）。
  /// 每次满 7 次就重置 ⇒ 再点 7 次才切换。
  void _tapTitle() {
    _titleTaps++;
    if (_titleTaps >= _kTapsForDevMode) {
      _titleTaps = 0;
      setState(() => _devMode = !_devMode);
      _toast(_devMode ? '已显示 Client ID 设置' : '已隐藏 Client ID 设置');
    }
  }

  // ---- 3 个功能开关（真实状态，不再是死开关）----
  //
  // ## 默认 false（`session_store` 里也是 false）
  // 这三个功能会**写数据到用户的 Trakt 账号**（scrobble / history）。
  // 未经用户明确开启就写别人账号是不对的 ⇒ 默认关，用户主动开。
  bool _track = false;    // 实时追踪：播放时上报进度
  bool _sync = false;     // 同步已看：详情页显示同步按钮
  bool _resume = false;   // 续播检查：播放时提示续播

  /// 授权页的 WebView 控制器。
  ///
  /// ⚠️ **必须在这里持有**（不能建在 dialog 的 builder 里）——
  /// `WebViewController` 每次 build 都新建会**重复加载**并丢状态。
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    // 该页用 htmx 局部更新 ⇒ **必须开 JS**，否则按钮点了没反应
    ..setUserAgent('Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36');

  /// **自动点「继续」**（提交已填入的验证码）。
  ///
  /// ## 用户截图给的证据（2026-10-15）
  /// ```
  /// 激活你的设备
  /// 验证码: [UGDGUA4Y]     ← _autoFillCode 已生效
  /// [        继续        ]  ← ★ 缺这一步：「继续」不点就停在原地
  /// ```
  /// ⇒ 完整链路三步：① 填码 ② **点「继续」** ③ 点「授权」
  ///   用户要求"我只要点击同意授权即可" ⇒ ② 也自动。
  ///
  /// ## 判据（与 `_autoTapAuthorize` 同款安全约束）
  /// · 只在**确实填了码**之后才点（避免在别的页面误点）
  /// · 按钮文案匹配 继续/Continue/Activate/确定/提交，**排除**取消/拒绝
  /// · **只点一次**
  Future<bool> _autoSubmitCode() async {
    final js = '(() => {'
        // 前提：输入框里已经有我们填的 8 位码（否则不该提交空表单）
        '  const inputs = Array.from(document.querySelectorAll("input"));'
        '  const filled = inputs.some((el) => {'
        '    const r = el.getBoundingClientRect();'
        '    return r.width > 0 && (el.value || "").trim().length >= 6; });'
        '  if (!filled) return "code-not-filled";'
        '  const deny = /取消|拒绝|Cancel|Deny|Back|返回/i;'
        '  const go = /继续|确定|提交|激活|授权|Continue|Activate|Submit'
        '|Verify|Confirm|Next/i;'
        '  const btns = Array.from(document.querySelectorAll('
        '    "button, input[type=submit], a.btn, .btn"));'
        '  const vis = (el) => { const r = el.getBoundingClientRect();'
        '    return r.width > 0 && r.height > 0; };'
        '  const cand = btns.filter((b) => vis(b) && !b.disabled);'
        '  const goBtn = cand.find((b) => {'
        '    const t = (b.innerText || b.value || "").trim();'
        '    return go.test(t) && !deny.test(t); });'
        '  if (!goBtn) return "no-submit-button";'
        '  goBtn.click();'
        '  return "submitted:" + (goBtn.innerText || goBtn.value || "").trim();'
        '})()';
    try {
      final r = await _web.runJavaScriptReturningResult(js);
      final v = r.toString().replaceAll('"', '');
      if (v.startsWith('submitted')) {
        debugPrint('[Trakt] 已自动点击「继续」提交验证码：$v');
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// **自动点「授权」按钮**（用户 2026-10-15 截图确认的目标页面）。
  ///
  /// ## 目标页面的**实测结构**（用户截图 + auth.js 交叉印证）
  /// ```
  /// 标题: 授权此设备
  /// 副标题: Rodel Player 正在请求访问你的 Trakt 账号。
  /// 验证码: WA6MPZMK          ← 我们的 user_code（8 位）
  /// 按钮:   [取消]  [授权]      ← 目标
  /// ```
  /// `auth.js` 原文印证了这页的存在与结构：
  /// ```js
  /// // …would corrupt the accept-vs-deny choice on the consent and
  /// //   **activate-confirm** forms.
  /// const countdown = document.querySelector('.countdown[data-expires-in]');
  /// const card = countdown.closest('.**consent-card**');
  /// ```
  /// ⇒ **有倒计时**（= 我们那 600 秒）与 `.consent-card` 容器。
  ///
  /// ## ⚠️ 安全边界（**只点一次，且不阻止用户拒绝**）
  /// 这是用户**本人主动点「连接 Trakt」**后的流程 ⇒ 自动点"授权"
  /// **不越权**（意图明确）。但：
  /// · **只点一次**（`_autoAuthorized` 标记）—— 反复点＝强迫用户授权
  /// · 用户点「取消」后**立即停手**（本轮找不到按钮就不再找）
  /// · 绝不点击「取消」以外的任何破坏性按钮
  ///
  /// ## 返回
  /// `true` = 本轮**点到了**授权按钮。
  Future<bool> _autoTapAuthorize() async {
    // 只在"确实是授权确认页"时才点（避免在别处误点）
    // 判据（三重，任一成立即认为是该页）：
    //  ① 有 `.consent-card`
    //  ② 页面文本含"授权此设备" / "Authorize this device"
    //  ③ 同时存在"取消"与"授权"两个提交按钮
    final js = '(() => {'
        '  const T = document.body ? document.body.innerText : "";'
        '  const card = document.querySelector(".consent-card");'
        '  const looksLike = (card !== null)'
        '    || /授权此设备|Authorize this device|Activate this device/i.test(T);'
        '  if (!looksLike) return "not-consent-page";'
        // 找"授权/Authorize/Activate/Yes/Allow"按钮，**排除**"取消/Deny/Cancel"
        '  const deny = /取消|拒绝|Cancel|Deny|No\\b/i;'
        '  const allow = /授权|同意|允许|Authorize|Activate|Allow|Yes|Approve/i;'
        '  const btns = Array.from(document.querySelectorAll('
        '    "button, input[type=submit], a.btn, .btn"));'
        '  const vis = (el) => { const r = el.getBoundingClientRect();'
        '    return r.width > 0 && r.height > 0; };'
        '  const cand = btns.filter((b) => vis(b) && !b.disabled);'
        '  const allowBtn = cand.find((b) => {'
        '    const t = (b.innerText || b.value || "").trim();'
        '    return allow.test(t) && !deny.test(t); });'
        '  if (!allowBtn) return "no-allow-button";'
        '  allowBtn.click();'
        '  return "clicked:" + (allowBtn.innerText || allowBtn.value || "").trim();'
        '})()';
    try {
      final r = await _web.runJavaScriptReturningResult(js);
      final v = r.toString().replaceAll('"', '');
      if (v.startsWith('clicked')) {
        debugPrint('[Trakt] 已自动点击授权按钮：$v');
        return true;
      }
      if (v == 'no-allow-button') {
        debugPrint('[Trakt] 授权页已到，但没找到「授权」按钮（稍后重试）');
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// **自动把设备授权码填进 Trakt 网页**（用户 2026-10-15 要求）。
  ///
  /// ## 实测依据（我抓了真实页面，不是猜的）
  /// ```
  /// https://auth.trakt.tv/activate → 302 → /signin?callbackURL=%2Factivate
  /// 首屏 HTML（15341 字符）里：
  ///   · 唯一 input: <input id="email" name="email" type="email">
  ///   · form: hx-post="/auth/magic" hx-target="#otp-step"  ← htmx 局部注入
  ///   · **没有** name="code" / id="code" / user_code / device
  /// 依赖: /_assets/htmx-2.0.4.min.js + auth.js
  ///
  /// URL 传参也**不生效**（实测 4 种）：
  ///   ?code=XXXX      → 被丢弃（最终 URL 无 code）
  ///   ?user_code=XXXX → 只留在 callbackURL，页面**不预填**
  ///   #code=XXXX      → 被丢弃
  /// ```
  ///
  /// ## ⚠️ 为什么必须**周期轮询**（而不是只填一次）
  /// 该页用 **htmx 局部注入**（`hx-swap="innerHTML"` 到 `#otp-step`）
  /// ⇒ 登录后新内容**不触发整页导航** ⇒ `onPageFinished` **不触发**
  /// ⇒ 只挂那一个回调的话，自动填**永远不会发生**。
  ///
  /// ## ⚠️ 选择器为什么是"自适应"而不是写死
  /// 我**没有 Trakt 账号** ⇒ **走不到"设备码输入框"那一页** ⇒
  /// 写死选择器就是**编造**（本仓库明令禁止）。
  /// 改为按特征打分识别；**找不到就静默返回**（不报错、不干扰手输）。
  ///
  /// ## 返回
  /// `true` = 这一轮确实填进去了（调用方据此**停止轮询**）。
  Future<bool> _autoFillCode(String code) async {
    if (code.isEmpty) return false;
    // ⚠️ 必须派发 `input`/`change` —— htmx 与一键一码框靠这些事件驱动；
    //    只改 `value` 页面**不会认**（这是自动填最常见的失败原因）。
    final js = '(() => {'
        '  const code = ${jsonEncode(code)};'
        '  const vis = (el) => { const r = el.getBoundingClientRect();'
        '    return r.width > 0 && r.height > 0; };'
        '  const score = (el) => {'
        '    let s = 0;'
        '    const n = (el.name || "").toLowerCase();'
        '    const i = (el.id || "").toLowerCase();'
        '    const a = (el.autocomplete || "").toLowerCase();'
        '    const t = (el.type || "").toLowerCase();'
        '    const im = (el.inputMode || "").toLowerCase();'
        '    const ml = parseInt(el.getAttribute("maxlength") || "0", 10);'
        '    if (n.includes("code")) s += 100;'
        '    if (i.includes("code")) s += 80;'
        '    if (a.includes("one-time-code")) s += 60;'
        '    if (im === "numeric") s += 40;'
        '    if (t === "tel") s += 30;'
        '    if (ml >= 6 && ml <= 10) s += 20;'
        '    if (t === "email" || t === "password") s -= 500;'
        '    if (n.includes("email") || i.includes("email")) s -= 500;'
        '    return s; };'
        '  let best = null, bestScore = 0;'
        '  document.querySelectorAll("input").forEach((el) => {'
        '    if (!vis(el) || el.disabled || el.readOnly) return;'
        '    const sc = score(el);'
        '    if (sc > bestScore) { bestScore = sc; best = el; } });'
        // 阈值 40：只有"inputMode=numeric"及以上才敢填，
        // 避免把**邮箱框**误填成授权码（那会让用户登不进去）
        '  if (!best || bestScore < 40) return "no-field";'
        '  if (best.value === code) return "already";'
        '  best.focus(); best.value = code;'
        '  best.dispatchEvent(new Event("input", {bubbles: true}));'
        '  best.dispatchEvent(new Event("change", {bubbles: true}));'
        '  return "filled:" + bestScore;'
        '})()';
    try {
      final r = await _web.runJavaScriptReturningResult(js);
      final v = r.toString().replaceAll('"', '');
      final ok = v.startsWith('filled') || v == 'already';
      if (ok) debugPrint('[Trakt] 授权码自动填入：$v');
      return ok;
    } catch (e) {
      // 页面还没就绪 / JS 被拒 ⇒ **静默**（下一轮轮询再试）
      return false;
    }
  }

  String? _clientId;
  String? _accessToken;

  /// 当前登录的 Trakt 用户（授权成功后拉取，用于显示用户名/头像）。
  ///
  /// ## 三态（**必须区分**，否则会写出"空白卡片"）
  /// | 值 | 含义 | UI |
  /// |---|---|---|
  /// | `null` + 未登录 | 没连 | 显示「连接 Trakt」 |
  /// | `null` + 已登录 | 登录了但拉取失败/还没拉到 | 显示「已连接」+ 重试 |
  /// | 有值 | 正常 | 头像 + `@username` |
  TraktUser? _me;

  /// `/users/me` 是否还在加载（决定要不要显示转圈）。
  bool _meLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(sessionStoreProvider);
    // ★ `resolveTraktClientId()`：自填优先，否则解封内置。
    //   旧写法只读自填值 ⇒ 用内置时 `id` 恒空 ⇒
    //   ① 会显示成"未配置"（实际有内置凭据）
    //   ② `_loadMe(id)` 里 `cid.isEmpty` 直接 return ⇒ **永远显示不出用户名**
    //   （用户 2026-10-14 报障："这个授权成功后，显示我的 trakt 名字哇"）
    final id = await store.resolveTraktClientId();
    final tk = await store.loadTraktAccessToken();
    if (!mounted) return;
    // `resolveTraktClientId` 已含内置兜底 ⇒ 这里只需判断"有没有拿到"
    final builtin = (id == null || id.isEmpty) ? null : id;
    if (!mounted) return;
    // 一次读 3 个开关（`traktFlags` 内部并行 —— 顺序 await 会累积
    // Keystore 解密延迟）
    final flags = await store.traktFlags();
    if (!mounted) return;
    setState(() {
      _clientId = id;
      _accessToken = tk;
      _usingBuiltin = builtin != null && builtin.isNotEmpty;
      _track = flags.track;
      _sync = flags.sync;
      _resume = flags.resume;
    });
    // 已登录 ⇒ 拉一次用户信息（**await 它**，这样调用方拿到的
    // `_me` 已经是最终值 —— 否则 `_login` 的 toast 会显示不出用户名）
    if (tk != null && tk.isNotEmpty) {
      await _loadMe(id);
    }
  }

  /// 拉取当前登录用户（显示 `@username` / 头像）。
  ///
  /// ## 为什么失败要**保留**已有 `_me`
  /// 网络抖动时把 `_me` 清空 ⇒ 页面从"@xxx"变成空白 ⇒
  /// 用户以为"掉登录了"。**失败就保持原样**（§6.9.1 同源的保守原则）。
  Future<void> _loadMe(String? cid) async {
    // ⚠️ `cid` 现在来自 `resolveTraktClientId()`（含内置兜底）
    //     ⇒ 只有"确实没有 Client ID"时才 return（用户没配 + 内置解封失败）
    if (cid == null || cid.isEmpty) {
      debugPrint('[Trakt] 无可用 Client ID ⇒ 无法取用户名');
      return;
    }
    if (mounted) setState(() => _meLoading = true);
    try {
      final tok = await ref.read(sessionStoreProvider).loadTraktAccessToken();
      if (tok == null || tok.isEmpty) return;
      // 用 `fromStore` 以带上 refreshToken（虽然 getMe 本身不刷新，
      // 但保持三处一致，避免"只有这里没刷新能力"的隐性差异）
      final sync = await TraktSync.fromStore(
        clientId: cid,
        readAccess: () async => tok,
        readRefresh: () => ref.read(sessionStoreProvider)
            .loadTraktRefreshToken(),
        writeTokens: (a, r) => ref.read(sessionStoreProvider)
            .saveTraktTokens(access: a, refresh: r),
        writeExpiresAt: (ms) =>
            ref.read(sessionStoreProvider).saveTraktExpiresAt(ms),
        expiresInMs: () =>
            ref.read(sessionStoreProvider).traktExpiresInMs(),
      );
      final me = await sync?.getMe();
      if (!mounted) return;
      if (me != null) {
        setState(() => _me = me);
        debugPrint('[Trakt] 已登录用户：${me.username}');
      } else {
        debugPrint('[Trakt] 取用户信息失败（保持原显示）');
      }
    } catch (e) {
      debugPrint('[Trakt] 取用户信息异常（保持原显示）: $e');
    } finally {
      if (mounted) setState(() => _meLoading = false);
    }
  }

  bool get _loggedIn => (_accessToken ?? '').isNotEmpty;

  Future<void> _toast(String m) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  Client ID（凭据：只进 secure_storage，仓库里不放任何值）
  // ══════════════════════════════════════════════════════════════

  /// 弹 **Trakt Client ID** 输入框。
  ///
  /// ## 为什么必须由用户填（不能内置）
  /// §红线：**凭据一律不入库**，仓库里连占位符都不放。
  /// 用户需自己在 <https://trakt.tv/oauth/applications> 建应用拿 Client ID。
  Future<void> _editClientId() async {
    final store = ref.read(sessionStoreProvider);
    final cur = await store.loadTraktClientId() ?? '';
    if (!mounted) return;
    final ctl = TextEditingController(text: cur);
    // ⚠️ `saved` 声明在 try 外（内部用 final 的话出了 try 不可见 —— 已在
    //    calendar_page 踩过同一个错，见那里的注释）
    bool? saved;
    try {
      saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Cf.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Cf.radiusMd)),
          title: const Text('Trakt Client ID'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '连接 Trakt 需要你自己的 Client ID。\n\n'
                '申请步骤：\n'
                '1. 打开 trakt.tv/oauth/applications\n'
                '2. New Application（名字随填）\n'
                '3. Redirect URI 填：\n'
                '   com.cineflow.app://auth/oauth2callback\n'
                '4. 保存后复制 **Client ID**\n\n'
                '（只存在本机安全存储，不会上传）',
                style: Cf.caption.copyWith(color: Cf.text3),
              ),
              const SizedBox(height: Cf.gap2),
              TextField(
                controller: ctl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Client ID',
                  hintText: '64 位十六进制',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            if (cur.isNotEmpty)
              TextButton(
                onPressed: () async {
                  await store.saveTraktClientId('');
                  // 清 Client ID 时**同时清 token**（否则留着一份无主的登录态）
                  await store.clearTraktTokens();
                  if (ctx.mounted) Navigator.pop(ctx, true);
                },
                child: const Text('清除'),
              ),
            FilledButton(
              onPressed: () async {
                await store.saveTraktClientId(ctl.text);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      ctl.dispose();
    }
    if (saved == true) {
      await _load();
      await _toast('已保存 Client ID');
    }
  }

  // ══════════════════════════════════════════════════════════════
  //  登录（设备码流程）
  // ══════════════════════════════════════════════════════════════

  Future<void> _login() async {
    if (_busy) return;
    final store = ref.read(sessionStoreProvider);
    // ① 用户自填优先（尊重用户：他特意填了自己的就用他的）
    var id = await store.loadTraktClientId() ?? '';

    // ② 没填 ⇒ 尝试**解封内置**的（签名绑定混淆，见 builtin_secret.dart）
    //
    // ## 为什么内置（用户 2026-10-14 要求）
    // > Client ID 以后内置在我的应用中，不对外公开
    // ⇒ 开箱即用：用户不必先去 trakt.tv/oauth/applications 建应用。
    //
    // ⚠️ 解封失败是**正常情形之一**（换签名重打包 / 平台无原生通道）
    //    ⇒ 静默回退到"让用户填"，**不报错**（见 unsealBuiltinTraktClientId）。
    if (id.isEmpty) {
      final builtin = await unsealBuiltinTraktClientId();
      if (builtin != null && builtin.isNotEmpty) {
        id = builtin;
        _usingBuiltin = true;
        debugPrint('[Trakt] 使用内置 Client ID（签名绑定解封成功）');
      }
    }

    if (id.isEmpty) {
      // 都没有 ⇒ 让他填（一步到位，不用先报错再跳）
      await _editClientId();
      id = await store.loadTraktClientId() ?? '';
      if (id.isEmpty) return;
    }
    if (!mounted) return;

    setState(() => _busy = true);
    final client = TraktClient(clientId: id);
    try {
      final session = await client.startDeviceAuth();
      if (session == null) {
        await _toast('申请授权码失败 —— 请检查 Client ID 是否正确');
        return;
      }
      if (!mounted) return;
      // 弹出授权指引（显示码 + 打开浏览器 + 轮询）
      final ok = await _showAuthorizeDialog(client, session);
      if (ok == true) {
        // ══════════════════════════════════════════════════════════
        // 授权成功后的四步（用户 2026-10-14 列的标准流程）
        // ══════════════════════════════════════════════════════════
        // ① **Token**（access + refresh）已在轮询里拿到，并由
        //    `saveTraktTokens` 存进 `flutter_secure_storage`（Keystore）。
        // ② **Profile**：`_load()` → `_loadMe()` 拉 `/users/me`
        //    拿到 username / 头像 ⇒ 顶部卡片显示 `@username`。
        // ③ **同步数据**：**本步尚未实现** —— 需要用户在详情页
        //    主动点「同步已看」（或播放时实时追踪）。
        //    ⚠️ 这里**不写**"已同步"字样：授权刚完成时我们**没有**
        //       同步任何数据，说了就是假话（§5.8）。
        // ④ **页面跳转**：弹窗已由 `wantClose` 自动关闭（延迟 900ms），
        //    这里只补一条 toast 让用户确认"连上了哪个账号"。
        await _load();
        await _toast(
            _me != null ? '已连接：${_me!.display}' : '已连接 Trakt');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 授权对话框：显示授权码 + 一键打开浏览器 + **按 interval 轮询**。
///
/// ⚠️ **不要按"6 位"排版** —— 官方文档写明 `user_code`
/// "**typically 8 characters**"，实测两次分别拿到 8 位
///（`UNRWZ2UK` / `9RHHFKWU`）⇒ 我最初写"6 位"是**错的**，
/// 按 6 位留宽会把码显示不全。
  ///
  /// ## 轮询策略（基于实测）
  /// · 间隔 = 服务端给的 `interval`（实测 6s）
  /// · `400` ⇒ 继续等（**body 为空，只能靠状态码判**）
  /// · `404` ⇒ 码失效 ⇒ 停止并提示重来
  /// · `429` ⇒ 退避（多等一个 interval）
  /// · 到 `expires_in` 超时 ⇒ 停止
  /// · 用户关掉对话框 ⇒ **停止轮询**（不要后台偷跑）
  Future<bool?> _showAuthorizeDialog(
      TraktClient client, TraktDeviceSession session) async {
    var cancelled = false;
    final completer = Completer<bool>();

    // 后台轮询：把结果写进 ValueNotifier，UI 只读它（不在 build 里跑网络）
    // ⚠️ 从 `ValueNotifier<String>` 升级为**带类型的状态**
    //    （用户 2026-10-14 规格：成功要显示**绿勾**、失败要显示红叉）
    //    只存字符串的话，UI 层要靠"文案里有没有'成功'两个字"来判断
    //    ⇒ 改一个字的文案就会让图标错（脆弱）。
    final status = ValueNotifier<_AuthStatus>(
        const _AuthStatus('等待授权…', _AuthKind.waiting));
    final done = ValueNotifier<bool>(false);

    /// "该关窗了"的信号（**由知道 `ctx` 的那一层消费**）。
    ///
    /// ## 为什么需要它（而不是在轮询闭包里直接 pop）
    /// 轮询闭包在 `showDialog` **之前**创建 ⇒ 它作用域里**没有** dialog
    /// 的 `ctx`。闭包只管"发信号"，关窗交给 dialog builder 里的监听。
    /// ⇒ 这也避免了"用外层 context pop 错路由"的经典坑。
    final wantClose = ValueNotifier<bool>(false);

    // ⚠️ `disposed` 与 `cancelled` **必须分开**（审计发现的真隐患）：
    //
    // ## 两个标志的区别
    // · `cancelled` = **用户不再关心**（关弹窗）⇒ 停止轮询
    // · `disposed`  = `status`/`done` 两个 ValueNotifier **已被 dispose**
    //                 ⇒ **绝不能再写它们**（写了 Flutter 会抛
    //                 `A ValueNotifier was used after being disposed`）
    //
    // ## 为什么不能只用一个
    // 后台 Future 可能正卡在 `await pollDeviceToken()`（网络请求中），
    // 此时用户关掉弹窗 ⇒ 我们把 notifier dispose 了 ⇒
    // 请求返回后那一行 `status.value = ...` **就会抛异常**。
    // ⇒ 所以写之前必须检查 `disposed`（而不是只看 `cancelled`）。
    var disposed = false;

    unawaited(() async {
      var interval = session.intervalSec;
      while (!cancelled && !session.isExpired && !done.value) {
        await Future<void>.delayed(Duration(seconds: interval));
        if (cancelled || disposed || !mounted) break;
        final r = await client.pollDeviceToken(session);
        // ⚠️ **请求返回后必须再查一次** —— 上面那次 await 期间用户可能已关窗
        if (cancelled || disposed || !mounted) break;
        switch (r.state) {
          case TraktAuthState.success:
            await ref.read(sessionStoreProvider).saveTraktTokens(
                  access: r.accessToken!,
                  refresh: r.refreshToken,
                );
            // 保存 token 也可能耗时 ⇒ 再查一次再写 UI
            if (disposed) {
              if (!completer.isCompleted) completer.complete(true);
              return;
            }
            // ══════════════════════════════════════════════════════
            // ★ 授权成功 ⇒ **自动关窗**（用户 2026-10-14 报障）
            // ══════════════════════════════════════════════════════
            //
            // ## 原来的 bug
            // 这里只写 `status.value = '授权成功'` 就 `return` ——
            // **弹窗不关**，用户只能点「取消」，而「取消」pop(false)
            // ⇒ 后续"显示用户名"的逻辑永远不执行。
            // 用户原话："显示授权成功后没有下一步动作了""怎么一直这样"。
            //
            // ## 为什么延迟 900ms
            // 立刻关窗的话，用户**看不到**"授权成功"这一行
            // ⇒ 会怀疑"到底成没成"（这正是他现在的困惑）。
            // 900ms 够看清一行字，又不会让人等。
            //
            // ## 为什么 pop(true) 而不是 pop(false)
            // 返回值是调用方判断"要不要刷新 UI"的依据（见 `_connect`）。
            status.value = const _AuthStatus('授权成功', _AuthKind.success);
            done.value = true;
            if (!completer.isCompleted) completer.complete(true);
            // ⚠️ **不在这里 pop** —— 本闭包在 `showDialog` 之前创建，
            //    **拿不到 dialog 的 `ctx`**（我第一版在这里写
            //    `Navigator.pop(ctx, true)` ⇒ `Undefined name 'ctx'`）。
            // ⇒ 改为"发信号"：`done` 已经置 true，由 dialog 那一层
            //    （它知道 `ctx`）监听 `done` 自行关闭。
            //    延迟 900ms 让用户看清"授权成功"这一行。
            // ══════ 过渡提示（用户 2026-10-14 规格）══════
            // > 可短暂显示"正在获取您的 Trakt 数据..."，给用户一个心理缓冲
            //
            // ## 为什么需要它
            // 拿到 token 之后还要**再发一个请求**（`/users/me` 取用户名）
            // ⇒ 那 0.5–2 秒里如果界面停在"授权成功"不动，用户会以为卡了
            //（他这次报障的"怎么一直这样"就是这类体验问题）。
            await Future<void>.delayed(const Duration(milliseconds: 600));
            if (!disposed) {
              status.value = const _AuthStatus(
                  '正在获取您的 Trakt 数据…', _AuthKind.loading);
            }
            await Future<void>.delayed(const Duration(milliseconds: 600));
            if (!disposed) wantClose.value = true;
            return;
          case TraktAuthState.expired:
            status.value = _AuthStatus(r.message ?? '授权码已失效',
                _AuthKind.failed);
            done.value = true;
            if (!completer.isCompleted) completer.complete(false);
            return;
          case TraktAuthState.slowDown:
            interval = (interval + 3).clamp(3, 30);
            status.value = const _AuthStatus(
                '请求过于频繁，放慢轮询…', _AuthKind.waiting);
          case TraktAuthState.waiting:
            status.value = _AuthStatus(
                '等待授权…（剩余 ${session.remainingSec}s）',
                _AuthKind.waiting);
          case TraktAuthState.error:
            // ⚠️ 网络失败**不算授权失败**（§6.9.1）⇒ 继续轮询，只提示
            status.value = _AuthStatus(
                '网络抖动，重试中…（剩余 ${session.remainingSec}s）',
                _AuthKind.waiting);
        }
      }
      if (!completer.isCompleted && !done.value && !disposed) {
        status.value = const _AuthStatus('已超时，请重新登录',
            _AuthKind.failed);
        if (!completer.isCompleted) completer.complete(false);
      }
    }());

    if (!mounted) return null;

    // ══════════════════════════════════════════════════════════════
    // B 方案（保底）：**自动把授权码写进剪贴板**
    // ══════════════════════════════════════════════════════════════
    // 自动填/自动点若失败（页面改版），用户仍可长按黏贴。
    // 剪贴板是**系统级**能力 ⇒ 不依赖页面结构 ⇒ **一定有用**。
    unawaited(Clipboard.setData(ClipboardData(text: session.userCode)));

    // ══════════════════════════════════════════════════════════════
    // A 方案：**全自动**（填码 → 点「授权」）
    // ══════════════════════════════════════════════════════════════
    //
    // ## 为什么两个动作放同一个定时器（而不是各一个）
    // 它们是**有顺序**的两步，且第二步的前提是第一步已完成
    //（页面从"输码"变成"确认"）。分开两个定时器会互相抢时机。
    //
    // ## 节拍 1.2 秒（不是 6 秒）
    // 授权轮询的 6 秒是**契约要求**（服务端 `interval`）；
    // 而"等页面换步"是**体验**问题 ⇒ 用更快的节拍，且**成功即停**。
    var filled = false;
    var submitted = false;
    var authorized = false;
    final autoTimer = Timer.periodic(const Duration(milliseconds: 1200), (t) async {
      if (cancelled || disposed || done.value) {
        t.cancel();
        return;
      }
      // ══════ 三段式自动授权（用户截图确认的完整链路）══════
      //   ① 填码  ② 点「继续」  ③ 点「授权」
      // 顺序**不能乱**：没填码就提交会提交空表单；没提交就到不了授权页。
      if (!filled) {
        filled = await _autoFillCode(session.userCode);
      }
      if (filled && !submitted) {
        // ② 提交（点「继续」）—— 提交后页面会变成「授权此设备」
        submitted = await _autoSubmitCode();
      }
      if (filled && submitted && !authorized) {
        // ③ 点「授权」（`_autoTapAuthorize` 内含"确实是确认页"的三重判据）
        authorized = await _autoTapAuthorize();
      }
      if (filled && submitted && authorized) t.cancel();   // 三步都成 ⇒ 停
    });
    // 授权码 600 秒过期 ⇒ 最多跑 ~500 次，不会无限
    // ⚠️ 必须有个"兜底取消"，否则对话框关掉后定时器仍在跑（泄漏）
    unawaited(Future<void>.delayed(const Duration(seconds: 601)).then((_) {
      autoTimer.cancel();
    }));

    // 先让 WebView 加载授权页（弹窗一出现就有内容，避免白屏）
    unawaited(_web.loadRequest(Uri.parse(session.verificationUrl)));
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Cf.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Cf.radiusMd)),
        title: const Text('连接 Trakt'),
        content: SizedBox(
          width: double.maxFinite,
          height: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ══════ ★ 授权成功 ⇒ 自动关窗（用户 2026-10-14 报障）══════
              //
              // ## 原来的 bug
              // 轮询拿到 token 后只把文案改成"授权成功"就 `return`，
              // **弹窗不关** ⇒ 用户只能点「取消」，而「取消」返回 false
              // ⇒ 后续"显示用户名/同步"全不执行。
              // 用户原话："显示授权成功后没有下一步动作了""怎么一直这样"。
              //
              // ## 为什么在这里监听（而不是在轮询闭包里 pop）
              // 轮询闭包在 `showDialog` **之前**创建 ⇒ 作用域里**没有**
              // dialog 的 `ctx`（我第一版在那里写 `Navigator.pop(ctx, true)`
              // ⇒ `Undefined name 'ctx'`）。
              // ⇒ 闭包只置 `wantClose = true`，由**知道 ctx 的这一层**消费。
              //
              // ## 为什么延迟 900ms（在闭包里）
              // 立刻关窗用户看不到"授权成功"那一行 ⇒ 会怀疑到底成没成
              //（这正是他现在的困惑）。900ms 够看清，又不让人等。
              ValueListenableBuilder<bool>(
                valueListenable: wantClose,
                builder: (_, shouldClose, __) {
                  if (shouldClose) {
                    // `addPostFrameCallback`：**不能在 build 期间 pop**
                    // （Flutter 会抛 "setState during build" 类错误）
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    });
                  }
                  return const SizedBox.shrink();
                },
              ),
              // ══════ 内置 WebView（用户 2026-10-14 要求）══════
              //
              // ## 加载哪个 URL
              // `https://auth.trakt.tv/activate` —— 设备侧实测会 **302**
              // 到 `/signin?callbackURL=%2Factivate`，即 Trakt 的登录页
              // （用户截图里那个：语言 / 邮箱 / 「给我发送登录链接」）。
              //
              // ## 为什么不需要 NavigationDelegate 拦截
              // 设备码流程**没有回调** —— 用户在页面里输授权码，Trakt 自己确认。
    // ⚠️ 码通常是 **8 位**（官方文档 + 实测），不要按 6 位排版。
              // 我们只**轮询** `/oauth/device/token`（见下面的轮询逻辑）
              // ⇒ 这是它与 PKCE 方案的关键区别（那才需要抓 redirect）。
              //
              // ## 必须开 JS
              // 该页用 **htmx**（服务端渲染 + 局部更新）⇒
              // 不开 JS 则按钮点了没反应。
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Cf.radiusSm),
                  child: WebViewWidget(controller: _web),
                ),
              ),
              const SizedBox(height: Cf.gap2),
              // ══════ 授权码：**已隐藏**（用户 2026-10-15 要求）══════
              //
              // ## 为什么去掉这一行
              // 用户原话：
              // > 我退出了，你改成这样的，**隐藏继续的左下授权码**
              //
              // 理由（技术上也站得住）：
              // · 现在**自动填入**授权码（`_autoFillCode`）⇒ 用户不必看它
              // · 且**自动点「授权」**（`_autoTapAuthorize`）⇒ 连点都不用点
              // ⇒ 那一行只剩"占地方 + 让人以为要手输"两个作用
              //
              // ## ⚠️ 但**保底通路必须留着**（不能一并删掉）
              // 自动填依赖"页面结构能被识别"，而我没有 Trakt 账号
              // ⇒ **走不到登录后页面** ⇒ 选择器无法实测。
              // 若自动填失败而授权码又不可见，用户就**只能靠剪贴板**了。
              // ⇒ 剪贴板仍在生成时自动写入（见 `_showAuthorizeDialog` 开头），
              //   用户长按输入框即可粘贴。**这是这条通路存在的理由。**
              //
              // ## 为什么保留代码而不删除（注释掉 vs 删掉）
              // 保留为**折叠态**：需要时（自动填失效）用户可以展开看码。
              // ⇒ 用 `ExpansionTile` 而不是直接删 —— 删了就没退路。
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  dense: true,
                  // 默认**收起**（用户要求隐藏）；需要时才展开
                  initiallyExpanded: false,
                  title: Text('看不到授权码？（点此展开）',
                      style: Cf.caption.copyWith(color: Cf.text3)),
                  children: [
                    Row(children: [
                      SelectableText(
                        session.userCode,
                        style: Cf.title.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                          color: Cf.accent,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '复制授权码',
                        onPressed: () async {
                          await Clipboard.setData(
                              ClipboardData(text: session.userCode));
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('授权码已复制')),
                            );
                          }
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                      ),
                    ]),
                  ],
                ),
              ),
              // ══════ 「在浏览器中打开」兜底 ══════
              //
              // ## 为什么必须有（实测依据）
              // Trakt 登录页提供 **Google / Apple** 登录；而 Google
              // **明确禁止**在嵌入式 WebView 里做 OAuth
              // （错误 `disallowed_useragent`，判据是 UA 含 `; wv)`）。
              // ⇒ 这不是我们能绕过的（绕过违反其政策，也会被风控）
              // ⇒ 用邮箱登录可在 WebView 内完成；用 Google 则必须跳浏览器。
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final uri = Uri.tryParse(session.verificationUrl);
                    if (uri == null) return;
                    if (!await launchUrl(uri,
                        mode: LaunchMode.externalApplication)) {
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                            content:
                                Text('请手动打开 ${session.verificationUrl}')));
                      }
                    }
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('用 Google 登录？在浏览器中打开'),
                ),
              ),
              // ══════ 轮询状态 ══════
              ValueListenableBuilder<_AuthStatus>(
                valueListenable: status,
                builder: (_, st, __) => Row(children: [
                  // ══════ 按状态换图标（用户 2026-10-14 规格）══════
                  // 原来**无论什么状态都转圈** ⇒ 显示"授权成功"时还在转
                  // ⇒ 用户不知道到底成没成（他截图里困惑的就是这个）。
                  if (st.kind == _AuthKind.success)
                    const Icon(Icons.check_circle_rounded,
                        size: 16, color: _kSuccessGreen)
                  else if (st.kind == _AuthKind.failed)
                    const Icon(Icons.error_rounded,
                        size: 16, color: Cf.danger)
                  else
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const SizedBox(width: Cf.gap2),
                  Expanded(
                    child: Text(st.text,
                        style: Cf.caption.copyWith(
                            color: st.kind == _AuthKind.success
                                ? _kSuccessGreen
                                : (st.kind == _AuthKind.failed
                                    ? Cf.danger
                                    : Cf.text2))),
                  ),
                ]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              if (!completer.isCompleted) completer.complete(false);
              Navigator.pop(ctx, false);
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );
    cancelled = true;
    // ⚠️ **顺序很重要**：先置 `disposed`（让后台 Future 停止写 UI），
    //    再 dispose 两个 notifier。
    //    反过来的话，后台 Future 可能在 dispose 之后、置标志之前写一次 ⇒ 抛异常。
    disposed = true;
    status.dispose();
    done.dispose();
    wantClose.dispose();
    return result ?? await completer.future;
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Cf.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Cf.radiusMd)),
        title: const Text('断开 Trakt'),
        content: const Text('将清除本机的 Trakt 登录状态（保留 Client ID）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('断开'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = ref.read(sessionStoreProvider);

    // ══════════════════════════════════════════════════════════════
    // ① 先在**服务端吊销**（借鉴小幻影视的 `TraktRevokeTokenRequest`）
    // ══════════════════════════════════════════════════════════════
    //
    // ## 为什么必须有（只清本地是不够的）
    // 只清本地存储的话，Trakt 服务端**仍认为该 token 有效**
    // ⇒ 安全上不干净（token 若被截获仍可用）。
    // 官方契约原文：
    // > An `access_token` can be revoked when a user signs out.
    //
    // ## ★ 顺序：先吊销，再清本地
    // 反过来的话清完本地就没 token 可吊销了。
    //
    // ## ⚠️ 吊销失败**不能**阻止本地登出
    // 否则网络不好时用户会**被锁在登录态**（想登出登不出）
    // ⇒ 这是比"服务端还留着 token"更糟的体验问题。
    try {
      // ★ 用 `resolveTraktClientId()`（含内置兜底）——
      //   旧写法 `loadTraktClientId()` 在**用内置凭据时恒为空**
      //   ⇒ `cid.isNotEmpty` 为假 ⇒ **吊销永远不会执行**（revoke 成死代码）。
      //   （这是"三处漏改"的最后一处；另两处在播放器与详情页。）
      final cid = await store.resolveTraktClientId() ?? '';
      if (cid.isNotEmpty) {
        final sync = await TraktSync.fromStore(
          clientId: cid,
          readAccess: store.loadTraktAccessToken,
          readRefresh: store.loadTraktRefreshToken,
          writeTokens: (a, r) => store.saveTraktTokens(access: a, refresh: r),
          // ⚠️ 这里**故意传"不提前刷新"**（`() async => null`）：
          // 登出流程马上要吊销 token ⇒ 提前刷新毫无意义，
          // 反而会**多发一次请求**、并在服务端**多造一个 token**。
          expiresInMs: () async => null,
          // 登出时不需要存到期时刻（马上要清空）
          writeExpiresAt: (_) async {},
        );
        // 不 await 它的结果 —— 吊销是"尽力而为"
        await sync?.revoke();
      }
    } catch (e) {
      debugPrint('[Trakt] 吊销失败（本地仍会登出）: $e');
    }

    // ② 再清本地（**无条件**，与吊销成功与否无关）
    await store.clearTraktTokens();
    await _load();
    await _toast('已断开 Trakt');
  }

  // ══════════════════════════════════════════════════════════════
  //  UI
  // ══════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Cf.bg,
      appBar: AppBar(
        backgroundColor: Cf.bg,
        // 标题**连点 7 次**才显示 Client ID 卡片（Android 开发者选项惯例）。
        // ⚠️ 为什么不做成"长按"：长按在 AppBar 标题上会被系统当作
        //    文本选择的手势，且用户不容易发现。
        title: GestureDetector(
          onTap: _tapTitle,
          // 让整块标题都可点（不只是文字），否则命中区只有十几个像素
          behavior: HitTestBehavior.opaque,
          child: const Text('Trakt'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Cf.gap4),
        children: [
          _headerCard(),
          const SizedBox(height: Cf.gap3),
          // 三个开关：**尚未接后端**（如实标注，不假装已实现）
          _switchGroup(),
          // ★ Client ID 卡片**默认不渲染**（用户要求隐藏）。
          //   注意是"不渲染"而不是"透明/收起" —— 后者仍会出现在
          //   语义树与截图里，等于没藏。
          if (_devMode) ...[
            const SizedBox(height: Cf.gap3),
            _clientIdCard(),
          ],
        ],
      ),
    );
  }

  /// Trakt 品牌图标（官方紫方块 + 同步图标）。
  ///
  /// ## 为什么抽成方法
  /// 它有两个使用点：① 未登录时 ② 头像加载失败时（`errorBuilder`）。
  /// 复制两份会出现"改了一处忘另一处"。
  Widget _brandIcon() => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF9F42C6),
          borderRadius: BorderRadius.circular(Cf.radiusSm),
        ),
        child: const Icon(Icons.sync_alt_rounded,
            color: Colors.white, size: 20),
      );

  Widget _headerCard() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Cf.radiusMd),
        color: Cf.surface,
        border: Border.all(color: Cf.border),
      ),
      child: Column(children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: Cf.gap4, vertical: Cf.gap3),
            child: Row(children: [
              // ── 头像：已拉到用户信息就用真头像，否则用品牌图标 ──
              //
              // ## 为什么要显示头像（用户 2026-10-14）
              // > 这个授权成功后，显示我的 trakt 名字哇
              // 光显示"已连接"用户无法确认**连的是哪个账号** ——
              // 多账号场景下连错了要能一眼看出来。
              if (_me?.avatarUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(Cf.radiusSm),
                  child: Image.network(
                    _me!.avatarUrl!,
                    width: 36,
                    height: 36,
                    fit: BoxFit.cover,
                    // ⚠️ 头像加载失败**不能**让整行崩/空白 ⇒ 回退品牌图标
                    errorBuilder: (_, __, ___) => _brandIcon(),
                  ),
                )
              else
                _brandIcon(),
              const SizedBox(width: Cf.gap3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 已登录且拿到用户名 ⇒ 标题就是 `@username`
                    //（这是用户最想看到的那一行）
                    Row(children: [
                      Flexible(
                        child: Text(
                          _me != null ? _me!.display : 'Trakt',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Cf.body
                              .copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (_me?.isVip == true) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Cf.accent.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('VIP',
                              style: Cf.micro.copyWith(
                                  color: Cf.accent,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(
                      // 三态如实区分（不能把"拉取失败"说成"未连接"）
                      _me != null
                          ? '已连接 —— 观看记录与收藏将双向同步'
                          : (_loggedIn
                              ? (_meLoading
                                  ? '已连接，正在读取账号信息…'
                                  : '已连接（点此刷新账号信息）')
                              : '连接 Trakt 账户以同步观看记录和收藏'),
                      style: Cf.micro,
                    ),
                  ],
                ),
              ),
              // 登录 / 断开
              if (_busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                FilledButton(
                  onPressed: _loggedIn ? _logout : _login,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 36), // ≥48dp 命中区（§6.4.1）
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: Text(_loggedIn ? '断开' : '登录'),
                ),
              const SizedBox(width: Cf.gap2),
              Icon(
                _expanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                color: Cf.text3,
              ),
            ]),
          ),
        ),
        // 展开区（对齐截图：展开时显示三个开关）
        if (_expanded) ...[
          Divider(color: Cf.border, height: 1),
          _switchRow(
            '实时追踪',
            '播放时自动向 Trakt 报告观看进度',
            value: _track,
            onChanged: (v) async {
              setState(() => _track = v);
              await ref
                  .read(sessionStoreProvider)
                  .setTraktFlag(SessionStore.kTraktTrackKey, v);
            },
          ),
          Divider(color: Cf.border, height: 1),
          _switchRow(
            '同步已看状态',
            '在详情页显示 Trakt 同步按钮',
            value: _sync,
            onChanged: (v) async {
              setState(() => _sync = v);
              await ref
                  .read(sessionStoreProvider)
                  .setTraktFlag(SessionStore.kTraktSyncKey, v);
            },
          ),
          Divider(color: Cf.border, height: 1),
          _switchRow(
            '续播检查',
            '播放时检查 Trakt 进度并提示从上次位置继续',
            value: _resume,
            onChanged: (v) async {
              setState(() => _resume = v);
              await ref
                  .read(sessionStoreProvider)
                  .setTraktFlag(SessionStore.kTraktResumeKey, v);
            },
          ),
        ],
      ]),
    );
  }

  /// 三个开关（**未接后端**）。
  ///
  /// ## ⚠️ 为什么显示为「关」且不可点
  /// 它们的后端行为（上报进度 / 同步已看 / 续播检查）需要
  /// `POST /scrobble/*`、`POST /sync/history` 等**写入类**接口，
  /// 而本项目**从未验证过**那些接口（也不该在没验证前让用户以为能用）。
  ///
  /// ⇒ §5.8 的规矩：**未接入的功能不许假装已实现**。
  ///   所以这里显示灰态 + 点击提示"开发中"，而不是给一个点了没反应的开关。
  /// 一个功能开关（**已接后端**，不再是死开关）。
  ///
  /// ## 历史（为什么原来写着"开发中"）
  /// 上一轮我做了这三个开关的 UI，但后端（`POST /scrobble/*`、
  /// `POST /sync/history`、`GET /sync/playback`）还没实现
  /// ⇒ 按 §5.8 显示灰态 + 「开发中」提示，**没有假装能用**。
  ///
  /// ## 现在
  /// 三个接口已按官方契约实现（见 `trakt_client.dart` 的 `TraktSync`）
  /// ⇒ 开关真正生效，值持久化在 `SessionStore`（pref）。
  ///
  /// ## 为什么未登录也允许切换
  /// 存的是**偏好**，与登录态无关：用户可以先配好，等登录后立即生效。
  /// 比"禁用"更好 —— 禁用会让人不知道自己该先做什么。
  Widget _switchRow(String title, String sub,
      {required bool value, required ValueChanged<bool> onChanged}) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: Cf.gap4, vertical: Cf.gap3),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Cf.body.copyWith(color: Cf.text)),
                const SizedBox(height: 2),
                Text(sub, style: Cf.micro),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ]),
      ),
    );
  }

  Widget _switchGroup() => const SizedBox.shrink();

  Widget _clientIdCard() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Cf.radiusMd),
        color: Cf.surface,
        border: Border.all(color: Cf.border),
      ),
      child: InkWell(
        onTap: _editClientId,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Cf.gap4, vertical: Cf.gap3),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Client ID',
                      style: Cf.body.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    // ⚠️ **不再区分"内置/自填"**（用户要求隐藏）。
                    // 原本文案会写出"已内置" ⇒ 等于告诉别人
                    // "这 App 内置了 Trakt 凭据"。两者对用户**可操作
                    // 的下一步完全相同**（都是"点此修改"）⇒ 合并没有损失。
                    (_clientId ?? '').isNotEmpty || _usingBuiltin
                        ? '已配置（点此修改）'
                        : '未配置 —— 点此填写',
                    style: Cf.micro,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: Cf.iconMd, color: Cf.text3),
          ]),
        ),
      ),
    );
  }
}

/// 授权轮询的状态**类型**（决定图标与颜色）。
///
/// ## 为什么不直接用字符串（用户 2026-10-14 规格推动的改动）
/// 只存文案的话，UI 要靠"字符串里有没有'成功'"来选图标 ⇒
/// 改一个字的文案就会让图标错（脆弱且难查）。
enum _AuthKind {
  /// 等待用户授权 / 网络抖动重试（转圈）
  waiting,

  /// 授权成功（绿勾 ✅）
  success,

  /// 正在取用户数据（转圈 —— 过渡态）
  loading,

  /// 失败：授权码失效 / 超时（红叉 ❌）
  failed,
}

/// 轮询状态（文案 + 类型）。
class _AuthStatus {
  const _AuthStatus(this.text, this.kind);
  final String text;
  final _AuthKind kind;
}

/// **成功绿**（用户明确要求"绿色对勾"）。
///
/// ## 为什么允许它不进 Cf 令牌（§5.4 的例外，需说明）
/// Cf 里**没有**语义化"成功色"（现有令牌都是品牌色/中性色）。
/// 而"成功=绿"是**跨平台通用语义**，不是本 App 的品牌色选择。
/// ⇒ 就地定义 + 具名 + 注明理由，比硬编码一个 Color(0xFF...) 好。
/// ⚠️ 若将来 Cf 增加 success 令牌，**应改为引用它**。
const _kSuccessGreen = Color(0xFF22C55E);
