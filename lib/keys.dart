/// 测试键：应用与 Patrol 真机 UI 测试之间的**唯一共享契约**。
///
/// ## 为什么要有这个文件
///
/// Patrol 测试只能通过 widget 查找到控件。若测试里直接写
/// `$('登  录')` 这种"按文案找"，那么任何一次文案微调（甚至全角空格
/// 的改动）都会让测试变红——而测试本该在**行为**变化时才变红。
/// 键把"这个控件是登录按钮"这件事从文案里解耦出来。
///
/// ## 纪律（Patrol 官方约定）
///
/// - 只给**测试真正会碰**的控件加键，不给整个界面铺键；
/// - 键值全局唯一，且按字母序排列（便于人工比对重复）；
/// - 私有子类 `ValueKey<String>` 给每个键加前缀，避免不同页面撞名
///   （例如登录页和设置页都有"返回"）；
/// - 键值一旦发布就不要改：它是测试的契约。
///
/// ## 用法
///
/// 应用侧：
/// ```dart
/// TextField(key: keys.login.usernameField, ...)
/// ```
///
/// 测试侧：
/// ```dart
/// await $(keys.login.usernameField).enterText('alice');
/// ```
library;

import 'package:flutter/widgets.dart';

/// 登录 / 服务器管理页的键。
class _LoginKey extends ValueKey<String> {
  const _LoginKey(String value) : super('login_$value');
}

class LoginKeys {
  const LoginKeys();

  /// 服务器地址输入框
  final serverField = const _LoginKey('serverField');

  /// 用户名输入框
  final usernameField = const _LoginKey('usernameField');

  /// 密码输入框
  final passwordField = const _LoginKey('passwordField');

  /// 密码可见性切换（眼睛图标）
  final passwordToggle = const _LoginKey('passwordToggle');

  /// 「记住密码」勾选框（整行可点）
  final rememberRow = const _LoginKey('rememberRow');

  /// 主登录按钮
  final submitButton = const _LoginKey('submitButton');

  /// 「快速连接码 →」
  final quickConnectLink = const _LoginKey('quickConnectLink');

  /// 登录页根节点（断言"当前在登录页"用）
  final page = const _LoginKey('page');
}

/// 主框架（底部 Tab）的键。
class _ShellKey extends ValueKey<String> {
  const _ShellKey(String value) : super('shell_$value');
}

class ShellKeys {
  const ShellKeys();

  /// 底部 Tab；用下标参数化（Tab 由列表生成，不是固定个数的具名控件）。
  /// 返回 [ValueKey] 而非私有子类：公开 API 不得暴露私有类型。
  ValueKey<String> tab(int index) => _ShellKey('tab_$index');

  /// 首页顶层节点（断言切到首页用）
  final homeTab = const _ShellKey('homeTab');

  /// 排行榜顶层节点
  final rankTab = const _ShellKey('rankTab');

  /// 「我的」顶层节点
  final profileTab = const _ShellKey('profileTab');
}

/// 通用/跨页面控件的键。
class _WidgetKey extends ValueKey<String> {
  const _WidgetKey(String value) : super('widget_$value');
}

class WidgetKeys {
  const WidgetKeys();

  /// 加载失败视图的重试按钮（CfErrorView）
  final errorRetryButton = const _WidgetKey('errorRetryButton');

  /// 加载中指示器
  final loadingIndicator = const _WidgetKey('loadingIndicator');
}

/// 播放页的键。
///
/// ## 为什么需要这些（这是全项目最大的验证缺口）
///
/// 集成测试（`integration_test/player_kernel_test.dart`）只驱动**内核**：
/// 它建纹理、起播、seek、改倍速，但**从不碰 UI 层** ——
/// 也就是说"控制层长什么样、按钮点了有没有反应、弹幕有没有盖在按钮上"
/// 从来没有被任何自动化验证过，只能靠人肉点。
///
/// 这一组键让 Patrol 能真正走一遍播放页：
/// 点中央显隐控制层 → 找到各功能钮 → 打开弹层 → 断言弹层出现。
class _PlayerKey extends ValueKey<String> {
  const _PlayerKey(String value) : super('player_$value');
}

class PlayerKeys {
  const PlayerKeys();

  /// 音轨按钮（控制条）
  final audioButton = const _PlayerKey('audioButton');

  /// 底部控制层根节点（断言"控制层已显示"用）
  final controls = const _PlayerKey('controls');

  /// 弹幕开关按钮
  final danmakuButton = const _PlayerKey('danmakuButton');

  /// 弹幕浮层（断言"弹幕叠加在视频上"用）
  final danmakuOverlay = const _PlayerKey('danmakuOverlay');

  /// 画幅比例按钮（左侧中部）
  final fitButton = const _PlayerKey('fitButton');

  /// 锁定按钮（右侧中部）
  final lockButton = const _PlayerKey('lockButton');

  /// 播放下一个 / 快进 10s（中央右侧）
  final seekForwardButton = const _PlayerKey('seekForwardButton');

  /// 快退 10s（中央左侧）
  final seekBackButton = const _PlayerKey('seekBackButton');

  /// 选集按钮（固定在控制条左侧）
  final episodeButton = const _PlayerKey('episodeButton');

  /// 倍速按钮
  final rateButton = const _PlayerKey('rateButton');

  /// 字幕按钮
  final subtitleButton = const _PlayerKey('subtitleButton');

  /// 播放/暂停（中央）
  final togglePlayButton = const _PlayerKey('togglePlayButton');

  /// 视频层手势区（点一下显隐控制层）
  final videoGestureArea = const _PlayerKey('videoGestureArea');

  /// 页面根节点（断言"已进入播放页"用）
  final page = const _PlayerKey('page');
}

/// 全局键聚合入口——测试与应用的唯一引用点。
final keys = Keys();

class Keys {
  final login = const LoginKeys();
  final player = const PlayerKeys();
  final shell = const ShellKeys();
  final widgets = const WidgetKeys();
}
