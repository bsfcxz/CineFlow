import 'package:cineflow/data/emby_provider.dart';
import 'package:cineflow/data/media_provider.dart' show ProgressEvent;
import 'package:cineflow/data/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 服务端筛选（缺陷 §7.15）的单元测试。
///
/// 为什么必须测「请求参数」而不是「结果」：
/// 原来的实现把类型/年份做成**客户端复筛**——UI 看起来正常（当前页确实被过滤了），
/// 但分页下从未加载的条目永远筛不到。这种缺陷只有断言"真的发出了
/// Genres/Years 参数"才能防回归，静态分析与手工点几个条目都发现不了。
///
/// 实测依据（本机 curl，2026-10）：
/// - `/Genres?ParentId=` → 200 + `{Items:[{Name}]}`（空 Name 需滤掉）
/// - `Genres=动作` 使 TotalRecordCount 2035→823，返回条目确实都含「动作」
/// - `Years=2024` → 67；两者组合 → 19（交集语义）
/// - 年份无分面端点，用 ProductionYear 升/降序 + Limit=1 两次探针取区间
///   （本服务器探到 1931–2026）
void main() {
  /// 捕获最后一次请求的查询参数
  late Map<String, dynamic> lastQuery;

  EmbyProvider buildProvider({required ResponseBody Function(RequestOptions) reply}) {
    final session = const MediaSession(
      serverUrl: 'http://test.local',
      accessToken: 'tok',
      user: MediaUser(id: 'u1', name: 'tester'),
      deviceId: 'dev1',
    );
    final provider = EmbyProvider(session);
    // 用测试拦截器替换网络层：不发真实请求，只记录参数
    provider.dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      lastQuery = Map<String, dynamic>.from(o.queryParameters);
      h.resolve(Response(
        requestOptions: o,
        statusCode: 200,
        data: {'Items': <dynamic>[], 'TotalRecordCount': 0},
        headers: Headers(),
      ));
    }));
    return provider;
  }

  setUp(() => lastQuery = {});

  group('getItems 的服务端筛选参数（§7.15 回归线）', () {
    test('传入 genres/years 时确实写进查询参数', () async {
      final api = buildProvider(reply: (_) => ResponseBody.fromString('{}', 200));
      await api.getItems(genres: '动作', years: '2024');
      expect(lastQuery['Genres'], '动作',
          reason: '类型必须交给服务端，客户端复筛在分页下不完整');
      expect(lastQuery['Years'], '2024');
    });

    test('未传筛选时不应出现空参数（避免服务端收到 Genres= 这种值）', () async {
      final api = buildProvider(reply: (_) => ResponseBody.fromString('{}', 200));
      await api.getItems();
      expect(lastQuery.containsKey('Genres'), isFalse);
      expect(lastQuery.containsKey('Years'), isFalse);
    });

    test('空字符串同样视为未筛选', () async {
      final api = buildProvider(reply: (_) => ResponseBody.fromString('{}', 200));
      await api.getItems(genres: '', years: '');
      expect(lastQuery.containsKey('Genres'), isFalse);
      expect(lastQuery.containsKey('Years'), isFalse);
    });

    test('筛选与排序/未观看可共存（互不覆盖）', () async {
      final api = buildProvider(reply: (_) => ResponseBody.fromString('{}', 200));
      await api.getItems(
        genres: '科幻',
        years: '2023',
        unplayedOnly: true,
        sortBy: 'DateCreated,SortName',
        sortOrder: 'Descending,Ascending',
      );
      expect(lastQuery['Genres'], '科幻');
      expect(lastQuery['Years'], '2023');
      expect(lastQuery['Filters'], 'IsUnplayed');
      expect(lastQuery['SortBy'], 'DateCreated,SortName');
      expect(lastQuery['SortOrder'], 'Descending,Ascending');
    });

    test('Filters 与 unplayedOnly 不会同时出现（§7.6 回归线）', () async {
      final api = buildProvider(reply: (_) => ResponseBody.fromString('{}', 200));
      await api.getItems(unplayedOnly: true, filters: 'IsFavorite');
      // 只允许一个 Filters 键，且优先 unplayedOnly
      expect(lastQuery['Filters'], 'IsUnplayed');
    });

    test('分页参数照常传递（筛选状态下续拉不能丢条件）', () async {
      final api = buildProvider(reply: (_) => ResponseBody.fromString('{}', 200));
      await api.getItems(genres: '动画', startIndex: 40, limit: 40);
      expect(lastQuery['StartIndex'], 40);
      expect(lastQuery['Limit'], 40);
      expect(lastQuery['Genres'], '动画');
    });
  });

  group('条目进度持久化（POST …/UserData，实测只支持 POST）', () {
    /// 捕获最后一次请求的路径与请求体
    late String lastPath;
    late Map<String, dynamic> lastBody;
    late String lastMethod;

    EmbyProvider providerWithRecorder() {
      final session = const MediaSession(
        serverUrl: 'http://test.local',
        accessToken: 'tok',
        user: MediaUser(id: 'u1', name: 'tester'),
        deviceId: 'dev1',
      );
      final p = EmbyProvider(session);
      p.dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        lastPath = o.path;
        lastMethod = o.method;
        lastBody = Map<String, dynamic>.from(o.data as Map? ?? {});
        h.resolve(Response(
          requestOptions: o,
          statusCode: 204,
          data: null,
          headers: Headers(),
        ));
      }));
      return p;
    }

    setUp(() {
      lastPath = '';
      lastMethod = '';
      lastBody = {};
    });

    /// reportItemProgress 是 fire-and-forget（内部 unawaited），
    /// 单靠 `Future.delayed(Duration.zero)` 等不到 dio 的拦截器执行——
    /// 需要让出足够的事件循环轮次。多 pump 几次比调大延时更稳。
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('打到 /Users/{uid}/Items/{id}/UserData 且带 PositionTicks', () async {
      final api = providerWithRecorder();
      api.reportItemProgress(itemId: 'it1', positionTicks: 1234567890);
      await settle();
      expect(lastMethod, 'POST', reason: '实测该路径 GET 返回 404，只有 POST 可用');
      expect(lastPath, '/Users/u1/Items/it1/UserData');
      expect(lastBody['PlaybackPositionTicks'], 1234567890);
    });

    test('未指定 played 时不发送该字段（避免顺带覆盖已看状态）', () async {
      final api = providerWithRecorder();
      api.reportItemProgress(itemId: 'it1', positionTicks: 100);
      await settle();
      expect(lastBody.containsKey('Played'), isFalse);
    });

    test('看完时发送 played=true 且进度归零', () async {
      final api = providerWithRecorder();
      api.reportItemProgress(itemId: 'it1', positionTicks: 0, played: true);
      await settle();
      expect(lastBody['Played'], isTrue);
      expect(lastBody['PlaybackPositionTicks'], 0);
    });

    test('负进度被夹到 0（服务端不接受负数 ticks）', () async {
      final api = providerWithRecorder();
      api.reportItemProgress(itemId: 'it1', positionTicks: -5);
      await settle();
      expect(lastBody['PlaybackPositionTicks'], 0);
    });
  });

  group('播放进度上报的 EventName（官方文档要求）', () {
    /// 捕获最后一次上报的 body 与路径
    late Map<String, dynamic> body;
    late String path;

    EmbyProvider recorder() {
      final session = const MediaSession(
        serverUrl: 'http://test.local',
        accessToken: 'tok',
        user: MediaUser(id: 'u1', name: 'tester'),
        deviceId: 'dev1',
      );
      final p = EmbyProvider(session);
      p.dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        path = o.path;
        body = Map<String, dynamic>.from(o.data as Map? ?? {});
        h.resolve(Response(
          requestOptions: o,
          statusCode: 204,
          data: null,
          headers: Headers(),
        ));
      }));
      return p;
    }

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUp(() {
      body = {};
      path = '';
    });

    test('定时上报带 TimeUpdate', () async {
      recorder().reportPlaybackProgress(
        itemId: 'it1',
        playSessionId: 'ps1',
        mediaSourceId: 'ms1',
        positionTicks: 100,
        paused: false,
        eventName: ProgressEvent.timeUpdate,
      );
      await settle();
      expect(path, '/Sessions/Playing/Progress');
      expect(body['EventName'], 'TimeUpdate');
    });

    test('暂停上报带 Pause', () async {
      recorder().reportPlaybackProgress(
        itemId: 'it1',
        playSessionId: 'ps1',
        mediaSourceId: 'ms1',
        positionTicks: 100,
        paused: true,
        eventName: ProgressEvent.pause,
      );
      await settle();
      expect(body['EventName'], 'Pause');
      expect(body['IsPaused'], isTrue);
    });

    test('恢复播放带 Unpause', () async {
      recorder().reportPlaybackProgress(
        itemId: 'it1',
        playSessionId: 'ps1',
        mediaSourceId: 'ms1',
        positionTicks: 100,
        paused: false,
        eventName: ProgressEvent.unpause,
      );
      await settle();
      expect(body['EventName'], 'Unpause');
      expect(body['IsPaused'], isFalse);
    });

    test('变速带 PlaybackRateChange 且速率正确', () async {
      recorder().reportPlaybackProgress(
        itemId: 'it1',
        playSessionId: 'ps1',
        mediaSourceId: 'ms1',
        positionTicks: 100,
        paused: false,
        rate: 1.5,
        eventName: ProgressEvent.playbackRateChange,
      );
      await settle();
      expect(body['EventName'], 'PlaybackRateChange');
      expect(body['PlaybackRate'], 1.5);
    });

    test('不传 eventName 时字段不出现（Start/Stopped 不需要它）', () async {
      recorder().reportPlaybackStop(
        itemId: 'it1',
        playSessionId: 'ps1',
        mediaSourceId: 'ms1',
        positionTicks: 100,
      );
      await settle();
      expect(path, '/Sessions/Playing/Stopped');
      expect(body.containsKey('EventName'), isFalse,
          reason: 'Start/Stopped 带 EventName 属于多余字段，保持与官方模型一致');
    });

    test('常量值大小写正确（帕斯卡命名，拼错服务端会静默忽略）', () {
      // 这些值来自官方文档，大小写敏感；用常量锁定，避免手写成 'timeupdate'
      const expected = {
        ProgressEvent.timeUpdate: 'TimeUpdate',
        ProgressEvent.pause: 'Pause',
        ProgressEvent.unpause: 'Unpause',
        ProgressEvent.volumeChange: 'VolumeChange',
        ProgressEvent.repeatModeChange: 'RepeatModeChange',
        ProgressEvent.audioTrackChange: 'AudioTrackChange',
        ProgressEvent.subtitleTrackChange: 'SubtitleTrackChange',
        ProgressEvent.playlistItemMove: 'PlaylistItemMove',
        ProgressEvent.playlistItemRemove: 'PlaylistItemRemove',
        ProgressEvent.playlistItemAdd: 'PlaylistItemAdd',
        ProgressEvent.qualityChange: 'QualityChange',
        ProgressEvent.subtitleOffsetChange: 'SubtitleOffsetChange',
        ProgressEvent.playbackRateChange: 'PlaybackRateChange',
      };
      expect(expected.length, 13, reason: '官方文档共 13 个取值，少一个说明漏定义');
      for (final e in expected.entries) {
        expect(e.key, e.value);
        expect(e.key[0], e.key[0].toUpperCase(),
            reason: '${e.key} 应以大写字母开头（帕斯卡命名）');
      }
    });
  });
}
