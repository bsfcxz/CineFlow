/// 115 网盘登录页（扫码）。
///
/// ## 为什么是扫码而不是账号密码
///
/// 115 的 webapi 路线靠 cookie 认证，而拿到 cookie 的**唯一正规途径**是扫码登录
/// （`login/qrcode`）。用账号密码登录需要走它未公开的密码登录端点——
/// 那既不在我们的协议取证范围内，也意味着要**让用户把密码交给第三方客户端**，
/// 与 AGENTS.md 的安全红线相悖。
///
/// 扫码的好处：**密码从不经过本应用**，用户在自己手机的 115 App 里完成授权。
///
/// ## ⚠️ 风险提示（必须显著展示）
///
/// 本功能走的是 115 的**非公开接口**（webapi），可能违反其服务条款，
/// 且高频请求有风控/封号风险。这属于必须让用户**知情同意**的事，
/// 所以页面上有明确的警告区块，而不是埋在文档里。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import 'pan115_client.dart';
import 'pan115_store.dart';

/// 扫码登录页。
class Pan115LoginPage extends ConsumerStatefulWidget {
  const Pan115LoginPage({super.key});

  @override
  ConsumerState<Pan115LoginPage> createState() => _Pan115LoginPageState();
}

class _Pan115LoginPageState extends ConsumerState<Pan115LoginPage> {
  Pan115QrSession? _session;
  Pan115QrStatus? _status;
  bool _starting = false;
  bool _finishing = false;
  String? _error;

  /// 轮询的"当前一轮"标记。
  ///
  /// 用它而不是 bool flag 来作废过期回调：用户可能反复点"刷新二维码"，
  /// 每刷新一次就多一个轮询循环；用自增世代号能让旧循环
  /// 发现"自己已过期"后自行退出（避免多个循环同时打服务端）。
  int _generation = 0;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // 置位后所有 in-flight 的轮询会在下一轮自行退出，
    // 避免"页面已销毁还在 setState"
    _disposed = true;
    _generation++;
    super.dispose();
  }

  Future<void> _start() async {
    if (_disposed) return;
    setState(() {
      _starting = true;
      _error = null;
      _status = null;
      _session = null;
    });
    final gen = ++_generation;
    final client = ref.read(pan115ClientProvider);

    final s = await client.startQr();
    if (_disposed || gen != _generation) return;
    if (s == null) {
      setState(() {
        _starting = false;
        _error = '无法连接 115（网络不通或接口被风控拦截）。请稍后重试。';
      });
      return;
    }
    setState(() {
      _starting = false;
      _session = s;
    });
    unawaited(_pollLoop(s, gen));
  }

  /// 轮询扫码状态。
  ///
  /// ⚠️ **必须等上一次返回后再发下一次**，不能用 Timer.periodic：
  /// 115 的状态接口是**长轮询**（实测单次最长约 30 秒才返回），
  /// 固定间隔调用会堆叠出大量并发长请求——既无意义又可能触发风控。
  /// 这里用"await 完再等一小会儿"的循环，天然保证串行。
  Future<void> _pollLoop(Pan115QrSession s, int gen) async {
    final client = ref.read(pan115ClientProvider);
    // 失败计数：单次失败可容忍（网络抖动），但**连续失败必须让用户看见**。
    //
    // 踩过的真实缺陷：原先失败只 `continue`，错误被完全吞掉——
    // 用户看到的是永远停在"等待二维码…"，而日志里一个字都没有。
    // 那种"没反应但也不报错"的状态是最难排查的，必须避免。
    var failures = 0;

    while (!_disposed && gen == _generation) {
      final r = await client.pollQrRaw(s);
      if (_disposed || gen != _generation) return;

      if (!r.ok) {
        failures++;
        // 单次失败仍静默重试（长轮询偶发超时属正常），
        // 但连续 2 次就把原因显示出来，并提示可刷新。
        if (failures >= 2) {
          setState(() => _error = '轮询扫码状态失败：${r.error ?? "未知原因"}');
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      failures = 0;
      if (mounted && _error != null) setState(() => _error = null);

      final st = r.status!;
      setState(() => _status = st);

      if (st.allowed) {
        // ★ 只有 status==2 才允许换凭据。
        // 未确认时调 login 会返回 40101017「老乡验证失败」，
        // 与"非法 uid"的响应一模一样，用户会看到误导性的失败提示。
        await _finish(s, gen);
        return;
      }
      if (st.terminal) return; // 过期/取消：等用户点刷新

      // 两次轮询之间留一点间隔，避免长轮询立刻重连
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  Future<void> _finish(Pan115QrSession s, int gen) async {
    if (_disposed || gen != _generation) return;
    setState(() => _finishing = true);

    // ⚠️ 整段 try/catch 是**必要的**，不是防御性冗余：
    // `_pollLoop` 是用 `unawaited(...)` 启动的，它内部抛出的异常
    // 会变成一个**无人接收的异步错误**——界面上看不到、日志里也没有，
    // 表现就是"扫码成功了但页面卡住不动"。这类静默失败折腾过很久，
    // 所以这里显式捕获并把原因显示出来。
    try {
      final client = ref.read(pan115ClientProvider);
      final cred = await client.finishQr(s);
      if (_disposed || gen != _generation) return;

      if (cred == null) {
        setState(() {
          _finishing = false;
          _error = '登录失败，请刷新二维码重试。';
        });
        return;
      }

      // 凭据只进安全存储（Go 侧不落盘）
      await ref.read(pan115StoreProvider).saveCredential(cred);
      debugPrint('[Pan115] 凭据已写入安全存储');
      await client.restoreSession(cred);
      ref.invalidate(pan115SessionProvider);
      debugPrint('[Pan115] 登录流程完成，返回浏览页');

      if (_disposed) return;
      if (mounted) Navigator.of(context).pop(true);
    } catch (e, st) {
      debugPrint('[Pan115] 登录收尾失败: $e\n$st');
      if (_disposed) return;
      setState(() {
        _finishing = false;
        _error = '登录收尾失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Cf.bg,
      appBar: AppBar(
        backgroundColor: Cf.bg,
        foregroundColor: Cf.text,
        title: Text('登录 115 网盘', style: TextStyle(fontSize: 16)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _riskWarning(),
          SizedBox(height: 18),
          Center(child: _qrArea()),
          SizedBox(height: 14),
          Center(child: _statusText()),
          SizedBox(height: 18),
          if (_error != null) _errorBox(_error!),
          SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: _starting ? null : _start,
              icon: Icon(Icons.refresh_rounded, size: 20),
              label: Text('刷新二维码'),
              style: TextButton.styleFrom(foregroundColor: Cf.accent),
            ),
          ),
          SizedBox(height: 6),
          Center(
            child: Text(
              '用手机上的「115」App 扫码并确认登录',
              style: TextStyle(fontSize: 12, color: Cf.text3),
            ),
          ),
        ],
      ),
    );
  }

  /// 风险提示区块。
  ///
  /// 走非公开接口这件事必须让用户**知情**——不该埋在文档或代码注释里。
  /// 用醒目但不吓人的样式（橙色调），并给出"如何停止"（在设置里退出登录）。
  Widget _riskWarning() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x1AFFB347),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x55FFB347)),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, size: 20, color: Color(0xFFFFB347)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '本功能通过 115 的非公开接口访问，可能违反其服务条款，'
                '且频繁访问有账号风控风险。已做限速（2 次/秒、串行请求）以降低风险，'
                '但仍请自行判断是否使用。\n'
                '扫码登录不会把你的密码交给本应用——授权在你手机的 115 App 内完成。',
                style: TextStyle(fontSize: 12, color: Cf.text2, height: 1.6),
              ),
            ),
          ],
        ),
      );

  Widget _qrArea() {
    const size = 220.0;
    final box = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: _session == null
          ? SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2, color: Cf.accent))
          // 直接显示服务端给的 PNG（实测该端点返回 image/png），
          // 所以无需引入二维码生成库
          : Image.network(
              _session!.imageUrl,
              width: size - 16,
              height: size - 16,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Padding(
                padding: EdgeInsets.all(12),
                child: Text('二维码加载失败，请点「刷新二维码」',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
              ),
              loadingBuilder: (_, child, p) => p == null
                  ? child
                  : Center(
                      child: SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Cf.accent))),
            ),
    );
    // 过期/取消时压一层遮罩，避免用户对着失效二维码扫半天
    final expired = _status != null && _status!.terminal && !_status!.allowed;
    if (!expired) return box;
    return Stack(alignment: Alignment.center, children: [
      Opacity(opacity: 0.25, child: box),
      Text('二维码已失效\n请点下方刷新',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Cf.text)),
    ]);
  }

  Widget _statusText() {
    if (_finishing) {
      return Text('正在登录…', style: TextStyle(fontSize: 13, color: Cf.accent));
    }
    if (_starting) {
      return Text('正在获取二维码…',
          style: TextStyle(fontSize: 13, color: Cf.text3));
    }
    final label = _status?.label;
    if (label == null || label.isEmpty) {
      return Text('等待二维码…', style: TextStyle(fontSize: 13, color: Cf.text3));
    }
    return Text(label, style: TextStyle(fontSize: 13, color: Cf.text2));
  }

  Widget _errorBox(String msg) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0x1AFF4D4F),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x55FF4D4F)),
        ),
        child: Text(msg,
            style: TextStyle(fontSize: 12, color: Cf.danger, height: 1.5)),
      );
}
