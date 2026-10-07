/// 播放列表面板（规格 §7.8）—— 左侧抽屉。
///
/// 结构：标题 + 队列数量 + 列表（序号 / 文件名 / 副标题，当前项高亮）。
library;

import 'package:flutter/material.dart';

import '../../application/controllers/playlist_controller.dart';
import '../../../core/theme.dart';
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
                    // ---- 第一行：集数徽章 + 标题 ----
                    //
                    // 用户反馈："播放剧集和综艺时播放列表并没有显示当前
                    // 集数"。修法对齐旧页选集的展示口径（第 N 集 + 剧名）。
                    //
                    // 集数用**独立徽章**而非拼进标题：扫列表时用户最先要看
                    // 的是"播到第几集"，单独着色加粗比埋在长标题里易读。
                    Row(
                      children: [
                        if (entry.episodeLabel case final e?
                            when e.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: active
                                  ? PlayerUi.tabActiveBg
                                  : PlayerUi.divider,
                              borderRadius: BorderRadius.circular(Cf.radiusXs),
                            ),
                            child: Text(
                              e,
                              style: TextStyle(
                                color: active
                                    ? PlayerUi.tabActiveText
                                    : PlayerUi.valueColor,
                                fontSize: PlayerUi.hintSize,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
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
                        ),
                      ],
                    ),
                    // ---- 第二行：进度优先，回退副标题 ----
                    //
                    // 进度优先的理由：用户更关心"这集看过没、看到哪"，
                    // 而副标题（剧名/容量）扫列表时信息量更低。
                    if (_secondLine(entry) case final sl?) Text(
                      sl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: entry.progressLabel != null && active
                            ? PlayerUi.tabActiveText
                            : PlayerUi.hintColor,
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

  /// 第二行显示什么：进度优先，其次副标题，都没有则不显示。
  static String? _secondLine(PlaylistEntry entry) {
    if (entry.progressLabel case final p? when p.isNotEmpty) return p;
    if (entry.subtitle case final s? when s.isNotEmpty) return s;
    return null;
  }
}