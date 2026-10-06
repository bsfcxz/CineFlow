/// 面板与 Tab 状态模型。
library;

/// 面板类型。`none` = 全部关闭。
enum PanelType {
  none,
  playlist,
  settings,
  danmaku;

  /// 是否从**左侧**滑入（播放列表在左，另两个在右）。
  bool get isLeft => this == PanelType.playlist;

  bool get isRight => this == PanelType.settings || this == PanelType.danmaku;

  String get title => switch (this) {
        PanelType.playlist => '播放列表',
        PanelType.settings => '设置',
        PanelType.danmaku => '弹幕设置',
        PanelType.none => '',
      };
}

/// 设置面板的四个 Tab（规格 §7.6）。
enum SettingsTab {
  video('视频'),
  audio('音频'),
  subtitle('字幕'),
  info('信息');

  const SettingsTab(this.label);
  final String label;
}

/// 面板状态（不可变）。
class PanelState {
  const PanelState({
    this.open = PanelType.none,
    this.settingsTab = SettingsTab.video,
  });

  final PanelType open;
  final SettingsTab settingsTab;

  PanelState copyWith({PanelType? open, SettingsTab? settingsTab}) =>
      PanelState(
        open: open ?? this.open,
        settingsTab: settingsTab ?? this.settingsTab,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PanelState &&
          other.open == open &&
          other.settingsTab == settingsTab;

  @override
  int get hashCode => Object.hash(open, settingsTab);

  @override
  String toString() => 'PanelState(open: $open, tab: $settingsTab)';
}
