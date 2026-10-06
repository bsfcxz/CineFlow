/// 双内核（mpv + Media3）的抽象层测试。
///
/// ## 要守的核心不变量
/// 1. **两者实现同一接口** —— 若 `Media3Kernel` 漏实现某个方法，
///    Dart 根本编译不过（`implements` 的强制力）。这条不需要测试。
/// 2. **能力声明必须如实** —— 这条**需要**测试：`supports()` 是可以随便写的，
///    写错了不报错，只会在 UI 上表现为"按钮点了没反应"。
/// 3. **不支持的能力被调用时不抛异常** —— 健壮性。
/// 4. **工厂的默认选择与理由一致** —— 默认必须是 mpv（格式覆盖）。
/// 5. **事件 JSON 形状一致** —— 两者共用 Dart 侧解析，形状不同会静默出空轨道。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:cineflow/player/domain/player_constants.dart' show DecodeMode;
import 'package:cineflow/player/kernel.dart';
import 'package:cineflow/player/kernel_event_parser.dart';
import 'package:cineflow/player/kernel_factory.dart';
import 'package:cineflow/player/media3/media3_kernel.dart';
import 'package:cineflow/player/native/native_kernel.dart';

void main() {
  // ⚠️ 必须先初始化 binding：两个内核的构造函数都会调
  //    `EventChannel(...).receiveBroadcastStream()`，而它走
  //    `ServicesBinding.instance` → 未初始化时抛
  //    "Binding has not yet been initialized"（实测 11 个测试全红）。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KernelType · 类型与文案', () {
    test('三档：自动 / mpv / Media3', () {
      expect(KernelType.values.length, 3);
      expect(KernelType.auto.label, '自动');
      expect(KernelType.mpv.label, 'mpv 内核');
      expect(KernelType.media3.label, 'Media3 内核');
    });
  });

  group('PlayerKernelFactory · 创建', () {
    test('★ 默认（auto）选 mpv —— 格式覆盖最全是刚需', () {
      expect(PlayerKernelFactory.autoResolvesTo, KernelType.mpv,
          reason: '默认必须是 mpv：本项目主力是"播放用户自己的各种片源"，\n'
              '而 Media3 依赖系统 MediaCodec 解码器，冷门编码/容器会播不了。\n'
              'Media3 的价值在系统集成，不是"更好的默认选择"。');

      final k = PlayerKernelFactory.create();
      expect(k, isA<NativeKernel>());
      expect(k.engine, 'native');
      k.dispose();
    });

    test('显式 mpv → NativeKernel', () {
      final k = PlayerKernelFactory.create(KernelType.mpv);
      expect(k, isA<NativeKernel>());
      k.dispose();
    });

    test('显式 media3 → Media3Kernel', () {
      final k = PlayerKernelFactory.create(KernelType.media3);
      expect(k, isA<Media3Kernel>());
      expect(k.engine, 'media3');
      k.dispose();
    });

    test('★ 每次返回新实例（共享实例会互相踩 dispose）', () {
      final a = PlayerKernelFactory.create();
      final b = PlayerKernelFactory.create();
      expect(identical(a, b), isFalse,
          reason: '内核持有原生资源与 StreamController，\n'
              '共享实例会导致 dispose 相互踩踏（一个页面退出把另一个的流关了）');
      a.dispose();
      b.dispose();
    });

    test('两个内核的 viewType 都是 null（都走 Flutter Texture）', () {
      final mpv = PlayerKernelFactory.create(KernelType.mpv);
      final m3 = PlayerKernelFactory.create(KernelType.media3);
      expect(mpv.viewType, isNull,
          reason: 'mpv 用 TextureRegistry.SurfaceProducer + Texture');
      expect(m3.viewType, isNull,
          reason: 'Media3 也走 `setVideoSurface(Flutter Texture)`，\n'
              '不用 PlatformView（避免合成开销与手势穿透问题）。\n'
              '两者一致 ⇒ Dart 侧渲染代码无需分支。');
      mpv.dispose();
      m3.dispose();
    });
  });

  group('★ 能力声明真实性（最容易写错、且错了不报错的地方）', () {
    late NativeKernel mpv;
    late Media3Kernel m3;

    setUp(() {
      mpv = NativeKernel();
      m3 = Media3Kernel();
    });
    tearDown(() {
      mpv.dispose();
      m3.dispose();
    });

    test('mpv 支持全部六项', () {
      for (final f in EngineFeature.values) {
        expect(mpv.supports(f), isTrue, reason: 'mpv 应支持 ${f.name}');
      }
    });

    test('★ Media3 如实声明不支持滤镜/延迟/解码切换', () {
      expect(m3.supports(EngineFeature.videoFilters), isFalse,
          reason: 'Media3 无画面滤镜属性 —— 需自叠 GL 层做像素处理，本内核不做。\n'
              '若这里返回 true，UI 会显示滤镜滑块但拖了没反应。');
      expect(m3.supports(EngineFeature.audioDelay), isFalse,
          reason: 'Media3 无 audio-delay 等价属性（mpv 有）');
      expect(m3.supports(EngineFeature.subtitleDelay), isFalse,
          reason: 'Media3 无 sub-delay 等价属性（mpv 有）');
      expect(m3.supports(EngineFeature.decodeMode), isFalse,
          reason: 'Media3 需重建 RenderersFactory 才能切硬/软解，运行中不可切');
    });

    test('Media3 声明支持外挂字幕与画面比例', () {
      expect(m3.supports(EngineFeature.externalSubtitle), isTrue);
      expect(m3.supports(EngineFeature.aspectMode), isTrue);
    });

    test('★ 能力断言与枚举全集一致（新增能力项时会提醒）', () {
      // 若将来给 EngineFeature 加了第 7 项，这条会失败 ——
      // 迫使实现者想清楚"两个内核各支不支持"，而不是默认 false 蒙混。
      expect(EngineFeature.values.length, 6,
          reason: '新增 EngineFeature 时必须同时更新本测试与'
              '两个内核的 supports()');
    });
  });

  group('★ 不支持的能力被调用时不抛异常（健壮性）', () {
    test('Media3 调 setVideoFilters / 延迟 / 解码模式都 completes', () async {
      final k = Media3Kernel();
      addTearDown(k.dispose);

      await expectLater(
        k.setVideoFilters(brightness: 50, contrast: -20, saturation: 10, hue: 90),
        completes,
        reason: 'UI 已据 supports() 禁用入口，但万一有代码路径直接调用，\n'
            '也不该让播放中断（本项目已有"点了没反应"类的教训）。',
      );
      await expectLater(k.setAudioDelay(const Duration(milliseconds: 300)),
          completes);
      await expectLater(k.setSubtitleDelay(const Duration(milliseconds: -200)),
          completes);
      await expectLater(k.setDecodeMode(DecodeMode.software), completes);
    });
  });

  group('★ 事件 JSON 形状一致（两者共用 Dart 侧解析）', () {
    test('Media3 的 tracks 事件能解析出轨道（字段名与 mpv 一致）', () {
      final k = Media3Kernel();
      addTearDown(k.dispose);

      // 模拟 Kotlin 侧 emitTracks 的输出（字段名刻意与 mpv 对齐）
      const raw = '{"type":"tracks","data":['
          '{"type":"audio","id":1,"ff-index":1,"title":null,'
          '"lang":"chi","codec":"aac","demux-channels":2,'
          '"default":true,"external":false,"forced":false},'
          '{"type":"audio","id":2,"ff-index":2,"title":"导演评论",'
          '"lang":null,"codec":"eac3","demux-channels":6,'
          '"default":false,"external":false,"forced":false},'
          '{"type":"sub","id":1,"ff-index":3,"title":null,'
          '"lang":"chi","codec":"subrip","demux-channels":null,'
          '"default":false,"external":true,"forced":false}]}';

      // 直接驱动解析（走公开的事件入口：靠 Stream 收）
      final got = <KernelTracks>[];
      final sub = k.tracksStream.listen(got.add);
      addTearDown(sub.cancel);

      // Media3Kernel 的事件入口是私有的，这里用"模拟 Kotlin 推送"的方式：
      // 通过 EventChannel 在纯 Dart 测试里不可行，故断言**形状契约**本身：
      // 把同一份 JSON 交给与内核相同的解析规则，验证字段名匹配。
      final parsed = KernelEventParser.parse(raw)!.tracks!;
      expect(parsed.audio.length, 2, reason: '应解析出 2 条音轨');
      expect(parsed.subtitle.length, 1, reason: '应解析出 1 条字幕轨');
      expect(parsed.audio[0].codec, 'aac');
      expect(parsed.audio[0].channels, 2);
      expect(parsed.audio[0].ffIndex, 1);
      expect(parsed.audio[0].isDefault, isTrue);
      expect(parsed.audio[1].title, '导演评论');
      expect(parsed.audio[1].channels, 6);
      expect(parsed.subtitle[0].isExternal, isTrue);
    });

    test('★ 多音轨能被区分（同 title 为 null 时靠 codec/声道）', () {
      const raw = '{"type":"tracks","data":['
          '{"type":"audio","id":1,"ff-index":1,"title":null,'
          '"lang":null,"codec":"aac","demux-channels":2},'
          '{"type":"audio","id":2,"ff-index":2,"title":null,'
          '"lang":null,"codec":"eac3","demux-channels":6}]}';
      final t = KernelEventParser.parse(raw)!.tracks!;
      expect(t.audio.length, 2);
      expect(t.audio[0].displayName, isNot(t.audio[1].displayName),
          reason: '本服务器实测两条音轨 title 都为空 ——\n'
              '若 displayName 相同，用户无法在多音轨里做选择。');
    });

    test('轨道列表为空的 JSON 不崩', () {
      final t = KernelEventParser.parse('{"type":"tracks","data":[]}')!
          .tracks!;
      expect(t.audio, isEmpty);
      expect(t.subtitle, isEmpty);
    });

    test('坏 JSON（缺 data / 类型错）不崩', () {
      expect(
          KernelEventParser.parse('{"type":"tracks"}')!.tracks!.audio, isEmpty);
      expect(
          KernelEventParser.parse('{"type":"tracks","data":"oops"}')!
              .tracks!
              .audio,
          isEmpty);
    });
  });

  group('canHandle · 格式能力判断', () {
    test('mpv 通吃（含冷门格式）', () {
      for (final f in ['a.mkv', 'b.rmvb', 'c.wmv', 'd.mp4', 'e.ts']) {
        expect(PlayerKernelFactory.canHandle(KernelType.mpv, path: f), isTrue,
            reason: 'mpv 应能处理 $f');
      }
    });

    test('★ Media3 对冷门格式返回 false（引导用 mpv）', () {
      for (final f in ['a.rmvb', 'b.wmv', 'c.asf', 'd.vob']) {
        expect(PlayerKernelFactory.canHandle(KernelType.media3, path: f),
            isFalse,
            reason: 'Media3 依赖系统解码器，$f 在多数设备上无解码器');
      }
    });

    test('Media3 对常见格式返回 true', () {
      for (final f in ['a.mp4', 'b.mkv', 'c.webm', 'd.mp3', 'e.m4a']) {
        expect(PlayerKernelFactory.canHandle(KernelType.media3, path: f),
            isTrue,
            reason: 'Media3 应能处理 $f');
      }
    });

    test('大小写不敏感', () {
      expect(PlayerKernelFactory.canHandle(KernelType.media3, path: 'A.RMVB'),
          isFalse);
      expect(PlayerKernelFactory.canHandle(KernelType.media3, path: 'B.MKV'),
          isTrue);
    });

    test('无扩展名时按"可以试试"处理', () {
      expect(PlayerKernelFactory.canHandle(KernelType.media3, path: 'stream'),
          isTrue,
          reason: '无扩展名（如网络流）无法预判，交给运行时');
    });
  });
}
