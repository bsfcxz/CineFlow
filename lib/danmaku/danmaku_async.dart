/// 异步弹幕生成的轮询（**状态机，可单测**）。
///
/// ## 为什么需要异步
///
/// 御坂弹幕服务（misaka_danmu_server）2.7.0+ 在库中没有该集弹幕时，
/// 会现场去抓取并生成。这个过程可能很久——调研显示服务端自身最坏会阻塞
/// 约 90 秒（30s 生成 + 15s 刷新 + 60s 请求合并等待）。
/// 同步等待会让播放器卡住；故官方给了 `?async=1`：
///
///   1. 客户端请求 `.../comment/{episodeId}?async=1`
///   2. 服务端若不能立刻给出，返回 `{"count":0,"comments":[],
///      "status":"pending","taskId":"..."}`
///   3. 客户端轮询 `.../taskcomment/{taskId}`
///   4. 完成后（`status=completed`）**再调一次普通接口**取最终弹幕
///
/// ## 关键事实（调研确认，与直觉不同）
///
/// - **`async=1` 不会立即返回**：它仍会同步等最多 30 秒，
///   只在超时才返回 pending。所以"带 async 就秒回"是错的。
/// - **状态字面量是 `pending` / `completed` / `failed`**。
///   **没有 `done`**——全仓 grep 显示 `"done"` 只出现在无关的 SSE 代码里。
///   按 `done` 判断会永远认为任务没完成，直到 5 分钟超时。
/// - **成功时可能根本没有 taskId**：任务在 30 秒内完成就直接返回弹幕。
///   所以调用方必须容忍"同步成功"这条分支。
///
/// ## 为什么抽成状态机
///
/// 轮询逻辑是"定时 + 条件分支 + 超时"的组合，塞进 widget 后只能靠
/// 真实等待来验证（一轮就是几分钟）。做成纯状态机后，
/// 可以用注入的时钟在毫秒内把 5 分钟的超时路径走完。
library;

/// 轮询阶段。
enum PollPhase {
  /// 同步就拿到了弹幕，无需轮询
  immediate,

  /// 等待服务端生成
  waiting,

  /// 生成完成，需要再取一次弹幕
  ready,

  /// 生成失败
  failed,

  /// 超过总时长上限
  timedOut,
}

/// 一次轮询的决策结果。
class PollDecision {
  const PollDecision(this.phase, {this.taskId, this.description, this.progress});

  final PollPhase phase;

  /// 下一步要查询的 taskId（仅 waiting 时有意义）
  final String? taskId;

  /// 服务端给的描述文本（进度说明或失败原因），**直接展示给用户**——
  /// 用户等 30 秒时看到"正在从 B站 抓取第 3/8 个源"远比一个转圈有用。
  final String? description;

  /// 0–100，仅 waiting 时可能非空（服务端不保证提供）
  final int? progress;

  bool get isTerminal =>
      phase == PollPhase.ready ||
      phase == PollPhase.failed ||
      phase == PollPhase.timedOut;
}

/// 轮询配置。默认值按用户规格：1.5 秒间隔、5 分钟上限。
class PollConfig {
  const PollConfig({
    this.interval = const Duration(milliseconds: 1500),
    this.timeout = const Duration(minutes: 5),
  });

  final Duration interval;
  final Duration timeout;
}

/// 解析 `?async=1` 的首次响应，决定下一步。
///
/// 这是整个流程最容易写错的地方：**三种可能的结果**混在同一个响应形状里。
PollDecision decideFirstResponse({
  required int commentCount,
  String? status,
  String? taskId,
  String? description,
  int? progress,
}) {
  // 服务端明确说在生成中
  if (status == 'pending' && taskId != null && taskId.isNotEmpty) {
    return PollDecision(PollPhase.waiting,
        taskId: taskId, description: description, progress: progress);
  }
  // 已经完成（理论上首次不会，但兼容服务端实现差异）
  if (status == 'completed') {
    return const PollDecision(PollPhase.ready);
  }
  // 明确失败
  if (status == 'failed') {
    return PollDecision(PollPhase.failed,
        description: description ?? '服务端生成弹幕失败');
  }
  // 没有 status：这是"同步成功"分支。
  //
  // ⚠️ 注意 commentCount==0 也走这里：**服务端无法区分**
  //    「本来就是 0 条弹幕」和「生成失败」——调研明确记录了这一点。
  //    所以这里按"成功但没弹幕"处理，不报错。
  return const PollDecision(PollPhase.immediate);
}

/// 解析一次 `taskcomment/{taskId}` 的响应。
///
/// [elapsed] 是**从首次请求算起**的总耗时，用于超时判断
/// （不是"本次轮询耗时"——超时上限针对整个流程）。
PollDecision decidePollResponse({
  required String? status,
  required String? taskId,
  String? description,
  int? progress,
  required Duration elapsed,
  PollConfig config = const PollConfig(),
}) {
  if (elapsed >= config.timeout) {
    return PollDecision(PollPhase.timedOut,
        description: '弹幕生成超过 ${config.timeout.inMinutes} 分钟，已放弃');
  }

  switch (status) {
    case 'completed':
      return const PollDecision(PollPhase.ready);
    case 'failed':
      return PollDecision(PollPhase.failed,
          description: description ?? '服务端生成弹幕失败');
    case 'pending':
      return PollDecision(PollPhase.waiting,
          taskId: taskId, description: description, progress: progress);
    default:
      // 未知状态：不当作成功（可能是服务端升级了字面量）。
      // 继续等而不是报错——等超时至少还能给出"超时"这个明确结论。
      return PollDecision(PollPhase.waiting,
          taskId: taskId,
          description: description ?? '服务端返回未知状态：${status ?? "(空)"}');
  }
}

/// 判断响应体里是否"看起来像 pending"。
///
/// 供客户端在**没解析出 status 字段**时做兜底判断：
/// 有些实现会返回 `status` 之外的名字，或把 taskId 放在别处。
/// 判据：count==0 且存在 taskId。
bool looksLikePending(Map<String, dynamic> map) {
  final count = (map['count'] as num?)?.toInt() ?? 0;
  final taskId = map['taskId'];
  return count == 0 && taskId is String && taskId.isNotEmpty;
}
