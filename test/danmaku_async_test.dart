import 'package:cineflow/danmaku/danmaku_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// 异步弹幕轮询状态机的测试。
///
/// ## 这些分支为什么必须测
///
/// 用户规格：`?async=1` → 若返回 `status=pending` + `taskId`，
/// 则每 1.5 秒轮询 `/taskcomment/{taskId}`，总上限 5 分钟。
///
/// 实机验证一轮要几分钟，且"没弹幕"与"生成失败"在服务端**无法区分**
/// （调研明确记录：两者都是 `count:0, comments:[]`）——
/// 这些细节靠人工测试根本覆盖不到，而写错的后果是"弹幕永远出不来"。
void main() {
  group('首次响应判定（三种结果混在同一形状里）', () {
    test('status=pending + taskId → 进入等待', () {
      final d = decideFirstResponse(
        commentCount: 0,
        status: 'pending',
        taskId: 'task-123',
        description: '正在从 B站 抓取',
      );
      expect(d.phase, PollPhase.waiting);
      expect(d.taskId, 'task-123');
      expect(d.description, '正在从 B站 抓取');
    });

    test('无 status → 同步成功（服务端 30 秒内直接给了弹幕）', () {
      final d = decideFirstResponse(commentCount: 500, status: null);
      expect(d.phase, PollPhase.immediate,
          reason: '任务快速完成时响应里没有 status/taskId，必须容忍这条分支');
    });

    test('无 status 且 0 条 → 仍是立即成功（不能报错）', () {
      // 服务端无法区分"本来就没弹幕"和"生成失败"，故按成功处理
      final d = decideFirstResponse(commentCount: 0, status: null);
      expect(d.phase, PollPhase.immediate);
    });

    test('status=completed → 直接可用', () {
      expect(decideFirstResponse(commentCount: 10, status: 'completed').phase,
          PollPhase.ready);
    });

    test('status=failed → 带上失败原因', () {
      final d = decideFirstResponse(
          commentCount: 0, status: 'failed', description: '任务不存在或已过期');
      expect(d.phase, PollPhase.failed);
      expect(d.description, '任务不存在或已过期');
    });

    test('pending 但 taskId 为空 → 当作同步失败而非死等', () {
      final d = decideFirstResponse(commentCount: 0, status: 'pending');
      expect(d.phase, PollPhase.immediate,
          reason: '没有 taskId 就无法轮询，死等只会浪费 5 分钟');
    });

    test('★ 状态字面量没有 done，只有 completed（调研确认）', () {
      // 若实现按 'done' 判断，这条会失败——而真机上表现为"永远在等待"
      expect(
        decideFirstResponse(commentCount: 5, status: 'done').phase,
        PollPhase.immediate,
        reason: 'done 不是合法状态；未知状态应退化为"当作已拿到结果"，'
            '而不是进入等待把用户卡 5 分钟',
      );
    });
  });

  group('轮询响应判定', () {
    test('pending → 继续等待，并带回进度描述', () {
      final d = decidePollResponse(
        status: 'pending',
        taskId: 't1',
        description: '正在抓取 3/8',
        progress: 37,
        elapsed: const Duration(seconds: 10),
      );
      expect(d.phase, PollPhase.waiting);
      expect(d.progress, 37);
      expect(d.description, '正在抓取 3/8');
    });

    test('completed → 可以取弹幕了', () {
      final d = decidePollResponse(
        status: 'completed',
        taskId: 't1',
        elapsed: const Duration(minutes: 1),
      );
      expect(d.phase, PollPhase.ready);
    });

    test('failed → 带失败原因（服务端会放在 description）', () {
      final d = decidePollResponse(
        status: 'failed',
        taskId: 't1',
        description: '所有数据源均失败',
        elapsed: const Duration(seconds: 30),
      );
      expect(d.phase, PollPhase.failed);
      expect(d.description, '所有数据源均失败');
    });

    test('未知状态 → 继续等待（不误判成功、也不立刻失败）', () {
      final d = decidePollResponse(
        status: 'generating',
        taskId: 't1',
        elapsed: const Duration(seconds: 5),
      );
      expect(d.phase, PollPhase.waiting);
      expect(d.description, contains('未知状态'));
    });

    test('status 为 null → 继续等待并提示', () {
      final d = decidePollResponse(
        status: null,
        taskId: 't1',
        elapsed: const Duration(seconds: 5),
      );
      expect(d.phase, PollPhase.waiting);
    });
  });

  group('超时（用户规格：5 分钟上限）', () {
    test('达到 5 分钟即超时', () {
      final d = decidePollResponse(
        status: 'pending',
        taskId: 't1',
        elapsed: const Duration(minutes: 5),
      );
      expect(d.phase, PollPhase.timedOut);
      expect(d.description, contains('5 分钟'));
    });

    test('刚好差一点不算超时', () {
      final d = decidePollResponse(
        status: 'pending',
        taskId: 't1',
        elapsed: const Duration(minutes: 5) - const Duration(seconds: 1),
      );
      expect(d.phase, PollPhase.waiting);
    });

    test('超时优先于服务端状态（即使服务端说 completed）', () {
      // 边界：服务端迟到的 completed 不该让已经超时的流程又活过来
      final d = decidePollResponse(
        status: 'completed',
        taskId: 't1',
        elapsed: const Duration(minutes: 6),
      );
      expect(d.phase, PollPhase.timedOut);
    });

    test('超时上限可配置', () {
      final cfg = PollConfig(timeout: const Duration(seconds: 30));
      expect(
        decidePollResponse(
          status: 'pending',
          taskId: 't',
          elapsed: const Duration(seconds: 31),
          config: cfg,
        ).phase,
        PollPhase.timedOut,
      );
    });
  });

  group('默认时序参数（用户规格）', () {
    test('轮询间隔 1.5 秒', () {
      expect(const PollConfig().interval, const Duration(milliseconds: 1500));
    });

    test('总上限 5 分钟', () {
      expect(const PollConfig().timeout, const Duration(minutes: 5));
    });

    test('5 分钟 / 1.5 秒 ≈ 200 次轮询（用于估算总请求数）', () {
      final n = const PollConfig().timeout.inMilliseconds ~/
          const PollConfig().interval.inMilliseconds;
      expect(n, 200);
    });
  });

  group('终态判定', () {
    test('ready / failed / timedOut 是终态', () {
      expect(const PollDecision(PollPhase.ready).isTerminal, isTrue);
      expect(const PollDecision(PollPhase.failed).isTerminal, isTrue);
      expect(const PollDecision(PollPhase.timedOut).isTerminal, isTrue);
    });

    test('waiting / immediate 不是终态', () {
      expect(const PollDecision(PollPhase.waiting).isTerminal, isFalse);
      expect(const PollDecision(PollPhase.immediate).isTerminal, isFalse);
    });
  });

  group('pending 兜底识别', () {
    test('count=0 且有 taskId → 像 pending', () {
      expect(looksLikePending({'count': 0, 'taskId': 'x'}), isTrue);
    });

    test('count>0 → 不像 pending（真的有弹幕）', () {
      expect(looksLikePending({'count': 5, 'taskId': 'x'}), isFalse);
    });

    test('taskId 为空 → 不像 pending', () {
      expect(looksLikePending({'count': 0, 'taskId': ''}), isFalse);
      expect(looksLikePending({'count': 0}), isFalse);
    });
  });
}
