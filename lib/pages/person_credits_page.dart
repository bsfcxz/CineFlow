/// 演职员作品页 —— 点详情页的演员/导演头像进来，看他参与过的全部作品。
///
/// ## 为什么需要它（用户要求第一批第 1 项）
/// 详情页的演职员行原本是**死的**：有头像、有名字、能横滑，但**点了没反应**。
/// 用户看到喜欢的演员，最自然的下一步就是"他还演过什么"。
///
/// ## 数据来源（Emby 服务端，不在客户端拼）
/// `GET /Persons/{Id}/Credits`（端点依据见 `MediaProvider.getPersonCredits`）
/// —— 服务端知道该人的全部参演/执导条目；客户端自算需要拉全库，既慢又不准。
///
/// ## 与详情页的关系
/// 复用同一入口：点卡片 → `openPlayerResolved`（它会解析剧集分集 /
/// 电影合集），因此从本页进播放器的行为与首页一致。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/media_provider.dart';
import '../data/models.dart';
import '../state/providers.dart';
import 'open_player_resolved.dart';
import '../widgets/media_cards.dart';

class PersonCreditsPage extends ConsumerStatefulWidget {
  const PersonCreditsPage({
    super.key,
    required this.personId,
    required this.personName,
    this.role,
  });

  final String personId;
  final String personName;

  /// 在上一页担任的角色（如"饰 钢铁侠"），仅作标题副行。
  final String? role;

  @override
  ConsumerState<PersonCreditsPage> createState() => _PersonCreditsPageState();
}

class _PersonCreditsPageState extends ConsumerState<PersonCreditsPage> {
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
      final list = await api.getPersonCredits(widget.personId);
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // ⚠️ 失败**不伪装成空**（AGENTS §7.8）：给错误态 + 重试入口。
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.personName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            if (widget.role case final r? when r.isNotEmpty)
              Text(r,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Cf.text3)),
          ],
        ),
      ),
      body: _body(api),
    );
  }

  Widget _body(MediaProvider? api) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error case final e?) {
      return CfErrorView(message: e, onRetry: _load);
    }
    if (_items.isEmpty) {
      return const CfEmptyView(
        icon: Icons.person_off_outlined,
        message: '没有找到该演职员的作品',
      );
    }
    if (api == null) {
      return const CfEmptyView(message: '未连接服务器');
    }
    // 复用 `PosterGrid` —— 与首页/详情页同一套卡片，
    // "点进去"的视觉与交互天然一致（含角标/进度显示）。
    return PosterGrid(
      items: _items,
      api: api,
      onItemTap: (it) => openPlayerResolved(context, it, ref),
    );
  }
}
