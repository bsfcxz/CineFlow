/// 设置面板（规格 §7.6）—— 四个 Tab：视频 / 音频 / 字幕 / 信息。
///
/// ## 本文件只做"布局与绑定"，不含业务逻辑
/// 所有值都从 Controller 读、所有改动都转发给回调。
/// 这样面板本身是**纯展示**，可以独立用 widget 测试驱动
/// （传假数据即可，不必启动真引擎）。
///
/// ## Tab 切换用 `AnimatedSwitcher`（规格 §10.6：200ms）
library;

import 'package:flutter/material.dart';

import '../../domain/models/media_state.dart';
import '../../domain/models/panel_state.dart';
import '../../domain/player_constants.dart';
import '../../../keys.dart';
import '../player_ui_tokens.dart';
import '../widgets/panel_widgets.dart';
import 'player_panel_host.dart';

/// 设置面板的全部数据（一个值对象，避免 10 个构造参数）。
class SettingsPanelData {
  const SettingsPanelData({
    required this.video,
    required this.audio,
    required this.subtitle,
    required this.info,
    this.engineSupportsFilters = true,
    this.engineSupportsAudioDelay = true,
    this.engineSupportsSubtitleDelay = true,
    this.engineSupportsDecodeMode = true,
  });

  final VideoState video;
  final AudioState audio;
  final SubtitleState subtitle;
  final MediaInfo info;

  /// 当前引擎能力（**决定能否禁用做不到的入口**，见 `EngineFeature`）。
  final bool engineSupportsFilters;
  final bool engineSupportsAudioDelay;
  final bool engineSupportsSubtitleDelay;
  final bool engineSupportsDecodeMode;
}

/// 设置面板回调集合。
class SettingsPanelActions {
  const SettingsPanelActions({
    required this.onClose,
    required this.onTabChanged,
    required this.onAspectMode,
    required this.onDecodeMode,
    required this.onVideoFilter,
    required this.onResetFilters,
    required this.onAudioTrack,
    required this.onAudioDelay,
    required this.onVolume,
    required this.onSubtitleTrack,
    required this.onSubtitleDelay,
    required this.onSubtitleFontSize,
    required this.onSubtitleEncoding,
    required this.onImportSubtitle,
  });

  final VoidCallback onClose;
  final ValueChanged<SettingsTab> onTabChanged;
  final ValueChanged<AspectMode> onAspectMode;
  final ValueChanged<DecodeMode> onDecodeMode;

  /// `(brightness, contrast, saturation, hue)` —— 只传变化的那个，其余 null。
  final void Function({double? brightness, double? contrast,
      double? saturation, double? hue}) onVideoFilter;
  final VoidCallback onResetFilters;

  final ValueChanged<String> onAudioTrack;
  final ValueChanged<Duration> onAudioDelay;
  final ValueChanged<double> onVolume;

  final ValueChanged<String?> onSubtitleTrack;
  final ValueChanged<Duration> onSubtitleDelay;
  final ValueChanged<SubtitleFontSize> onSubtitleFontSize;
  final ValueChanged<SubtitleEncoding> onSubtitleEncoding;
  final VoidCallback onImportSubtitle;
}

class PlayerSettingsPanel extends StatelessWidget {
  const PlayerSettingsPanel({
    super.key,
    required this.tab,
    required this.data,
    required this.actions,
  });

  final SettingsTab tab;
  final SettingsPanelData data;
  final SettingsPanelActions actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: keys.player.settingsPanel,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(title: '设置', onClose: actions.onClose),
        PanelTabs<SettingsTab>(
          tabs: SettingsTab.values,
          value: tab,
          onChanged: actions.onTabChanged,
          labelOf: (t) => t.label,
        ),
        Expanded(
          // Tab 切换淡入淡出（规格 §10.6）
          child: AnimatedSwitcher(
            duration: PlayerPanelsDrawer.tabDuration,
            child: SingleChildScrollView(
              // key 让 AnimatedSwitcher 知道内容换了
              key: ValueKey(tab),
              padding: const EdgeInsets.only(bottom: 24),
              child: switch (tab) {
                SettingsTab.video => _videoTab(),
                SettingsTab.audio => _audioTab(),
                SettingsTab.subtitle => _subtitleTab(),
                SettingsTab.info => _infoTab(),
              },
            ),
          ),
        ),
      ],
    );
  }

  // ---------------- 视频 Tab ----------------

  Widget _videoTab() {
    final v = data.video;
    return Column(
      children: [
        SegmentedGroup<AspectMode>(
          label: '画面比例',
          options: AspectMode.values,
          value: v.aspectMode,
          onChanged: actions.onAspectMode,
          labelBuilder: (m) => m.label,
        ),
        SegmentedGroup<DecodeMode>(
          label: '解码方式',
          options: DecodeMode.values,
          value: v.decodeMode,
          onChanged: actions.onDecodeMode,
          labelBuilder: (m) => m.label,
        ),
        if (data.engineSupportsFilters) ...[
          SliderRow(
            label: '亮度',
            value: v.brightness,
            min: -100,
            max: 100,
            onChanged: (x) => actions.onVideoFilter(brightness: x),
          ),
          SliderRow(
            label: '对比度',
            value: v.contrast,
            min: -100,
            max: 100,
            onChanged: (x) => actions.onVideoFilter(contrast: x),
          ),
          SliderRow(
            label: '饱和度',
            value: v.saturation,
            min: -100,
            max: 100,
            onChanged: (x) => actions.onVideoFilter(saturation: x),
          ),
          SliderRow(
            label: '色相',
            value: v.hue,
            min: -180,
            max: 180,
            onChanged: (x) => actions.onVideoFilter(hue: x),
            showDivider: false,
          ),
          SettingRow(
            label: '重置画面参数',
            hint: v.isNeutral ? '当前已是默认值' : '亮度/对比度/饱和度/色相',
            value: v.isNeutral ? '—' : '重置',
            onTap: v.isNeutral ? null : actions.onResetFilters,
            showDivider: false,
          ),
        ] else
          // 引擎不支持时**明确告知**，而不是显示一堆点了没反应的滑块
          const PanelEmpty(
            icon: Icons.layers_clear_outlined,
            text: '当前播放内核不支持画面滤镜\n（硬件解码路径下不可用）',
          ),
      ],
    );
  }

  // ---------------- 音频 Tab ----------------

  Widget _audioTab() {
    final a = data.audio;
    return Column(
      children: [
        const _SectionTitle('音轨'),
        if (a.tracks.isEmpty)
          const PanelEmpty(icon: Icons.audiotrack, text: '没有可选音轨')
        else
          for (final t in a.tracks)
            _TrackRow(
              name: t.name,
              subtitle: t.subtitle,
              selected: t.id == a.activeTrackId,
              onTap: () => actions.onAudioTrack(t.id),
            ),
        if (data.engineSupportsAudioDelay) ...[
          const _SectionTitle('音频延迟'),
          DelayStepper(
            label: '延迟',
            delay: a.delay,
            onChanged: actions.onAudioDelay,
          ),
        ],
        const _SectionTitle('音量'),
        SliderRow(
          label: '音量',
          value: a.volume * 100,
          min: 0,
          max: 100,
          valueLabel: '${(a.volume * 100).round()}%',
          onChanged: (x) => actions.onVolume(x / 100),
          showDivider: false,
        ),
      ],
    );
  }

  // ---------------- 字幕 Tab ----------------

  Widget _subtitleTab() {
    final s = data.subtitle;
    return Column(
      children: [
        const _SectionTitle('字幕轨道'),
        _TrackRow(
          name: SubtitleTrack.off.name,
          subtitle: '',
          selected: s.activeTrackId == null,
          onTap: () => actions.onSubtitleTrack(null),
        ),
        for (final t in s.tracks)
          _TrackRow(
            name: t.name,
            subtitle: t.subtitle,
            selected: t.id == s.activeTrackId,
            onTap: () => actions.onSubtitleTrack(t.id),
          ),
        SettingRow(
          label: '导入本地字幕文件',
          hint: '支持 .srt / .ass / .vtt / .ssa',
          value: s.isExternalLoading ? '解析中…' : '选择文件',
          onTap: s.isExternalLoading ? null : actions.onImportSubtitle,
        ),
        if (data.engineSupportsSubtitleDelay) ...[
          DelayStepper(
            label: '字幕延迟',
            delay: s.delay,
            onChanged: actions.onSubtitleDelay,
          ),
        ],
        SegmentedGroup<SubtitleFontSize>(
          label: '字幕字号',
          options: SubtitleFontSize.values,
          value: s.fontSize,
          onChanged: actions.onSubtitleFontSize,
          labelBuilder: (x) => x.label,
        ),
        SegmentedGroup<SubtitleEncoding>(
          label: '字幕编码',
          options: SubtitleEncoding.values,
          value: s.encoding,
          onChanged: actions.onSubtitleEncoding,
          labelBuilder: (x) => x.label,
          showDivider: false,
        ),
      ],
    );
  }

  // ---------------- 信息 Tab ----------------

  Widget _infoTab() {
    final i = data.info;
    return Column(
      children: [
        InfoSection(title: '文件', children: [
          InfoRow(label: '文件名', value: i.fileName),
          InfoRow(label: '路径', value: i.filePath),
          InfoRow(
            label: '大小',
            value: i.sizeBytes == null ? null : _formatSize(i.sizeBytes!),
          ),
          InfoRow(
            label: '时长',
            value: i.duration == null ? null : _formatDuration(i.duration!),
            showDivider: false,
          ),
        ]),
        InfoSection(title: '视频', children: [
          InfoRow(label: '分辨率', value: i.resolutionLabel),
          InfoRow(
            label: '帧率',
            value: i.frameRate == null
                ? null
                : '${i.frameRate!.toStringAsFixed(3)} fps',
          ),
          InfoRow(label: '编码', value: i.videoCodec),
          InfoRow(
            label: '码率',
            value: i.videoBitrate == null
                ? null
                : '${(i.videoBitrate! / 1000000).toStringAsFixed(1)} Mbps',
          ),
          InfoRow(label: 'HDR', value: i.hdrFormat, showDivider: false),
        ]),
        InfoSection(title: '音频', children: [
          InfoRow(label: '编码', value: i.audioCodec),
          InfoRow(
            label: '声道',
            value: i.audioChannels == null ? null : '${i.audioChannels}',
          ),
          InfoRow(
            label: '采样率',
            value: i.audioSampleRate == null
                ? null
                : '${(i.audioSampleRate! / 1000).toStringAsFixed(1)} kHz',
            showDivider: false,
          ),
        ]),
        InfoSection(title: '封装', children: [
          InfoRow(label: '容器', value: i.container, showDivider: false),
        ]),
      ],
    );
  }

  /// 文件大小：B / KB / MB / GB（1024 进制）。
  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  /// `h:mm:ss` / `mm:ss`。
  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// Tab 内的分组标题。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: const TextStyle(
              color: PlayerUi.tabActiveText,
              fontSize: PlayerUi.hintSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
      );
}

/// 轨道行（音轨/字幕轨）—— 选中态左侧蓝条 + 蓝字。
class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.name,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          decoration: BoxDecoration(
            color: selected ? PlayerUi.tabActiveBg : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected ? PlayerUi.tabActiveText : Colors.transparent,
                width: 3,
              ),
              bottom: const BorderSide(color: PlayerUi.divider, width: 0.5),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(13, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? PlayerUi.tabActiveText
                            : PlayerUi.labelColor,
                        fontSize: PlayerUi.labelSize,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: PlayerUi.hintColor,
                          fontSize: PlayerUi.hintSize,
                        ),
                      ),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check,
                    size: 18, color: PlayerUi.tabActiveText),
            ],
          ),
        ),
      ),
    );
  }
}
