/// 通用「服务端列表」页 —— 公司作品 / 播放列表成员 / 追剧日历 共用。
///
/// ## 为什么抽一个通用页（而不是写三个几乎一样的页面）
/// 三者只有**三处不同**：数据来源、空态文案、卡片点击行为。
/// 其余（加载态/错误态/重试/网格布局）完全相同 ——
/// 复制三遍必然出现"改了一处忘了另两处"（本仓库已有这类教训，
/// 如两内核各写一份轨道解析）。
///
/// ## 错误处理纪律
/// 失败**不伪装成空**（AGENTS §7.8）：加载失败给 `CfErrorView` + 重试；
/// 真正没数据才给 `CfEmptyView`。两者的区别在用户看来是
/// "服务器出问题了"与"这里就是没有内容" —— 混淆会让人反复重试。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/media_provider.dart';
import '../data/models.dart';
import '../state/providers.dart';
import '../widgets/media_cards.dart';
import 'open_player_resolved.dart';

class ServerListPage extends ConsumerStatefulWidget {
  const ServerListPage({
    super.key,
    required this.title,
    required this.loader,
    required this.emptyText,
    this.emptyIcon = Icons.inbox_rounded,
    this.onItemTap,
    this.subtitleOf,
  });

  final String title;

  /// 数据来源（注入 —— 三个页面共用本页的关键）。
  final Future<List<MediaItem>> Function(MediaProvider api) loader;

  final String emptyText;
  final IconData emptyIcon;

  /// 点卡片做什么。null ⇒ 用默认的 `openPlayerResolved`。
  final void Function(BuildContext context, WidgetRef ref, MediaItem item)?
      onItemTap;

  /// 卡片副标题（如追剧日历要显示"3 天后"）。null ⇒ 用默认。
  final String? Function(MediaItem item)? subtitleOf;

  @override
  ConsumerState<ServerListPage> createState() => _ServerListPageState();
}

class _ServerListPageState extends ConsumerState<ServerListPage> {
  var _loading = true;
  String? _error;
  List<MediaItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(embyApiProvider);
    if (api == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '未连接服务器';
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.loader(api);
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(embyApiProvider);
    return Scaffold(
      backgroundColor: Cf.bg,
      appBar: AppBar(
        backgroundColor: Cf.bg,
        foregroundColor: Cf.text,
        title: Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
      body: _body(api),
    );
  }

  Widget _body(MediaProvider? api) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final e?) return CfErrorView(message: e, onRetry: _load);
    if (_items.isEmpty) {
      return CfEmptyView(icon: widget.emptyIcon, message: widget.emptyText);
    }
    if (api == null) return const CfEmptyView(message: '未连接服务器');

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final it = _items[i];
        final sub = widget.subtitleOf?.call(it);
        return ListTile(
          // 缩略图：海报裁成 16:9 横条（列表行比网格更适合横图）
          //
          // ⚠️ `thumbUrl` 返回 `String?`（条目可能**完全没有图片**）——
          //    直接喂给 `Image.network` 会抛。null 时给占位块。
          leading: SizedBox(
            width: 76,
            height: 44,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Cf.radiusSm),
              child: switch (it.thumbUrl(api, maxWidth: 240)) {
                final String u => Image.network(
                    u,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _thumbPlaceholder(),
                  ),
                null => _thumbPlaceholder(),
              },
            ),
          ),
          title: Text(it.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // ⚠️ 用 **13**（已有档位）而不是 13.5 ——
              //    `design_tokens_test` 守着"裸 fontSize 种类不超过 11"，
              //    新增一个 0.5px 档会变红，且 13 与 13.5 肉眼无差。
              style: TextStyle(fontSize: 13, color: Cf.text)),
          subtitle: sub == null
              ? null
              : Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Cf.text3)),
          onTap: () {
            final cb = widget.onItemTap;
            if (cb != null) {
              cb(context, ref, it);
            } else {
              // 默认：走统一入口（会解析剧集分集 / 电影合集）
              openPlayerResolved(context, it, ref);
            }
          },
        );
      },
    );
  }

  /// 无图/加载失败时的占位块（避免白洞）。
  static Widget _thumbPlaceholder() => ColoredBox(
        color: Cf.surface2,
        child: Icon(Icons.movie_outlined, size: 18, color: Cf.text3),
      );
}
