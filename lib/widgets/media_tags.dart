/// **状态标签 / 平台标签 / 玻璃 chip** —— 日历与首页共用的视觉组件。
///
/// ## 为什么抽成独立文件（用户 2026-10-12）
/// > "全部复用详情页那两个组件"
/// 我第一版把这几个组件写成了 `calendar_detail_sheet.dart` 里的**私有类**
/// （`_StatusTag` / `_PlatformTag`），结果首页 hero 只能自己另写一套
/// 灰色 chip ⇒ **同一个 App 里两套标签样式**（用户一眼看出"没遵守 UI 设计"）。
///
/// ⇒ 抽到这里并公开（去掉下划线），两处 import 同一个组件。
///
/// ## 用户/稿子的规格
/// | 状态 | 视觉 |
/// |---|---|
/// | 连载中 | 绿渐变 `#22c55e→#16a34a` + **白点闪烁**（1.5s）|
/// | 已完结 | 灰渐变 `#64748b→#475569`（静态）|
/// | 已上映 | 橙渐变 `#f59e0b→#d97706`（电影）|
///
/// 平台按**品牌色**（腾讯蓝/爱奇艺绿/优酷青/芒果橙/B站粉/Netflix红），
/// 稿子原话："让用户一眼能认出播出方"。
library;

import 'package:flutter/material.dart';

import '../core/theme.dart';

// ══════════════════════════════════════════════════════════════
// 状态判定（把三种数据源的写法归一）
// ══════════════════════════════════════════════════════════════

/// 从**任意来源**的状态字符串判定种类：`live` / `end` / `new`。
///
/// ## 为什么要归一（三个源的写法都不一样）
/// | 来源 | 连载中 | 已完结 | 已上映 |
/// |---|---|---|---|
/// | Emby | `Continuing` | `Ended` | — |
/// | TMDB | `Returning Series` / `In Production` / `Planned` | `Ended` / `Canceled` | `Released` |
/// | 本仓库订阅表 | `连载中` | `已完结` | — |
///
/// ## 为什么不写成三个函数
/// 首页 hero 用 `MediaItem`（Emby），详情页用 `CalendarEntry`（TMDB）
/// —— 若各写一个，两边**必然会漂移**（我第一轮就是这样：详情页有彩色标签、
/// 首页只有灰 chip）。归一后两处共用同一套判定。
///
/// ## 电影优先
/// 用户规格明确"已上映 橙色（电影）"：电影的 TMDB status 是 `Released`，
/// 与剧集的 `Ended` 语义不同 ⇒ 先判电影。
String? statusKindFrom(String? raw, {bool isMovie = false}) {
  if (isMovie) return 'new';
  if (raw == null || raw.isEmpty) return null;
  return switch (raw) {
    // Emby
    'Continuing' => 'live',
    'Ended' => 'end',
    // TMDB
    'Returning Series' || 'In Production' || 'Planned' => 'live',
    'Canceled' => 'end',
    'Released' => 'new',
    // 本仓库订阅表的中文快照
    '连载中' => 'live',
    '已完结' => 'end',
    '已上映' => 'new',
    _ => null,
  };
}

/// 种类 → 中文标签。
String statusTextOf(String kind) => switch (kind) {
      'live' => '连载中',
      'end' => '已完结',
      'new' => '已上映',
      _ => '',
    };

// ══════════════════════════════════════════════════════════════
// 组件
// ══════════════════════════════════════════════════════════════

/// 状态标签（彩色 + 连载中闪烁）。
class CfStatusTag extends StatefulWidget {
  const CfStatusTag({super.key, required this.kind});

  /// `live` / `end` / `new`
  final String kind;

  @override
  State<CfStatusTag> createState() => _CfStatusTagState();
}

class _CfStatusTagState extends State<CfStatusTag>
    with SingleTickerProviderStateMixin {
  /// 闪烁动画（只有"连载中"需要）。
  ///
  /// ## 为什么要真的动
  /// 用户明确要求"绿色 + 闪烁点（动态）"—— 静态绿点与"已完结"的视觉差异
  /// 在小字号下不够；闪烁传达"还在更新中"，是稿子刻意的信号。
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();
    if (widget.kind == 'live') _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static const _pairs = <String, (Color, Color)>{
    'live': (Color(0xFF22C55E), Color(0xFF16A34A)),
    'end': (Color(0xFF64748B), Color(0xFF475569)),
    'new': (Color(0xFFF59E0B), Color(0xFFD97706)),
  };

  @override
  Widget build(BuildContext context) {
    final (c1, c2) = _pairs[widget.kind] ?? _pairs['end']!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c1, c2]),
        borderRadius: BorderRadius.circular(Cf.radiusXs),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (widget.kind == 'live') ...[
          FadeTransition(
            opacity: Tween<double>(begin: 1, end: 0.15).animate(_c),
            child: Container(
              width: 5,
              height: 5,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Colors.white),
            ),
          ),
          const SizedBox(width: 4),
        ],
        Text(statusTextOf(widget.kind),
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ]),
    );
  }
}

/// 平台标签（**品牌色**；未收录的平台用中性灰）。
///
/// ## 为什么不编造品牌色
/// 稿子只给了 6 个平台的色值。其它平台（TVB Jade / CCTV / 百度…）
/// 若随便上个色，用户会以为那是**该平台的官方色** ⇒ 反而误导。
/// ⇒ 一律中性灰。
class CfPlatformTag extends StatelessWidget {
  const CfPlatformTag({super.key, required this.name});

  final String name;

  static const _brands = <String, (Color, Color)>{
    '腾讯': (Color(0xFF2563EB), Color(0xFF3B82F6)),
    '爱奇艺': (Color(0xFF16A34A), Color(0xFF22C55E)),
    '优酷': (Color(0xFF0891B2), Color(0xFF06B6D4)),
    '芒果': (Color(0xFFEA580C), Color(0xFFF97316)),
    'B站': (Color(0xFFDB2777), Color(0xFFEC4899)),
    '哔哩': (Color(0xFFDB2777), Color(0xFFEC4899)),
    'Netflix': (Color(0xFFDC2626), Color(0xFFEF4444)),
  };

  (Color, Color) _colors() {
    for (final e in _brands.entries) {
      if (name.contains(e.key)) return e.value;
    }
    return const (Color(0xFF475569), Color(0xFF64748B));
  }

  @override
  Widget build(BuildContext context) {
    final (c1, c2) = _colors();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c1, c2]),
        borderRadius: BorderRadius.circular(Cf.radiusXs),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 5,
          height: 5,
          decoration: const BoxDecoration(
              shape: BoxShape.circle, color: Colors.white),
        ),
        const SizedBox(width: 4),
        Text(name,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ]),
    );
  }
}

/// 玻璃质感 chip（年份/类型；在图上才看得清）。
class CfGlassChip extends StatelessWidget {
  const CfGlassChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          // 稿子：`rgba(255,255,255,.15)` + blur
          color: const Color(0x26FFFFFF),
          borderRadius: BorderRadius.circular(Cf.radiusXs),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 11, color: Colors.white)),
      );
}

/// 金色评分（稿子 `.score { color: #f5c518; font-weight: 700; font-size: 14px }`）。
///
/// ⚠️ 稿子的评分**没有底色**（`background: transparent`）——
/// 它是"数值"不是"标签"，加底色会让 meta 行显得杂乱。
class CfScoreText extends StatelessWidget {
  const CfScoreText({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 15, color: Color(0xFFF5C518)),
          const SizedBox(width: 2),
          Text(value.toStringAsFixed(1),
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFF5C518))),
        ],
      );
}

/// 从日期串取年份（`2026-10-08` → `2026`）。
String? yearOfDate(String? d) {
  if (d == null || d.length < 4) return null;
  final y = d.substring(0, 4);
  return int.tryParse(y) == null ? null : y;
}

/// **平台常规首播时刻**（`20:00` / `23:30` 这种）。
///
/// ## ★★ 这不是"该剧的精确播出时刻"（实测证据）
/// 在**两台真实 Emby 服务器**上完整核过，精确时刻**不存在于现有源**：
/// ```
/// ① 分集 PremiereDate 的时间部分：
///    iLoveHD  00:00:00 ×40    ← 全是"日期零点"
///    HK-Emby  16:00:00 ×39    ← 16:00Z = 北京次日 0 点，同样是零点
/// ② 剧级 AirTime / AirDays：**两台全部 None / 空数组**
/// ③ TMDB 只有 air_date，没有 air_time
/// ```
/// ⇒ 拿不到"这部剧几点播"。
///
/// ## 那 20:00 / 23:30 从哪来
/// 是**中国大陆平台的常规首播时刻**（公开、稳定）：
/// · 腾讯/爱奇艺/优酷/芒果 ⇒ **20:00**（会员抢先看）
/// · B站番剧 ⇒ **23:30**
/// · CCTV 电视剧频道 ⇒ **19:30**
/// 稿子对芒果TV 写 20:00、对 B 站写 23:30 —— 与此表吻合。
///
/// ## 返回 null 的含义
/// 认不出平台 ⇒ **不显示**（本仓库一贯口径：宁可不显示，也不编数字）。
String? platformAirTime(String? platform) {
  if (platform == null || platform.isEmpty) return null;
  final p = platform.toLowerCase();
  // B站番剧：23:30
  if (p.contains('b站') || p.contains('bilibili') || p.contains('哔哩')) {
    return '23:30';
  }
  // CCTV 电视剧频道：19:30
  if (p.contains('cctv') || p.contains('央视')) return '19:30';
  // 主流长视频平台：20:00
  for (final k in const [
    '腾讯', 'tencent', 'weixin',
    '爱奇艺', 'iqiyi',
    '优酷', 'youku',
    '芒果', 'mango', 'mgtv',
    '咪咕', 'migu',
    '乐视', 'letv',
    '搜狐', 'sohu',
    '西瓜', 'ixigua',
  ]) {
    if (p.contains(k)) return '20:00';
  }
  return null;
}
