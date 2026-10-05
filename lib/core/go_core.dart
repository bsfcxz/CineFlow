/// Go 核心逻辑层的 Dart 侧绑定（dart:ffi）。
///
/// 契约与 `go/bridge.go` 的 C ABI 一一对应：
///   CineFlowPing() -> *char                    最小连通性探针
///   CineFlowCall(method, payload) -> *char     统一调用（JSON 信封）
///   CineFlowFree(*char)                        释放本库分配的字符串
///
/// ## 内存契约（最容易出错的地方）
/// `CineFlowCall` 返回的字符串由 **Go 侧** 用 `C.CString` 分配在 C 堆上，
/// **必须**由调用方 `CineFlowFree` 释放。漏掉就是每次调用泄漏一块内存。
/// 本文件用 try/finally 保证释放，调用方不需要关心。
///
/// ## 库加载失败不是异常情况
/// 桌面/未编译 Go 库时会加载失败。此时 `available` 为 false，
/// 业务侧应回退到纯 Dart 实现（见 `docs/decisions/0004`）。
/// 不让它抛异常，是为了"没有 Go 也能跑"这个降级路径成立。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// C ABI 签名
typedef _PingNative = Pointer<Utf8> Function();
typedef _PingDart = Pointer<Utf8> Function();

typedef _CallNative = Pointer<Utf8> Function(
    Pointer<Utf8> method, Pointer<Utf8> payload);
typedef _CallDart = Pointer<Utf8> Function(
    Pointer<Utf8> method, Pointer<Utf8> payload);

typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// 一次调用的结果信封（与 Go 侧 Response 对应）
class GoResult {
  final bool ok;
  final String? error;
  final Object? result;

  const GoResult({required this.ok, this.error, this.result});

  @override
  String toString() => ok ? 'GoResult(ok, $result)' : 'GoResult(err: $error)';
}

/// Go 核心层客户端。
///
/// 单例语义：动态库只需加载一次，且 `DynamicLibrary` 本身可复用。
class GoCore {
  GoCore._(this._ping, this._call, this._free);

  final _PingDart _ping;
  final _CallDart _call;
  final _FreeDart _free;

  static GoCore? _instance;
  static bool _triedLoad = false;

  /// 实际加载成功的库路径（供 isolate 内重新加载用）。
  ///
  /// 记录它而不是让子 isolate 按名字查找：桌面/测试下可能用 [tryLoad] 的
  /// `overridePath` 注入了非标准路径，子 isolate 若按平台默认名查找会失败。
  static String? _loadedPath;

  /// 桥接协议版本。与 `go/bridge.go` 的 `bridgeVersion` 必须一致；
  /// Dart 侧启动时校验，避免 .so 与 Dart 代码版本错配。
  static const bridgeVersion = '1';

  /// 库名：Android 下由 jniLibs 提供，桌面/测试下按平台命名规则查找。
  static String get _libName {
    if (Platform.isWindows) return 'cineflow_go.dll';
    if (Platform.isMacOS) return 'libcineflow_go.dylib';
    // Android / Linux
    return 'libcineflow_go.so';
  }

  /// Go 核心层是否可用。**不可用不是错误**——业务应回退纯 Dart 实现。
  static bool get available => _instance != null;

  /// 尝试加载动态库。可重复调用，只在首次真正加载。
  ///
  /// [overridePath] 供测试注入指定的 .so 路径。
  ///
  /// > 每个 isolate 需各自调用一次：Dart 的静态变量**按 isolate 隔离**，
  /// > 主 isolate 加载过不代表子 isolate 能用（见 [invokeAsync]）。
  static GoCore? tryLoad({String? overridePath}) {
    if (_triedLoad) return _instance;
    _triedLoad = true;
    try {
      final path = overridePath ?? _libName;
      final lib = DynamicLibrary.open(path);
      _instance = GoCore._(
        lib.lookupFunction<_PingNative, _PingDart>('CineFlowPing'),
        lib.lookupFunction<_CallNative, _CallDart>('CineFlowCall'),
        lib.lookupFunction<_FreeNative, _FreeDart>('CineFlowFree'),
      );
      _loadedPath = path;
    } catch (_) {
      // 库不存在/符号缺失：保持 available=false，由调用方降级
      _instance = null;
    }
    return _instance;
  }

  /// 最小连通性探针。
  ///
  /// 走**专用符号** `CineFlowPing`（无参数）而不是 `invoke('system.version')`，
  /// 目的是能在"统一入口本身有问题"时仍有一个最简通道做诊断。
  static GoResult ping() {
    final inst = _instance;
    if (inst == null) {
      return const GoResult(ok: false, error: 'Go 核心层未加载');
    }
    Pointer<Utf8> rPtr = nullptr;
    try {
      rPtr = inst._ping();
      if (rPtr == nullptr) {
        return const GoResult(ok: false, error: 'Go 返回空指针');
      }
      final decoded = jsonDecode(rPtr.toDartString());
      if (decoded is! Map) {
        return GoResult(ok: false, error: '返回信封格式异常: $decoded');
      }
      return GoResult(
        ok: decoded['ok'] == true,
        error: decoded['error'] as String?,
        result: decoded['result'],
      );
    } catch (e) {
      return GoResult(ok: false, error: 'ping 失败: $e');
    } finally {
      if (rPtr != nullptr) inst._free(rPtr);
    }
  }

  /// 统一调用：`method` 为点分方法名，`payload` 会被 JSON 编码。
  ///
  /// ⚠️ **同步调用，会阻塞当前 isolate**。
  /// 纯计算（media.*）用它没问题；**涉及网络的（pan115.*）必须用 [invokeAsync]**，
  /// 否则 UI 会卡住——115 的扫码状态轮询是长轮询，单次最长约 30 秒。
  GoResult invoke(String method, [Object? payload]) {
    final mPtr = method.toNativeUtf8();
    final pPtr = (payload == null ? '' : jsonEncode(payload)).toNativeUtf8();
    Pointer<Utf8> rPtr = nullptr;
    try {
      rPtr = _call(mPtr, pPtr);
      if (rPtr == nullptr) {
        return const GoResult(ok: false, error: 'Go 返回空指针');
      }
      final raw = rPtr.toDartString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return GoResult(ok: false, error: '返回信封格式异常: $raw');
      }
      final okFlag = decoded['ok'] == true;
      return GoResult(
        ok: okFlag,
        error: decoded['error'] as String?,
        result: decoded['result'],
      );
    } catch (e) {
      return GoResult(ok: false, error: '调用 $method 失败: $e');
    } finally {
      // 顺序无关，但三个都必须释放；漏了 rPtr 就是每次调用泄漏
      if (rPtr != nullptr) _free(rPtr);
      malloc.free(mPtr);
      malloc.free(pPtr);
    }
  }

  /// 在**独立 isolate** 里执行调用，避免阻塞 UI。
  ///
  /// ## 为什么必须如此（不是优化，是正确性要求）
  ///
  /// [invoke] 是同步 FFI，会占住调用它的 isolate。115 的方法都要发网络请求
  /// （扫码轮询更是**长轮询**，实测单次约 30 秒），若在 UI isolate 调同步版，
  /// 界面会整个冻住——用户看到"点了没反应"，且系统可能报 ANR。
  ///
  /// ## 为什么单独 isolate 可行（两个前提都成立）
  ///
  /// 1. **动态库是进程级的**：新 isolate 里 `DynamicLibrary.open` 拿到的是
  ///    同一个已加载的库（dlopen 有引用计数），不重复加载。
  /// 2. **Go 侧会话表在原生内存**，跨 isolate 共享——所以"登录后拿到凭据、
  ///    后续在别的 isolate 调用"是成立的。
  ///
  /// 唯一代价是每次调用多一次 isolate 启动（毫秒级），相对于网络往返可忽略。
  static Future<GoResult> invokeAsync(String method, [Object? payload]) {
    final inst = _instance;
    // 已经能同步判断时不必开 isolate（Go 不可用要立即降级）
    if (inst == null) {
      return Future.value(
        const GoResult(ok: false, error: 'Go 核心层未加载'),
      );
    }
    // ⚠️ 这里**必须传原始 payload 对象**，不能在主 isolate 先 jsonEncode。
    //
    // 踩过的真实缺陷（症状：二维码能显示但轮询永远"等待"）：
    // 原先写成「主 isolate 编码 → 传字符串 → 子 isolate 再 invoke(字符串)」，
    // 而 `invoke` 内部还会 `jsonEncode` 一次，于是 `{"uid":"x"}` 被编成
    // `"{\"uid\":\"x\"}"`（一个 JSON **字符串字面量**，不是对象），
    // Go 侧反序列化到 Request 结构体必然失败。
    //
    // 更隐蔽的是：`qr.start` 恰好**没有 payload**（走 `payload == null` 分支），
    // 所以只有它正常——二维码能拿到、轮询却全失败，看起来像"服务端问题"。
    // 真实网络集成测试（go/internal/rpc/pan115_live_test.go）能直接暴露这类问题。
    //
    // isolate 间传 Map/List/String/num/bool/null 都是安全的（可发送类型）。
    final libraryPath = _loadedPath;
    return Isolate.run(() {
      // 新 isolate 的静态变量是**独立**的，故必须在此重新加载。
      // 传 libraryPath 而不是让它按名字找：桌面/测试下注入过路径时，
      // 按平台默认名查找会失败（拿不到同一个库）。
      final sub = GoCore.tryLoad(overridePath: libraryPath);
      if (sub == null) {
        return const GoResult(ok: false, error: 'Go 核心层未加载（isolate 内）');
      }
      return sub.invoke(method, payload);
    });
  }

  // ---------- 媒体规则（Go 侧 internal/media 的 Dart 入口）----------
  //
  // 这些规则原本只在 Dart 实现（models.dart 的 isPlayable / progress 等）。
  // 引入 Go 核心层后，**规则的事实源在 Go**，Dart 侧逐步改为调用这里——
  // 目的是让未来 115 网盘、TMDB 刮削复用同一套判定，且两端行为一致。

  /// 清洗 `/Latest` 的裸数组：只保留可播放条目。
  /// 返回 null 表示 Go 层不可用（调用方应回退 Dart 实现）。
  List<Map<String, dynamic>>? normalizeLatest(List<Object?> items) {
    final r = invoke('media.normalizeLatest', {'items': items});
    if (!r.ok) return null;
    final res = r.result;
    if (res is! Map) return null;
    final list = res['items'];
    if (list is! List) return null;
    return [
      for (final e in list)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// 按类型复筛（服务端 `IncludeItemTypes` 不可信）。
  List<Map<String, dynamic>>? filterByType(
      List<Object?> items, List<String> types) {
    final r = invoke('media.filterByType', {'items': items, 'types': types});
    if (!r.ok) return null;
    final res = r.result;
    if (res is! Map) return null;
    final list = res['items'];
    if (list is! List) return null;
    return [
      for (final e in list)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// 排序参数规范化：返回 `(sortBy, sortOrder)`，可直接拼进 Emby 查询串。
  ///
  /// Go 侧会补默认方向（`DateCreated` → `Descending`）并追加次级键
  /// `SortName`，避免翻页顺序抖动。返回 null 表示 Go 不可用。
  (String, String)? sortParams(String field) {
    final r = invoke('media.sortParams', {'field': field});
    if (!r.ok) return null;
    final res = r.result;
    if (res is! Map) return null;
    final by = res['sortBy'];
    final order = res['sortOrder'];
    if (by is! String || order is! String) return null;
    return (by, order);
  }

  /// 单条进度/是否看完/剩余分钟（口径与详情页、播放器一致）。
  (double progress, bool completed, int remainingMinutes)? progressOf(
      Map<String, dynamic> item) {
    final r = invoke('media.progress', {
      'items': [item],
    });
    if (!r.ok) return null;
    final res = r.result;
    if (res is! Map) return null;
    final p = res['progress'];
    final c = res['completed'];
    final m = res['remainingMinute'];
    if (p is! num || c is! bool || m is! num) return null;
    return (p.toDouble(), c, m.toInt());
  }
}
