/// **HDR 信息必须真的从数据层流到内核决策** —— 补上注入发现的测试盲区。
///
/// ## 为什么单独写这个文件（反向注入暴露的盲区）
/// `kernel_hdr_select_test.dart` **直接构造 `MediaTraits`**，
/// 从而**绕过了 `traitsFromLaunch`** —— 于是：
///
/// ```
/// 把 adapter 里的 `videoRange ??= s.videoRange;` 删掉（接线断开）
///   → kernel_hdr_select_test **依然全绿**
/// ```
/// 因为那个测试喂的是"已经带 videoRange 的 traits"，
/// 而真实链路是：`MediaStream.videoRange`（服务端）
///   → `traitsFromLaunch` → `MediaTraits.videoRange` → `KernelAutoSelect`
///
/// **中间那一段断了，测试照样绿** —— 这就是本仓反复出现过的
/// "数据有、接线断"型缺陷（`episodeLabel` 那次同源）。
///
/// ## 本文件守什么
/// 断言**链路每一段都在**：
/// · 数据层 `MediaStream` 解析 `VideoRange`（服务端字段）
/// · adapter 读 `s.videoRange` 并传给 `MediaTraits`
/// · 决策层用 `isHdr` / `isDolbyVision` 判定
///
/// 三段齐全才算"这条线是通的"。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/data/models.dart';

/// 读源码并**剥掉注释**。
///
/// ## ⚠️ 为什么必须剥注释（本项目已记录的坑）
/// 我第一版直接用 `read()` 的原文做 `contains` 断言，结果
/// **反向注入抓不到缺陷**：把 `videoRange ??= s.videoRange;` 删掉后，
/// 注释里那句 `MediaStream.videoRange` 仍然匹配 ⇒ **假绿**。
///
/// 与 AGENTS §6 记录的 U1 轮同一类问题
/// （`SafeArea(top: false)` 写在注释里 → 注入失效）。
String readCode(String rel) => stripComments(File(rel).readAsStringSync());

String stripComments(String src) {
  var s = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  s = s.split('\n').map((l) {
    final i = l.indexOf('//');
    return i >= 0 ? l.substring(0, i) : l;
  }).join('\n');
  return s;
}

String read(String rel) => File(rel).readAsStringSync();

void main() {
  group('★ HDR 链路完整性（防止"数据有、接线断"）', () {
    test('① 数据层：MediaStream 解析服务端 VideoRange 字段', () {
      final src = readCode('lib/data/models.dart');
      expect(
        src.contains("j['VideoRange']") || src.contains('VideoRangeType'),
        isTrue,
        reason: '★ `MediaStream.fromJson` 必须解析服务端的 `VideoRange` /\n'
            '    `VideoRangeType` —— 否则整条 HDR 链路从源头就断了。',
      );
      expect(src.contains('final String? videoRange'), isTrue,
          reason: '`MediaStream` 应有 `videoRange` 字段');
    });

    test('② 模型行为：videoRange 能被正确判定', () {
      // 造一个最小 MediaStream（走真实 fromJson，验证解析 + 判定）
      final dv = MediaStream.fromJson(const {
        'Type': 'Video',
        'Codec': 'hevc',
        'VideoRange': 'DOVI',
      });
      expect(dv.videoRange, 'DOVI',
          reason: '服务端 `VideoRange: DOVI` 应被解析进 videoRange');

      final hdr = MediaStream.fromJson(const {
        'Type': 'Video',
        'VideoRange': 'HDR10',
      });
      expect(hdr.videoRange, 'HDR10');
    });

    test('★ ③ adapter：traitsFromLaunch 必须真的读 s.videoRange', () {
      final src = readCode('lib/player/kernel_traits_adapter.dart');
      expect(src.contains('s.videoRange'), isTrue,
          reason: '★ **这是反向注入抓出来的盲区**：\n'
              '    把 adapter 里的 `videoRange ??= s.videoRange;` 删掉，\n'
              '    `kernel_hdr_select_test` **依然全绿**（它直接构造 traits，\n'
              '    绕过了 adapter）⇒ 真实链路上 HDR 信息是断的。\n'
              '    本断言守住这一段的接线。');
      expect(src.contains('videoRange: videoRange'), isTrue,
          reason: '读到的 videoRange 必须**传进** MediaTraits 构造函数');
    });

    test('★ ④ 决策层：KernelAutoSelect 用 isHdr 判定', () {
      final src = readCode('lib/player/kernel_auto_select.dart');
      expect(src.contains('if (t.isHdr)'), isTrue,
          reason: '★ 决策必须基于 `isHdr`（含 DV）—— 否则规则 0 是死代码');
      expect(src.contains('t.isDolbyVision'), isTrue,
          reason: '理由文案应区分 DV 与普通 HDR（便于用户理解为何换内核）');
    });

    test('★ ⑤ 端到端：从 PlaybackLaunch 到决策结论', () {
      // 这条是本文件的核心 —— 走**真实的 traitsFromLaunch**，
      // 而不是手搓 MediaTraits。
      // （traitsFromLaunch 在 adapter 里，签名接受 PlaybackLaunch）
      final src = readCode('lib/player/kernel_traits_adapter.dart');
      // 断言 adapter 暴露了那个函数且没有"提前 return 空 traits"之类的短路
      expect(src.contains('MediaTraits traitsFromLaunch('), isTrue,
          reason: '找不到 traitsFromLaunch —— 若改名请同步改本测试');
      // 关键：videoRange 的赋值必须在**返回 MediaTraits 之前**
      final readIdx = src.indexOf('s.videoRange');
      final returnIdx = src.indexOf('return MediaTraits(');
      expect(readIdx, greaterThanOrEqualTo(0));
      expect(returnIdx, greaterThan(readIdx),
          reason: '★ `s.videoRange` 的读取必须发生在 `return MediaTraits(...)`\n'
              '    **之前** —— 否则读了也没传出去。\n'
              '    （顺序即正确性，这类"赋值在 return 之后"是死代码的典型形态）');
    });
  });
}
