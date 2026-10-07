/// **播放内核设置页** —— 用户在此选择用哪个内核，并看到自动适配的理由。
///
/// ## 为什么要有这一页（而不是硬编码一个内核）
/// 项目有**两个内核**，能力互补（见 `kernel_auto_select.dart` 的表格）：
///   · mpv：格式覆盖最全，支持画面滤镜与音视频延迟
///   · Media3：Android 官方栈，HLS/转码流与系统媒体会话更好
///
/// 没有"哪个更好"，只有"哪个更合适当前片源"。
/// 故默认自动适配，同时**把选择权交给用户** ——
/// 遇到自动选错时（真实存在：本模块判断基于文件名与元数据，
/// **不是真探测解码能力**），用户能一键覆盖。
///
/// ## 这一页必须说清楚的两件事
/// 1. **当前偏好是什么**（自动 / mpv / Media3）
/// 2. **自动会怎么选**：把规则**列出来**，而不是让用户猜
///    —— 这是可解释性；用户看到"为什么这次用了 Media3"才不会困惑
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../player/kernel_auto_select.dart';
import '../state/providers.dart' show sessionStoreProvider;

/// 读取当前偏好。
final kernelPreferenceProvider =
    FutureProvider.autoDispose<KernelPreference>((ref) async {
  final store = ref.watch(sessionStoreProvider);
  return KernelPreference.fromStorage(await store.getPref(kKernelPrefKey));
});

class KernelSettingsPage extends ConsumerWidget {
  const KernelSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefAsync = ref.watch(kernelPreferenceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('播放内核')),
      body: prefAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('读取失败：$e')),
        data: (pref) => ListView(
          padding: const EdgeInsets.symmetric(vertical: Cf.gap2),
          children: [
            const _SectionLabel('选择内核'),
            for (final p in KernelPreference.values)
              _PreferenceTile(
                pref: p,
                selected: p == pref,
                onTap: () async {
                  await ref
                      .read(sessionStoreProvider)
                      .setPref(kKernelPrefKey, p.storageValue);
                  ref.invalidate(kernelPreferenceProvider);
                },
              ),
            const SizedBox(height: Cf.gap3),
            const _SectionLabel('自动适配规则'),
            const _ExplainCard(),
            const SizedBox(height: Cf.gap3),
            const _SectionLabel('已知局限'),
            const _LimitCard(),
            const SizedBox(height: Cf.gap5),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Cf.gap4, Cf.gap2, Cf.gap4, Cf.gap1),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Cf.success,
        ),
      ),
    );
  }
}

class _PreferenceTile extends StatelessWidget {
  const _PreferenceTile({
    required this.pref,
    required this.selected,
    required this.onTap,
  });

  final KernelPreference pref;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Cf.gap4, vertical: Cf.gap3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: Cf.iconMd,
              color: selected ? Cf.success : Cf.text3,
            ),
            const SizedBox(width: Cf.gap3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pref.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected ? Cf.success : Cf.text,
                    ),
                  ),
                  const SizedBox(height: Cf.gap1),
                  Text(pref.description, style: Cf.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 把自动规则**列出来**（可解释性）。
class _ExplainCard extends StatelessWidget {
  const _ExplainCard();

  @override
  Widget build(BuildContext context) {
    // 规则顺序即优先级（与 `KernelAutoSelect._selectAuto` 一致）
    const rules = <(String, String, String)>[
      ('HLS / 转码流', 'Media3', '分片续播与码率切换更成熟'),
      ('RMVB / WMV / ASF', 'mpv', '系统解码器通常没有，mpv 才放得了'),
      ('4K 及更高', 'Media3', '走系统硬解通路，能效更好'),
      ('有外挂字幕', 'mpv', '字幕编码（GBK/BIG5）与特效支持更好'),
      ('其余情况', 'mpv', '格式覆盖最全，保守选择'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Cf.gap4),
      child: Container(
        decoration: BoxDecoration(
          color: Cf.surface,
          borderRadius: BorderRadius.circular(Cf.radiusMd),
          border: Border.all(color: Cf.border),
        ),
        padding: const EdgeInsets.all(Cf.gap3),
        child: Column(
          children: [
            for (final (i, r) in rules.indexed) ...[
              if (i > 0) const Divider(height: Cf.gap4, color: Cf.border),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(r.$1,
                        style: const TextStyle(fontSize: 12, color: Cf.text)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      r.$2,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: r.$2 == 'mpv' ? Cf.warn : Cf.success,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 6,
                    child: Text(r.$3, style: Cf.caption),
                  ),
                ],
              ),
            ],
            const Divider(height: Cf.gap4, color: Cf.border),
            const Text(
              // 顺序即优先级 —— 这是实现事实，不说清用户会疑惑
              // "4K 的 RMVB 到底按哪条"。
              '规则按从上到下判断，先命中的先生效。\n'
              '「播放优先」：能播 > 体验，冷门格式永远优先走 mpv。',
              style: Cf.caption,
            ),
          ],
        ),
      ),
    );
  }
}

/// 诚实声明局限（别让用户以为"自动 = 一定播得了"）。
class _LimitCard extends StatelessWidget {
  const _LimitCard();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Cf.gap4),
      child: Container(
        decoration: BoxDecoration(
          color: Cf.surface2,
          borderRadius: BorderRadius.circular(Cf.radiusMd),
          border: Border.all(color: Cf.border),
        ),
        padding: const EdgeInsets.all(Cf.gap3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: Cf.iconSm, color: Cf.text3),
            const SizedBox(width: Cf.gap2),
            const Expanded(
              child: Text(
                '自动适配依据的是文件名与服务器元数据，'
                '不是真正探测设备解码能力。\n\n'
                '所以它给的是「合理的默认值」，不保证一定播得了。'
                '遇到播不了的片源，请手动切到另一个内核试试。',
                style: TextStyle(fontSize: 11, color: Cf.text3, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
