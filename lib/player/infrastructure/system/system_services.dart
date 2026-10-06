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

/// 音量服务。
///
/// ## ⚠️ 与播放器音量是两件事
/// · **系统音量**（本服务）：影响整个设备
/// · **播放器音量**（`AudioState.volume`）：只影响这个播放器
///
/// 规格 §9.3 的右半屏手势调的是**系统音量**（与 MX Player 一致），
/// 而设置面板里的"音量"滑块调的是**播放器音量**。
/// 两者混用会让用户困惑"为什么面板调到 0 还有声音"。
class VolumeService {
  VolumeService();

  static const MethodChannel _ch = MethodChannel('com.cineflow.app/volume');

  double _value = 70;

  /// 当前系统音量 0–100。
  double get value => _value;

  Future<void> init() async {
    try {
      final v = await _ch.invokeMethod<num>('get');
      if (v != null) _value = v.toDouble().clamp(0, 100);
    } catch (e) {
      debugPrint('[Volume] 读取失败，沿用默认 70: $e');
    }
  }

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
