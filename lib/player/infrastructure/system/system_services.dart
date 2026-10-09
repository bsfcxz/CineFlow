/// 系统 UI 服务（规格 §13）—— 沉浸式全屏、屏幕方向、亮度、音量、唤醒锁。
///
/// ## 为什么全部包成"带降级"的服务
/// 这些能力都依赖原生插件或平台通道，**在测试环境/不支持的平台上会抛**。
/// 播放本身不该因为"设不了亮度"而中断 —— 所以每个方法都:
///   1. 捕获异常并记录（不向上抛）
///   2. 保留一份 Dart 侧的状态镜像（插件不可用时 UI 仍能显示合理值）
///
/// ## 与规格 §13 的差异（必须说明）
/// 规格写"进入全屏 = `immersiveSticky` + 强制横屏"。
/// 本实现**拆开这两件事**：
///   · 沉浸式（隐藏状态栏/导航栏）—— 全屏时总是要
///   · 强制横屏 —— **只在用户按了全屏按钮时才做**
/// 因为本项目已有"播放页横屏"的既有逻辑（`PlayerPage` 里两处
/// `setPreferredOrientations`），若这里无条件锁横屏，
/// 竖屏播放（短视频场景）会被强行转过去。
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 沉浸式状态。
class SystemUiService {
  SystemUiService();

  bool _immersive = false;
  bool get immersive => _immersive;

  /// 进入沉浸式全屏（隐藏状态栏与导航栏）。
  ///
  /// `immersiveSticky`：用户从边缘滑动可临时唤出系统栏，几秒后自动隐藏 ——
  /// 比 `immersive` 更友好（后者需要用户手动划出才能操作系统栏）。
  Future<void> enterImmersive() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _immersive = true;
    } catch (e) {
      debugPrint('[SystemUi] 进入沉浸式失败（忽略）: $e');
    }
  }

  /// 退出沉浸式（恢复系统栏）。
  ///
  /// 用 `edgeToEdge` 而不是 `manual`：本项目 targetSdk 36，
  /// Android 15 起强制 edge-to-edge，`manual` 已被废弃且行为不一致。
  Future<void> exitImmersive() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _immersive = false;
    } catch (e) {
      debugPrint('[SystemUi] 退出沉浸式失败（忽略）: $e');
    }
  }

  /// 锁定横屏。
  Future<void> lockLandscape() async {
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } catch (e) {
      debugPrint('[SystemUi] 锁定横屏失败（忽略）: $e');
    }
  }

  /// 锁定竖屏。
  Future<void> lockPortrait() async {
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } catch (e) {
      debugPrint('[SystemUi] 锁定竖屏失败（忽略）: $e');
    }
  }

  /// 恢复"跟随系统"（不锁定方向）。
  ///
  /// ⚠️ 退出播放器时**必须**调这个：否则用户离开播放页后
  /// 整个 App 仍被锁在横屏（本项目已有此约束，见 `PlayerPage.dispose`）。
  Future<void> unlockOrientation() async {
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } catch (e) {
      debugPrint('[SystemUi] 恢复方向失败（忽略）: $e');
    }
  }

  /// 进入全屏（沉浸式 + 横屏）。
  Future<void> enterFullscreen() async {
    await enterImmersive();
    await lockLandscape();
  }

  /// 退出全屏（恢复系统栏 + 竖屏）。
  Future<void> exitFullscreen() async {
    await exitImmersive();
    await lockPortrait();
  }

  /// 离开播放器时的清理（规格 §13.4）。
  Future<void> restore() async {
    await exitImmersive();
    await unlockOrientation();
  }
}

/// 亮度服务（`screen_brightness` 插件封装）。
///
/// ## 为什么用 0–100 而不是 0–1
/// 手势层与面板都用 0–100（规格 §9.3），统一单位避免"这一层 0–1、
/// 那一层 0–100"的换算错误 —— 单位不一致是本项目已踩过的坑。
class BrightnessService {
  BrightnessService();

  static const MethodChannel _ch =
      MethodChannel('com.cineflow.app/brightness');

  double _value = 50;

  /// 当前亮度 0–100（Dart 侧镜像；插件不可用时仍可读）。
  double get value => _value;

  /// 初始化：读取系统当前亮度作为起点。
  Future<void> init() async {
    try {
      final v = await _ch.invokeMethod<num>('get');
      if (v != null) _value = v.toDouble().clamp(0, 100);
    } catch (e) {
      debugPrint('[Brightness] 读取失败，沿用默认 50: $e');
    }
  }

  /// 设置亮度 0–100。
  Future<void> set(double v) async {
    final c = v.clamp(0.0, 100.0);
    _value = c; // 先更新镜像：即使原生失败，UI 也保持一致
    try {
      await _ch.invokeMethod('set', {'value': c});
    } catch (e) {
      debugPrint('[Brightness] 设置失败（忽略）: $e');
    }
  }
}

/// **系统媒体音量服务**（K3.5 起是音量的**唯一事实源**）。
///
/// ## ★ 架构：所有音量入口都落到系统音量
/// | 入口 | 落到哪 |
/// |---|---|
/// | 左半屏上下滑动手势 | 本服务 → `AudioManager.STREAM_MUSIC` |
/// | 设置面板音量滑块 | 本服务（同上）|
/// | **手机侧边音量键** | 系统直接改，本服务**监听**后同步 UI |
/// | 音频焦点 duck | **内核**（临时压低，见下）|
///
/// 内核音量**恒定 1.0** ⇒ 不再有"系统 × 内核"的**双重衰减**。
///
/// ## 为什么不再区分"系统音量 / 播放器音量"
/// 旧实现有两条独立音量线（本服务 + `AudioState.volume`），
/// 后果是用户困惑：
/// · 按侧边键，App 里的滑块**不动**（看起来像坏了）
/// · 两者相乘：系统 50% × 播放器 50% = 实际 25%，"音量不对劲"
///
/// 参考实现（mpv-android `MPVActivity.kt:2102`、Next Player
/// `VolumeState.kt:169`）**都**把手势落到系统音量。本项目 2026-10-09 对齐。
///
/// ## ⚠️ 唯一例外：音频焦点 `duck` 仍走内核
/// "闪避"（别的 App 播报时压低我们的声音）**必须**改内核音量：
/// 改系统音量会把**用户的手机音量**改小，且**不会自动恢复** ——
/// 用户退出 App 后发现手机声音莫名变小，是很糟的体验。
/// 见 `PlayerChannel` 的 `multiply volume` 与播放页的 duck/unduck 实现。
///
/// ## 回环防护（见 [startListening]）
/// 我们自己 `set()` 也会触发系统广播。靠**按值去重**滤掉，
/// 不用 `isSelfChange` 标志位（那在异常路径下会残留）。
class VolumeService {
  VolumeService();

  static const MethodChannel _ch = MethodChannel('com.cineflow.app/volume');
  static const EventChannel _events =
      EventChannel('com.cineflow.app/volume/events');

  double _value = 70;

  /// 当前系统音量 0–100。
  double get value => _value;

  StreamSubscription<dynamic>? _sub;

  /// 系统音量变化回调（**只在值真的变了**时触发）。
  ///
  /// UI 层订阅它来同步滑块；**不要**在这里再调 [set]（那会回环）。
  void Function(double value)? onSystemChanged;

  /// 读取当前系统音量（应用启动/进播放页时调一次）。
  Future<void> init() async {
    try {
      final v = await _ch.invokeMethod<num>('get');
      if (v != null) _value = v.toDouble().clamp(0, 100);
    } catch (e) {
      debugPrint('[Volume] 读取失败，沿用默认 70: $e');
    }
  }

  /// 开始监听系统音量变化（用户按侧边键时会触发）。
  ///
  /// ## ★ 回环防护：按值去重
  /// 收到广播 → 与 [_value] 比较 → **相同就丢弃**。
  ///
  /// 为什么这样够：我们自己 [set] 时**先把 `_value` 更新成本地值**，
  /// 随后系统回的广播值与之相同 ⇒ 天然被滤掉。
  ///
  /// 为什么不用 `isSelfChange` 标志位：那需要在"设置前后"成对维护，
  /// **异常路径（如 set 抛异常）会让标志位残留**，之后所有系统变化
  /// 都被误吞 —— 用户按侧边键彻底失效，且极难排查。
  /// 值比较是**无状态**的，不存在这个风险。
  void startListening() {
    if (_sub != null) return;
    _sub = _events.receiveBroadcastStream().listen(
      (e) {
        final v = (e as num?)?.toDouble();
        if (v == null) return;
        final c = v.clamp(0.0, 100.0);
        // ★ 去重：相同值直接丢弃（这就是防回环）
        if ((c - _value).abs() < 0.01) return;
        _value = c;
        // 记一条日志：让"监听是否工作"**可观测**。
        //
        // 本项目已多次踩"静默失效"（R8 剥离日志、静默 catch、通知不贴…），
        // 而"按侧边键滑块不动"在无日志时**完全无从排查**。
        //
        // 不会刷屏：① 只在值真变时打（去重之后）② 用户按键频率极低。
        // ⚠️ 放在**去重之后** —— 放前面会在回环时刷屏。
        debugPrint('[Volume] 系统音量变化 → 同步 UI: $c');
        onSystemChanged?.call(c);
      },
      onError: (Object e) => debugPrint('[Volume] 监听出错（忽略）: $e'),
    );
  }

  /// 停止监听（退出播放页时调，避免后台无谓唤醒）。
  Future<void> stopListening() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// 设置系统音量（手势/滑块都走这里）。
  ///
  /// ⚠️ 先更新 `_value` 再调原生：这样紧跟着回来的广播会被去重滤掉。
  Future<void> set(double v) async {
    final c = v.clamp(0.0, 100.0);
    _value = c;
    try {
      await _ch.invokeMethod('set', {'value': c});
    } catch (e) {
      debugPrint('[Volume] 设置失败（忽略）: $e');
    }
  }
}

/// 唤醒锁服务（播放中不熄屏）。
///
/// 规格要求 `wakelock_plus`。本实现用**原生通道**而不是引插件 ——
/// 理由：本项目已因 `media_kit` 的依赖树吃过体积/兼容的亏
/// （ADR 0009），而 `wakelock_plus` 只为一个 `FLAG_KEEP_SCREEN_ON`，
/// 用 20 行 Kotlin 就能覆盖，不值得多一个依赖。
///
/// ## ⚠️ 待办
/// Kotlin 侧的 `com.cineflow.app/wakelock` 通道**尚未实现**，
/// 故现在调它是空操作（会打日志）。补齐后无需改这里。
class WakelockService {
  WakelockService();

  static const MethodChannel _ch = MethodChannel('com.cineflow.app/wakelock');

  bool _enabled = false;
  bool get enabled => _enabled;

  Future<void> enable() async {
    _enabled = true;
    try {
      await _ch.invokeMethod('enable');
    } catch (e) {
      debugPrint('[Wakelock] 启用失败（忽略，可能未实现）: $e');
    }
  }

  Future<void> disable() async {
    _enabled = false;
    try {
      await _ch.invokeMethod('disable');
    } catch (e) {
      debugPrint('[Wakelock] 禁用失败（忽略）: $e');
    }
  }
}
