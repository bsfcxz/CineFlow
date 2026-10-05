/// 公共媒体卡片组件：板块容器 / 海报卡 / 继续观看卡 / 错误视图
library;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/media_provider.dart';
import '../data/models.dart';

/// 「敬请期待」轻提示（未接入功能统一入口）
void showComingSoon(BuildContext context, String feature) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('$feature 将在后续步骤接入'),
    behavior: SnackBarBehavior.floating,
    backgroundColor: Cf.surface,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Cf.border)),
  ));
}

/// 板块容器：竖条标题 + 右侧「全部」
class CfSection extends StatelessWidget {
  const CfSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.onTrailing,
    this.padding = const EdgeInsets.only(top: 22),
  });
  final String title;
  final Widget child;
  final String? trailing;
  final VoidCallback? onTrailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(children: [
            Container(
              width: 4,
              height: 17,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: Cf.primaryGradient,
              ),
            ),
            SizedBox(width: 8),
            Text(title,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.3)),
            const Spacer(),
            if (trailing != null)
              GestureDetector(
                onTap: onTrailing,
                child: Text(trailing!,
                    style: TextStyle(fontSize: 11, color: Cf.text3)),
              ),
          ]),
        ),
        child,
      ]),
    );
  }
}

/// 海报卡（2:3，评分角标 / 已看标记 / 标题浮层）
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.api,
    this.onTap,
  });
  final MediaItem item;
  final MediaProvider api;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final url = item.posterUrl(api);
    return GestureDetector(
      onTap: onTap,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Cf.border),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Stack(fit: StackFit.expand, children: [
                if (url != null)
                  Image.network(url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _ph())
                else
                  _ph(),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [.45, 1],
                      colors: [Colors.transparent, Color(0xD1000000)],
                    ),
                  ),
                ),
                if (item.communityRating case final r?)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        color: const Color(0xBF000000),
                      ),
                      child: Text('⭐ ${r.toStringAsFixed(1)}',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Cf.warn)),
                    ),
                  ),
                if (item.played)
                  Positioned(
                    bottom: 26,
                    right: 7,
                    child: Container(
                      width: 17,
                      height: 17,
                      decoration: BoxDecoration(
                          color: Cf.accent, shape: BoxShape.circle),
                      child: Icon(Icons.check_rounded,
                          size: 12, color: Cf.ink),
                    ),
                  ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 6,
                  child: Text(item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                          color: Colors.white,
                          shadows: [
                            Shadow(blurRadius: 4, color: Colors.black87)
                          ])),
                ),
              ]),
            ),
          ),
        ),
        SizedBox(height: 5),
        Text(
          [
            if (item.productionYear != null) '${item.productionYear}',
            item.typeLabel,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 9.5, color: Cf.text3),
        ),
      ]),
    );
  }

  Widget _ph() => Container(
        color: Cf.surface2,
        alignment: Alignment.center,
        child: Icon(Icons.movie_outlined, size: 26, color: Cf.text3),
      );
}

/// 海报网格（手机 3 列）
class PosterGrid extends StatelessWidget {
  const PosterGrid({
    super.key,
    required this.items,
    required this.api,
    this.onItemTap,
  });
  final List<MediaItem> items;
  final MediaProvider api;
  final void Function(MediaItem)? onItemTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: items.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2 / 3.45,
        ),
        itemBuilder: (context, i) =>
            PosterCard(item: items[i], api: api, onTap: onItemTap == null ? null : () => onItemTap!(items[i])),
      ),
    );
  }
}

/// 继续观看横卡（16:9 + 集数徽标 + 进度条）
class ContinueCard extends StatelessWidget {
  const ContinueCard({
    super.key,
    required this.item,
    required this.api,
    this.onTap,
  });
  final MediaItem item;
  final MediaProvider api;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final url = item.thumbUrl(api);
    final remain = item.remainingMinutes;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 200,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 200,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Cf.border),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(fit: StackFit.expand, children: [
                  if (url != null)
                    Image.network(url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => _ph())
                  else
                    _ph(),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [.5, 1],
                        colors: [Colors.transparent, Color(0xB3000000)],
                      ),
                    ),
                  ),
                  if (item.seasonEpisode case final se?)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          color: const Color(0xB3000000),
                          border:
                              Border.all(color: const Color(0x4D00D4FF)),
                        ),
                        child: Text(se,
                            style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: Cf.accent)),
                      ),
                    ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 3,
                      color: const Color(0x38FFFFFF),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: item.progress,
                        child: Container(
                            decoration:
                                BoxDecoration(gradient: Cf.primaryGradient)),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          SizedBox(height: 9),
          Text(item.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          SizedBox(height: 3),
          Text(
            remain != null ? '剩余 $remain 分钟' : '继续播放',
            style: TextStyle(fontSize: 10, color: Cf.text3),
          ),
        ]),
      ),
    );
  }

  Widget _ph() => Container(
        decoration: BoxDecoration(
          gradient:
              LinearGradient(colors: [Color(0x26111A33), Color(0x33111A33)]),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.movie_creation_outlined,
            size: 30, color: Cf.text3),
      );
}

/// 加载失败视图
class CfErrorView extends StatelessWidget {
  const CfErrorView({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child:
            Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.cloud_off_rounded, size: 44, color: Cf.text3),
          SizedBox(height: 14),
          Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12.5, color: Cf.text2, height: 1.6)),
          SizedBox(height: 18),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: Cf.accent,
              side: BorderSide(color: Cf.accent),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            ),
            child: Text('重试'),
          ),
        ]),
      ),
    );
  }
}
