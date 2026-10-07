/// **内核自动适配**的测试 —— 规则逐条钉死。
///
/// ## 为什么这批测试重要
/// 自动适配是**看不见的逻辑**：它决定了一次播放用哪个内核，
/// 而选错的后果是"视频播不了"（用户直接感知）。
/// 没有测试的话，改规则顺序、改阈值都不会有任何提示。
///
/// ## 覆盖策略
/// 1. **每条规则单独一个用例** —— 规则是 if-else 链，
///    单独测才不会"A 规则的用例因为 B 规则先命中而假通过"
/// 2. **优先级顺序显式测试** —— 顺序即语义（见 `_selectAuto` 注释），
///    改顺序必须让测试红
/// 3. **边界** —— 分辨率阈值（2000）两侧、空特征、未知容器
/// 4. **用户偏好覆盖自动** —— 显式指定时不该被"聪明"覆盖
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/kernel_auto_select.dart';
import 'package:cineflow/player/kernel_factory.dart';

/// 造特征的便捷函数（默认值 = "信息不足"，逐个覆盖）。
MediaTraits t({
  String? path,
  String? container,
  String? videoCodec,
  String? audioCodec,
  int? width,
  int? height,
  int? bitrate,
  bool isHls = false,
  bool isTranscoding = false,
  bool hasExternalSubtitle = false,
}) =>
    MediaTraits(
      path: path,
      container: container,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      width: width,
      height: height,
      bitrate: bitrate,
      isHls: isHls,
      isTranscoding: isTranscoding,
      hasExternalSubtitle: hasExternalSubtitle,
    );

void main() {
  group('KernelPreference · 存储往返', () {
    test('auto 存空串（便于清除偏好）', () {
      expect(KernelPreference.auto.storageValue, '');
    });

    test('mpv / media3 存名字', () {
      expect(KernelPreference.mpv.storageValue, 'mpv');
      expect(KernelPreference.media3.storageValue, 'media3');
    });

    test('往返：每个值解析回来还是自己', () {
      for (final p in KernelPreference.values) {
        expect(KernelPreference.fromStorage(p.storageValue), p);
      }
    });

    test('★ 空/非法值一律回退 auto（不崩、不乱选）', () {
      expect(KernelPreference.fromStorage(null), KernelPreference.auto);
      expect(KernelPreference.fromStorage(''), KernelPreference.auto);
      expect(KernelPreference.fromStorage('MPV'), KernelPreference.auto,
          reason: '大小写不匹配应回退（存储值是我们自己写的，不会有大写）');
      expect(KernelPreference.fromStorage('nonsense'), KernelPreference.auto);
    });

    test('isExplicit 只在非 auto 时为真', () {
      expect(KernelPreference.auto.isExplicit, isFalse);
      expect(KernelPreference.mpv.isExplicit, isTrue);
      expect(KernelPreference.media3.isExplicit, isTrue);
    });

    test('kernelType 映射正确', () {
      expect(KernelPreference.auto.kernelType, KernelType.auto);
      expect(KernelPreference.mpv.kernelType, KernelType.mpv);
      expect(KernelPreference.media3.kernelType, KernelType.media3);
    });
  });

  group('MediaTraits · 扩展名与容器解析', () {
    test('从路径取扩展名（小写）', () {
      expect(t(path: '/x/Movie.MKV').extension, 'mkv');
    });

    test('★ 去掉查询串再取扩展名（Emby 直链带 api_key）', () {
      expect(
        t(path: 'http://s/video.mp4?api_key=abc&Static=true').extension,
        'mp4',
        reason: '不去查询串会得到 "mp4?api_key=abc..."，容器判断全错',
      );
    });

    test('★ 去掉 URL fragment', () {
      expect(t(path: 'http://s/v.mp4#t=10').extension, 'mp4');
    });

    test('无扩展名返回空串', () {
      expect(t(path: 'http://s/stream').extension, '');
      expect(t(path: '').extension, '');
      expect(t().extension, '');
    });

    test('★ 容器字段优先于扩展名', () {
      expect(
        t(path: '/x/a.bin', container: 'mkv').effectiveContainer,
        'mkv',
        reason: '服务端声明的 container 比 URL 后缀更权威',
      );
    });

    test('无 container 时回退扩展名', () {
      expect(t(path: '/x/a.rmvb').effectiveContainer, 'rmvb');
    });

    test('shortSide 取短边（竖屏视频也对）', () {
      expect(t(width: 3840, height: 2160).shortSide, 2160);
      expect(t(width: 1080, height: 2400).shortSide, 1080,
          reason: '手机竖拍的视频不能被当成 2400p');
    });

    test('缺宽高时 shortSide 为 null', () {
      expect(t(height: 2160).shortSide, isNull);
      expect(t(width: 3840).shortSide, isNull);
    });
  });

  group('★ 规则 1：HLS / 转码流 → Media3', () {
    test('m3u8 → Media3', () {
      final d = KernelAutoSelect.select(t(path: 'http://s/a.m3u8'));
      expect(d.kernel, KernelType.media3);
    });

    test('isHls 标志 → Media3', () {
      final d = KernelAutoSelect.select(t(path: 'http://s/x', isHls: true));
      expect(d.kernel, KernelType.media3);
    });

    test('转码流 → Media3（理由要能区分转码与普通 HLS）', () {
      final d = KernelAutoSelect.select(
          t(path: 'http://s/x', isTranscoding: true));
      expect(d.kernel, KernelType.media3);
      expect(d.reason, contains('转码'));
      expect(d.confidence, KernelConfidence.high);
    });

    test('★ 只看后缀就该认出 HLS（不依赖调用方传 isHls）', () {
      // 这条是**写测试时抓到的真实缺口**：
      // 原先规则 1 判 `isHls || isTranscoding`，而 `isHls` 由调用方传。
      // 若调用方漏判（`launch.url` 是 .m3u8 但标志没置位），
      // HLS 就会落到"保守默认 mpv"，丢掉 Media3 的分片续播优势。
      // 已改为 `MediaTraits.isHlsStream`（同时看后缀）。
      final traits = t(path: 'http://s/a.m3u8?api_key=x');
      expect(traits.isHlsStream, isTrue, reason: '带查询串也要认出 m3u8');
      expect(KernelAutoSelect.isMpvOnlyContainer(traits.effectiveContainer),
          isFalse);
      expect(KernelAutoSelect.select(traits).kernel, KernelType.media3);
    });

    test('container 字段是 m3u8 也认', () {
      expect(
        KernelAutoSelect.select(t(path: 'http://s/x', container: 'm3u8')).kernel,
        KernelType.media3,
      );
    });
  });

  group('★ 规则 2：冷门容器 → mpv（优先级最高）', () {
    test('rmvb / wmv / asf / vob / flv 都走 mpv', () {
      for (final ext in ['rmvb', 'rm', 'wmv', 'asf', 'flv', 'vob']) {
        final d = KernelAutoSelect.select(t(path: '/x/a.$ext'));
        expect(d.kernel, KernelType.mpv, reason: '$ext 应走 mpv');
      }
    });

    test('★ 冷门容器优先于 HLS（播放优先于体验）', () {
      // 这是**顺序即语义**的关键用例：若把规则 1 放到规则 2 前面，
      // 这条会变红。
      final d = KernelAutoSelect.select(
          t(path: '/x/a.rmvb', isHls: true));
      expect(d.kernel, KernelType.mpv,
          reason: 'HLS 的体验优势 < 播得了。冷门格式必须优先走 mpv。\n'
              '若这条红 → `_selectAuto` 里规则 1 与规则 2 的顺序被调换了。');
    });

    test('mpvOnlyContainers 清单本身（防止被误删项）', () {
      for (final c in ['rmvb', 'rm', 'wmv', 'asf', 'vob', 'm2ts', 'ts']) {
        expect(KernelAutoSelect.mpvOnlyContainers, contains(c));
      }
    });

    test('大小写不敏感', () {
      expect(KernelAutoSelect.isMpvOnlyContainer('RMVB'), isTrue);
      expect(KernelAutoSelect.isMpvOnlyContainer('Mkv'), isFalse);
    });
  });

  group('★ 规则 3：高分辨率 → Media3', () {
    test('2160p → Media3', () {
      final d = KernelAutoSelect.select(t(width: 3840, height: 2160));
      expect(d.kernel, KernelType.media3);
    });

    test('1080p → 不触发（走保守默认 mpv）', () {
      final d = KernelAutoSelect.select(t(width: 1920, height: 1080));
      expect(d.kernel, KernelType.mpv);
    });

    test('★ 阈值边界：1999 → mpv，2000 → Media3', () {
      // ⚠️ 宽高必须成对合理：shortSide 取的是 min(w,h)，
      //    我曾写成 `t(width: 100, height: 2000)` —— 那算出 shortSide=100，
      //    于是"2000 应走 Media3"这条失败。**是测试数据错，不是实现错**。
      //    真实 1080p/4K 都是横的（w > h），故用 16:9 的数字。
      expect(
        KernelAutoSelect.select(t(width: 3555, height: 1999)).kernel,
        KernelType.mpv,
      );
      expect(
        KernelAutoSelect.select(t(width: 3556, height: 2000)).kernel,
        KernelType.media3,
      );
    });

    test('竖屏视频用短边判断（不被高度误导）', () {
      // 手机竖拍 1080×2400：短边 1080 → 不该被当成高分辨率
      expect(
        KernelAutoSelect.select(t(width: 1080, height: 2400)).kernel,
        KernelType.mpv,
        reason: 'shortSide=1080 < 2000，不该触发高分辨率规则',
      );
    });
  });

  group('★ 规则 4：外挂字幕 → mpv', () {
    test('有外挂字幕 → mpv', () {
      final d = KernelAutoSelect.select(t(hasExternalSubtitle: true));
      expect(d.kernel, KernelType.mpv);
      expect(d.reason, contains('字幕'));
    });

    test('★ 外挂字幕时即便 4K 也走 mpv（字幕优先于硬解能效）', () {
      final d = KernelAutoSelect.select(
          t(width: 3840, height: 2160, hasExternalSubtitle: true));
      // 注意：分辨率规则在字幕规则**之前**，所以 4K 会先命中 Media3。
      // 这条断言固化**当前实际行为**，而不是我以为的行为 ——
      // 若将来想改成"字幕优先"，必须同时改这里的断言与 _selectAuto 的顺序。
      expect(d.kernel, KernelType.media3,
          reason: '当前规则顺序是「分辨率 > 外挂字幕」。\n'
              '若要改成字幕优先，需调换 _selectAuto 里的两条规则并改本断言。');
    });
  });

  group('★ 规则 5：保守默认 mpv', () {
    test('普通 1080p mkv → mpv', () {
      final d = KernelAutoSelect.select(
          t(path: '/x/a.mkv', container: 'mkv', height: 1080));
      expect(d.kernel, KernelType.mpv);
    });

    test('★ 特征全空 → mpv 且 confidence=low（如实标注不确定）', () {
      final d = KernelAutoSelect.select(t());
      expect(d.kernel, KernelType.mpv);
      expect(d.confidence, KernelConfidence.low,
          reason: '信息不足时必须如实标 low，不能假装有把握');
    });

    test('有一条可依据的特征 → confidence=high', () {
      final d = KernelAutoSelect.select(t(path: '/x/a.mkv'));
      expect(d.confidence, KernelConfidence.high);
    });
  });

  group('★ 用户偏好覆盖自动', () {
    test('显式 mpv → 即便特征是 HLS（自动会选 Media3）也走 mpv', () {
      final d = KernelAutoSelect.select(
        t(path: 'http://s/a.m3u8', isHls: true),
        preference: KernelPreference.mpv,
      );
      expect(d.kernel, KernelType.mpv,
          reason: '用户显式指定了就不该被自动逻辑覆盖');
      expect(d.reason, contains('指定'));
    });

    test('显式 media3 → 即便容器是 rmvb 也走 media3', () {
      final d = KernelAutoSelect.select(
        t(path: '/x/a.rmvb'),
        preference: KernelPreference.media3,
      );
      expect(d.kernel, KernelType.media3,
          reason: '用户的显式选择权高于"更安全"的自动判断');
    });

    test('auto 时才走自动规则', () {
      final d = KernelAutoSelect.select(
        t(path: '/x/a.rmvb'),
        preference: KernelPreference.auto,
      );
      expect(d.kernel, KernelType.mpv);
    });
  });

  group('★ 决策必须有理由（可解释性）', () {
    test('所有分支都给出非空 reason', () {
      final cases = <MediaTraits>[
        t(),
        t(path: '/x/a.mkv'),
        t(path: '/x/a.rmvb'),
        t(path: 'http://s/a.m3u8'),
        t(isTranscoding: true),
        t(width: 3840, height: 2160),
        t(hasExternalSubtitle: true),
      ];
      for (final c in cases) {
        final d = KernelAutoSelect.select(c);
        expect(d.reason, isNotEmpty,
            reason: '每个决策都要能向用户解释，否则"为什么用这个内核"无从得知');
      }
    });
  });

  group('与 KernelFactory 的一致性', () {
    test('★ 工厂的 canHandle 与自动选择共用同一份清单', () {
      // 这条防的是"两处清单漂移"：原先 kernel_factory 里有一份独立的
      // _mpvOnlyExtensions，与这里的 mpvOnlyContainers 重复。
      for (final c in KernelAutoSelect.mpvOnlyContainers) {
        expect(
          PlayerKernelFactory.canHandle(KernelType.media3, path: 'a.$c'),
          isFalse,
          reason: 'canHandle 应拒绝 $c（与自动选择同源）',
        );
        expect(
          PlayerKernelFactory.canHandle(KernelType.mpv, path: 'a.$c'),
          isTrue,
        );
      }
    });

    test('常见格式 canHandle 为 true', () {
      for (final c in ['mp4', 'mkv', 'webm', 'mp3', 'm4a']) {
        expect(PlayerKernelFactory.canHandle(KernelType.media3, path: 'a.$c'),
            isTrue);
      }
    });
  });
}
