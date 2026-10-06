/// 关于页 —— 应用介绍、技术栈、开源致谢、许可与免责声明。
///
/// 为什么单独做一页（而不是塞进「我的」页）：
///   1. 第三方 Emby 客户端需要**明示"与 Emby Corp. 无关联"**，
///      这是合规要求，不该藏在设置列表里点两下才看到；
///   2. 本项目按 Apache-2.0 发布，且捆绑 libmpv（LGPL）、移植了 115driver
///      的算法（MIT）——**许可与出处必须对用户可见**，不能只躺在仓库的 NOTICE 里；
///   3. 「关于」是用户排查问题时的第一站：需要一眼看到版本号、
///      播放内核、以及"这些数据从哪来"。
///
/// 内容与 `NOTICE` / `LICENSE` / `docs/OSS-SOURCES.md` 保持一致；
/// **改依赖或许可时三处一起改**（否则又是一次"文档比代码乐观"）。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../core/version.dart';

/// 项目主页（Releases 与 Issue 都从这里进）
const _repoUrl = 'https://github.com/bsfcxz/CineFlow';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Cf.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              const BackButton(color: Cf.text),
              const Text('关于',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 18),

            _header(),
            const SizedBox(height: 16),

            _intro(),
            const SizedBox(height: 14),

            _section('技术栈', [
              _row('界面', 'Flutter 3.x + Material 3'),
              _row('状态管理', 'Riverpod 3.x'),
              _row('播放内核', '安卓原生 mpv（libmpv）'),
              _row('核心逻辑层', 'Go（经 FFI 桥接）'),
              _row('路由 / 本地库', 'go_router · drift(SQLite)'),
              _row('网络', 'dio'),
            ]),
            const SizedBox(height: 14),

            _section('功能', [
              _row('媒体库', 'Emby 服务端直连（第三方客户端）'),
              _row('弹幕', '弹弹play 官方源 + 自建兼容源'),
              _row('115 网盘', '扫码登录 · 文件浏览 · 直链播放'),
              _row('榜单 / 搜索', '豆瓣公开接口'),
            ]),
            const SizedBox(height: 14),

            _section('开源致谢', [
              _link('mpv-android', 'libmpv 的 Android 集成方案（Surface→wid）',
                  'https://github.com/mpv-android/mpv-android', 'MIT'),
              _link('androidx/media', 'MediaSession 会话层参考',
                  'https://github.com/androidx/media', 'Apache-2.0'),
              _link('media-kit', 'Flutter 纹理输出方案参考',
                  'https://github.com/media-kit/media-kit', 'MIT'),
              _link('mpv-player/mpv', 'libmpv 本体',
                  'https://github.com/mpv-player/mpv', 'LGPL-2.1+'),
              _link('115driver', '115 协议与 m115 算法来源',
                  'https://github.com/SheltonZhu/115driver', 'MIT'),
              _link('canvas_danmaku', '弹幕轨道算法思路',
                  'https://github.com/Predidit/canvas_danmaku', 'MIT'),
              _link('Riverpod / dio / go_router / drift', '基础依赖',
                  'https://github.com/rrousselGit/riverpod', 'MIT / BSD'),
            ]),
            const SizedBox(height: 14),

            _licenseSection(),
            const SizedBox(height: 14),

            _disclaimer(),
            const SizedBox(height: 20),

            Center(
              child: Text('CineFlow $kAppVersionLabel',
                  style: TextStyle(fontSize: 10, color: Cf.text3)),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // ---------- 头部：图标 + 名称 + 版本 ----------

  Widget _header() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Cf.surface, Cf.surface2],
        ),
        border: Border.all(color: Cf.border),
      ),
      child: Column(children: [
        const CfLogo(size: 64, radius: 17),
        const SizedBox(height: 12),
        const Text('CineFlow 影流',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(kAppVersionLabel,
            style: TextStyle(fontSize: 12, color: Cf.text3)),
        const SizedBox(height: 10),
        Text('Material 风格的 Emby 第三方播放器',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Cf.text2)),
      ]),
    );
  }

  Widget _intro() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Cf.surface,
        border: Border.all(color: Cf.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('这是什么',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          'CineFlow 是一个面向 Android 手机的 Emby 客户端。'
          '媒体库、详情、播放全部由你自建的 Emby 服务器真实数据驱动，'
          '应用本身不托管任何影视内容。',
          style: TextStyle(fontSize: 12, color: Cf.text2, height: 1.65),
        ),
        const SizedBox(height: 8),
        Text(
          '播放内核为自持的 libmpv（安卓原生集成，非插件），'
          '支持全格式硬解、音轨与字幕切换、弹幕叠加；'
          '另有 115 网盘直连播放与豆瓣榜单。',
          style: TextStyle(fontSize: 12, color: Cf.text2, height: 1.65),
        ),
      ]),
    );
  }

  // ---------- 许可 ----------

  Widget _licenseSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Cf.surface,
        border: Border.all(color: Cf.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('开源许可',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Row(children: [
          _pill('Apache-2.0', Cf.success),
          const SizedBox(width: 6),
          _pill('源码公开', Cf.accent),
        ]),
        const SizedBox(height: 10),
        Text(
          '本项目以 Apache License 2.0 发布，源码公开可查。'
          '捆绑的 libmpv 以动态链接方式分发（LGPL-2.1+）；'
          '115 相关算法移植自 115driver（MIT），许可文件原样保留在仓库中。',
          style: TextStyle(fontSize: 11, color: Cf.text2, height: 1.65),
        ),
        const SizedBox(height: 12),
        _actionRow(
          icon: Icons.code_rounded,
          label: '查看源码 / 反馈问题',
          onTap: () => _openUrl(_repoUrl),
        ),
      ]),
    );
  }

  // ---------- 免责声明 ----------

  Widget _disclaimer() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0x14FFB347), // 提示色 8% 透明
        border: Border.all(color: const Color(0x40FFB347)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.info_outline_rounded, size: 16, color: Cf.warn),
          const SizedBox(width: 6),
          Text('免责声明',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w800, color: Cf.warn)),
        ]),
        const SizedBox(height: 8),
        Text(
          '· 本项目是第三方客户端，与 Emby Corp.、115 网盘、豆瓣均无关联，'
          '亦未获其背书。\n'
          '· 不提供、不托管、不分发任何影视内容；所有媒体均来自你自行配置的服务器。\n'
          '· 豆瓣数据来自其公开页面接口，仅供学习与个人使用，未持久化转储。\n'
          '· 115 网盘走的是非公开接口，存在账号风控风险，请自行评估后使用。\n'
          '· 「Emby」是其权利人的商标，此处仅作兼容性说明之用。',
          style: TextStyle(fontSize: 11, color: Cf.text2, height: 1.75),
        ),
      ]),
    );
  }

  // ---------- 小组件 ----------

  Widget _section(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Cf.surface,
        border: Border.all(color: Cf.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        ...children,
      ]),
    );
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 78,
          child: Text(k, style: TextStyle(fontSize: 12, color: Cf.text3)),
        ),
        Expanded(
          child: Text(v,
              style: TextStyle(fontSize: 12, color: Cf.text2, height: 1.5)),
        ),
      ]),
    );
  }

  /// 开源项目行：名称 + 许可 + 说明，点击跳 GitHub
  Widget _link(String name, String desc, String url, String license) {
    return InkWell(
      onTap: () => _openUrl(url),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 6),
                Text(license, style: TextStyle(fontSize: 9, color: Cf.text3)),
              ]),
              const SizedBox(height: 2),
              Text(desc,
                  style: TextStyle(fontSize: 10, color: Cf.text3, height: 1.4)),
            ]),
          ),
          Icon(Icons.open_in_new_rounded, size: 16, color: Cf.text3),
        ]),
      ),
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: color.withValues(alpha: .14),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700)),
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Cf.surface2,
          border: Border.all(color: Cf.border),
        ),
        child: Row(children: [
          Icon(icon, size: 16, color: Cf.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          Icon(Icons.chevron_right_rounded, size: 16, color: Cf.text3),
        ]),
      ),
    );
  }

  /// 打开外部链接。
  ///
  /// 失败**静默**——关于页点不开链接不该弹错误打断用户
  /// （没有浏览器 / 系统无可用 handler 都会抛，属正常情况）。
  static Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // 忽略：关于页的链接打不开不影响任何功能
    }
  }
}
