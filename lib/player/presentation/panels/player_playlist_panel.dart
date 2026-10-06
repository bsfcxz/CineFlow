/// 播放列表面板（规格 §7.8）—— 左侧抽屉。
///
/// 结构：标题 + 队列数量 + 列表（序号 / 文件名 / 副标题，当前项高亮）。
library;

import 'package:flutter/material.dart';

import '../../application/controllers/playlist_controller.dart';
import '../../../keys.dart';
import '../player_ui_tokens.dart';
import '../widgets/panel_widgets.dart';
import 'player_panel_host.dart';

class PlayerPlaylistPanel extends StatelessWidget {
  const PlayerPlaylistPanel({
    super.key,
    required this.state,
    required this.onSelect,
    required this.onClose,
    required this.onCycleMode,
  });

  final PlaylistState state;
  final ValueChanged<int> onSelect;
  final VoidCallback onClose;
  final VoidCallback onCycleMode;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: keys.player.playlistPanel,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelHeader(
          title: '播放列表',
          onClose: onClose,
          trailing: _ModeChip(mode: state.mode, onTap: onCycleMode),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            state.isEmpty ? '列表为空' : '当前队列 · ${state.entries.length} 项',
            style: const TextStyle(
              color: PlayerUi.hintColor,
              fontSize: PlayerUi.hintSize,
            ),
          ),
        ),
        Expanded(
          child: state.isEmpty
              ? const PanelEmpty(icon: Icons.playlist_play, text: '没有待播放的媒体')
              : ListView.builder(
                  // 规格 §14：列表必须用 ListView.builder（长列表不预建全部）
                  itemCount: state.entries.length,
                  itemBuilder: (context, i) => _PlaylistTile(
                    index: i,
                    entry: state.entries[i],
                    active: i == state.currentIndex,
                    onTap: () => onSelect(i),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 播放模式小胶囊（顺序/随机/单曲）。
class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode, required this.onTap});

  final PlayMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PlayerUi.tabRadius),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: PlayerUi.tabActiveBg,
            borderRadius: BorderRadius.circular(PlayerUi.tabRadius),
          ),
          child: Text(
            mode.label,
            style: const TextStyle(
              color: PlayerUi.tabActiveText,
              fontSize: PlayerUi.hintSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    required this.index,
    required this.entry,
    required this.active,
    required this.onTap,
  });

  final int index;
  final PlaylistEntry entry;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          decoration: BoxDecoration(
            color: active ? PlayerUi.tabActiveBg : Colors.transparent,
            border: Border(
              // 当前项左侧蓝条（规格 §7.8）
              left: BorderSide(
                color: active ? PlayerUi.tabActiveText : Colors.transparent,
                width: 3,
              ),
              bottom: const BorderSide(color: PlayerUi.divider, width: 0.5),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(13, 8, 16, 8),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: active
                    ? const Icon(Icons.equalizer,
                        size: 15, color: PlayerUi.tabActiveText)
                    : Text(
                        '${index + 1}',
                        style: const TextStyle(
                          color: PlayerUi.hintColor,
                          fontSize: PlayerUi.valueSize,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: active
                            ? PlayerUi.tabActiveText
                            : PlayerUi.labelColor,
                        fontSize: PlayerUi.valueSize,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    if (entry.subtitle case final s? when s.isNotEmpty)
                      Text(
                        s,
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
            ],
          ),
        ),
      ),
    );
  }
}
