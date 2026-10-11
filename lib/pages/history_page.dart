/// 继续观看页 —— Emby 的**续播列表**（/Users/{uid}/Items/Resume）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/emby_provider.dart';
import '../data/models.dart';
import '../state/providers.dart';
import '../widgets/media_cards.dart';
import 'detail_page.dart';

/// **继续观看**（用户要求：播放历史 = 服务端的"继续观看"）。
///
/// ## ★★ 为什么从 `Filters=IsPlayed` 改成 `Resume`
/// 用户报障："播放历史对应的内容应该是 emby 服务端的继续观看内容，
/// 你识别有问题"。
///
/// 旧实现用的是 `Filters=IsPlayed` —— 那是「**已看完**」，
/// 与"继续观看"是**两个不同概念**：
/// · `IsPlayed` ⇒ 用户**看完了**的（点进去从头播没意义）
/// · `Resume`   ⇒ 用户**看了一半**的（点进去接着播）
/// 用户要的是后者。
///
/// ## 实测依据（两台真实服务器）
/// ```
/// /Users/{uid}/Items/Resume   → HTTP 200，12 条（带 PlayedPercentage）
///    · 《奥德赛》序章    18.1%
///    · 复仇者联盟       40.3%
///    · 沙浦村集结      100.0%
/// /Items/Resume?userId=       → HTTP 404   ← ⚠️ 必须走 /Users/{uid}/ 前缀
/// ```
///
/// ## 为什么带 `MediaTypes=Video`
/// Resume 默认会带**音频/图片**等 ⇒ 用户会在"播放历史"里看到歌单封面
///（实测该服务器 `Limit=12` 时全是视频，但换服务器不保证）。
final _historyProvider =
    FutureProvider.autoDispose<List<MediaItem>>((ref) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const MediaException('未登录');
  // `getResume` 内部走 `/Users/{uid}/Items/Resume`（实测唯一可用路径）
  return api.getResume(limit: 60);
});

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_historyProvider);
    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            BackButton(color: Cf.text),
            const Text('继续观看',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
          Expanded(
            child: history.when(
              loading: () => Center(
                  child: CircularProgressIndicator(color: Cf.accent)),
              error: (e, _) => CfErrorView(
                message: e is MediaException ? e.message : '加载失败',
                onRetry: () => ref.invalidate(_historyProvider),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return Center(
                      child: Text('没有正在观看的内容',
                          style:
                              TextStyle(fontSize: 12, color: Cf.text3)));
                }
                final api = ref.watch(embyApiProvider)!;
                return RefreshIndicator(
                  color: Cf.accent,
                  backgroundColor: Cf.surface,
                  onRefresh: () => ref.refresh(_historyProvider.future),
                  child: GridView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 2 / 3.45,
                    ),
                    itemBuilder: (context, i) => PosterCard(
                        item: items[i],
                        api: api,
                        onTap: () => openMediaItem(context, items[i])),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
