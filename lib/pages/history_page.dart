/// 播放历史页 —— Emby 已看条目（按最近播放排序，真实数据）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/emby_provider.dart';
import '../data/models.dart';
import '../state/providers.dart';
import '../widgets/media_cards.dart';
import 'detail_page.dart';

final _historyProvider =
    FutureProvider.autoDispose<List<MediaItem>>((ref) async {
  final api = ref.watch(embyApiProvider);
  if (api == null) throw const MediaException('未登录');
  final page = await api.getItems(
    includeTypes: 'Movie,Episode',
    recursive: true,
    sortBy: 'DatePlayed',
    filters: 'IsPlayed',
    limit: 60,
  );
  return page.items;
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
            const Text('播放历史',
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
                      child: Text('还没有观看记录',
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
