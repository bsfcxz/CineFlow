/// 预告片按钮（用户要求第一批第 2 项）。
///
/// ## 行为
/// · 拉一次服务端的**本地预告**（`GET /Users/{uid}/Items/{Id}/LocalTrailers`）
/// · **有预告才显示**；没有则整个按钮不出现
/// · 点一下 → 取第一个预告直接进播放器
///
/// ## 为什么"没有预告就不显示"（而不是灰掉）
/// 本仓库反复修过"死按钮"形态（`showComingSoon` 用得太随意、
/// 点了没反应）。预告片对**电影**通常有、对**剧集**通常没有 ——
/// 若常显，多数剧集详情页会挂一个永远点不动的图标。
/// 宁可不显示，也不要给一个点了没反应的按钮。
///
/// ## 为什么单独一个文件
/// `detail_page.dart` 已 1200+ 行；新增功能不该继续堆进去。
/// 本组件是**自包含**的（自己拉数据、自己导航），放外面更清楚。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../state/providers.dart';
import '../player/player_routes.dart';

class TrailerButton extends ConsumerStatefulWidget {
  const TrailerButton({super.key, required this.itemId});

  final String itemId;

  @override
  ConsumerState<TrailerButton> createState() => _TrailerButtonState();
}

class _TrailerButtonState extends ConsumerState<TrailerButton> {
  List<MediaItem> _trailers = const [];
  var _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TrailerButton old) {
    super.didUpdateWidget(old);
    // 同页切换到另一部（详情页可复用同一个 State）⇒ 重拉
    if (old.itemId != widget.itemId) {
      _loaded = false;
      _trailers = const [];
      _load();
    }
  }

  Future<void> _load() async {
    final api = ref.read(embyApiProvider);
    if (api == null) return;
    try {
      final list = await api.getLocalTrailers(widget.itemId);
      if (!mounted) return;
      setState(() {
        _trailers = list;
        _loaded = true;
      });
    } catch (e) {
      // ⚠️ 预告拉取失败**不影响详情页** —— 静默降级为"没预告"
      //    （不是关键路径，弹错误会干扰用户）。但要落日志便于排查。
      debugPrint('[Detail] 预告拉取失败（非致命）: $e');
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  void _play() {
    if (_trailers.isEmpty) return;
    final t = _trailers.first;
    // ⚠️ 预告是**独立短片**（不是主片的一部分）⇒ 不传 episodes：
    //    它自己就是完整条目，不需要选集/连播上下文。
    openPlayer(context, t);
  }

  @override
  Widget build(BuildContext context) {
    // 未加载完 或 没预告 ⇒ 不占位（避免布局跳动后突然多出一个按钮）
    if (!_loaded || _trailers.isEmpty) return SizedBox.shrink();

    return Semantics(
      button: true,
      label: '预告片',
      child: SizedBox(
        // 44dp：与同排"播放"按钮等高（见 `_actionButtons` 的 SizedBox(height: 44)）
        height: 44,
        width: 44,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _play,
            borderRadius: BorderRadius.circular(Cf.radiusSm),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x14FFFFFF),
                border: Border.all(color: const Color(0x26FFFFFF)),
              ),
              child: Icon(Icons.movie_filter_outlined,
                  size: 18, color: Cf.text),
            ),
          ),
        ),
      ),
    );
  }
}
