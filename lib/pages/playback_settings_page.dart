/// 播放设置页 —— 默认倍速 / 跳片头 / 自动连播 / 直连偏好（偏好持久化 cf_pref_*）
/// 风格：深蓝夜色卡片 + 青色选中态；与播放器抽屉共享同一批偏好键。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../danmaku/danmaku_settings_page.dart';
import '../player/player_page.dart' show PlayerPage;
import '../state/providers.dart' show sessionStoreProvider;

/// 当前偏好的内存快照（进入页面拉取，改动即写盘）
class _Prefs {
  final double defaultRate;
  final bool skipIntroAuto;
  final bool autoNext;

  /// 长按倍速（播放时长按屏幕临时加速用）
  final double holdSpeed;

  const _Prefs({
    required this.defaultRate,
    required this.skipIntroAuto,
    required this.autoNext,
    required this.holdSpeed,
  });
}

final _prefsProvider =
    FutureProvider.autoDispose<_Prefs>((ref) async {
  final store = ref.watch(sessionStoreProvider);
  final rate = double.tryParse(
          await store.getPref('default_rate') ?? '') ??
      1.0;
  final skip = await store.getPref('skip_intro_auto');
  final next = await store.getPref('auto_next');
  // 复用 PlayerPage 的解析（越界/非法一律回退 2.0x），保证两处口径一致
  final hold = PlayerPage.parseHoldSpeed(await store.getPref('hold_speed'));
  return _Prefs(
    defaultRate: rate,
    skipIntroAuto: skip != '0',
    autoNext: next != '0',
    holdSpeed: hold,
  );
});

class PlaybackSettingsPage extends ConsumerStatefulWidget {
  const PlaybackSettingsPage({super.key});

  @override
  ConsumerState<PlaybackSettingsPage> createState() =>
      _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends ConsumerState<PlaybackSettingsPage> {
  Future<void> _save(String key, String value) async {
    await ref.read(sessionStoreProvider).setPref(key, value);
    ref.invalidate(_prefsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(_prefsProvider);
    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: prefs.when(
          loading: () => Center(
              child: CircularProgressIndicator(color: Cf.accent)),
          error: (_, _) => Center(
              child: Text('加载失败',
                  style: TextStyle(fontSize: 12, color: Cf.text3))),
          data: (p) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(children: [
                BackButton(color: Cf.text),
                Text('播放设置',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
              ]),
              SizedBox(height: 16),

              // —— 默认倍速 ——
              _card(
                title: '默认倍速',
                sub: '下次起播生效（1.0x 为原速）',
                child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
                        _opt('${r}x',
                            selected: p.defaultRate == r,
                            onTap: () => _save('default_rate', '$r')),
                    ]),
              ),
              SizedBox(height: 14),

              // —— 跳过片头 ——
              _card(
                title: '自动跳过片头',
                sub: '按章节信息识别片头区间，起播后自动跳过',
                child: _toggle(p.skipIntroAuto,
                    (v) => _save('skip_intro_auto', v ? '1' : '0')),
              ),
              SizedBox(height: 14),

              // —— 长按倍速 ——
              // ★ 从播放器控制条搬到这里（用户要求）：它属于"设置一次就不再改"
              //   的偏好，放在播放中的控制条上只是噪音，还挤占横屏宽度。
              _card(
                title: '长按倍速',
                sub: '播放时长按屏幕，临时用该倍速；松手恢复',
                child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in const [1.5, 2.0, 2.5, 3.0])
                        _opt('${s}x',
                            selected: p.holdSpeed == s,
                            onTap: () => _save('hold_speed', '$s')),
                    ]),
              ),
              SizedBox(height: 14),

              // —— 自动连播 ——
              _card(
                title: '自动连播下一集',
                sub: '剧集播完 5 秒倒计时后自动播放下一集',
                child: _toggle(p.autoNext,
                    (v) => _save('auto_next', v ? '1' : '0')),
              ),
              SizedBox(height: 14),

              // —— 播放策略说明 ——
              _card(
                title: '播放策略',
                sub: '优先硬解直连原文件；直连失败自动降级到 1080p 转码；'
                    '缓冲跟不上播放时会提示切换',
                trailing: Text('自动',
                    style: TextStyle(
                        fontSize: 11, color: Cf.accent)),
              ),

              SizedBox(height: 14),
              // —— 弹幕设置入口 ——
              InkWell(
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const DanmakuSettingsPage())),
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: Cf.surface,
                    border: Border.all(color: Cf.border),
                  ),
                  child: Row(children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: Cf.ai.withValues(alpha: .12),
                      ),
                      child: Icon(Icons.subtitles_rounded,
                          size: 16, color: Cf.ai),
                    ),
                    SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text('弹幕设置',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('弹幕源 · 外观 · 屏蔽词',
                            style:
                                TextStyle(fontSize: 10, color: Cf.text3)),
                      ]),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 20, color: Cf.text3),
                  ]),
                ),
              ),
              SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card({
    required String title,
    required String sub,
    Widget? child,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Cf.surface,
        border: Border.all(color: Cf.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800)),
              SizedBox(height: 3),
              Text(sub,
                  style: TextStyle(
                      fontSize: 11, color: Cf.text3, height: 1.5)),
            ]),
          ),
          ?trailing,
        ]),
        if (child != null) ...[
          SizedBox(height: 12),
          child,
        ],
      ]),
    );
  }

  Widget _opt(String label,
      {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: selected ? Cf.accent.withValues(alpha: 0.13) : Cf.surface2,
          border: Border.all(color: selected ? Cf.accent : Cf.border),
          boxShadow: selected
              ? [
                  BoxShadow(
                      color: Cf.accent.withValues(alpha: .18),
                      blurRadius: 10),
                ]
              : null,
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected ? Cf.accent : Cf.text2)),
      ),
    );
  }

  Widget _toggle(bool value, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 25,
        padding: const EdgeInsets.all(2.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: value ? Cf.accent : Cf.border,
        ),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value ? Cf.ink : Cf.text3,
          ),
        ),
      ),
    );
  }
}
