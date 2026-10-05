# ADR 0002：阶段 A —— 纯 Dart MVP 取代 Go 内嵌服务层

- 状态：已接受（2026-10-04）
- 决策者：Captain + Architect
- 影响范围：`lib/data/`、`lib/state/`、`pubspec.yaml`、构建脚本、`docs/`；**不涉及任何 Go 代码**
- 取代：[ADR 0001](0001-flutter-go-libmpv-stack.md)

## 背景与问题

ADR 0001（源自计划书 `cineflow.html`）规划了「Flutter + Go 内嵌服务层（Synurang/FFI）+ libmpv」
的跨平台架构，并把 Emby 协议、弹幕聚合、115 接入都放在 Go 侧。

实际开发中该路线未落地，原因是多方面的：

1. **工具链门槛**：需要同时维护 Go / protoc / gomobile / zig 与 Flutter 两套工具链，
   移动端还要处理 `gomobile bind` 产物与 FFI 加载；本机实测这些工具链均未安装。
2. **收益不成立**：Go 层规划的收益是"协议聚合与重试更省事"，但阶段一/二/三的 Emby 交互
   是**薄 HTTP 转发 + 防御式解析**，Dart 的 dio + 手写 fromJson 已完全够用，
   引入 FFI 边界反而增加调试成本（跨语言错误映射、isolate 阻塞、产物打包）。
3. **迭代速度**：纯 Dart 改一行即热重载；跨 FFI 改动要重编原生库并重装应用。

代价是承认：ADR 0001 里"纯 Dart 要重复造轮子"的判断，在**当前范围（Emby 单源、Android 单端）**
下并不成立。轮子并没有那么多。

## 决策

1. **本仓库为纯 Dart/Flutter 实现，不含任何 Go 代码**（`go.mod` / `*.proto` / `*.go` 均为 0 个）。
   除非用户明确要求，**不引入 Go 桥接**。
2. **保留 `MediaProvider` 抽象层**（`lib/data/media_provider.dart`）——ADR 0001 最有价值的部分。
   UI 只依赖该接口，当前实现 `EmbyProvider`；未来 115 或其它媒体源只新增实现，UI 零改动。
3. **路由用 Navigator，不用 go_router**：当前 8 个页面 + 全屏推入的导航足够简单，
   先少一个依赖；深度链接需求出现时再迁移（成本可控）。
4. **持久化用 `flutter_secure_storage`，不引 drift/SQLite**：当前需要持久化的只有
   会话凭据、服务器列表、搜索历史与播放偏好，键值对足够；列表缓存尚未成为需求。
5. **播放内核仍为 media_kit（libmpv）**——ADR 0001 的这条决策被证明正确并保留，
   理由是 Emby 库里 MKV/HEVC/DV/PGS 常见，ExoPlayer 格式面不够。
6. **当前只做 Android 手机端**：iOS / 桌面 / 平板 / TV 明确搁置（用户决策），
   但代码结构不为单端做死（页面不写死宽度、播放器能力集中在 `player/`）。

## 替代方案（及未选原因）

| 方案 | 未选原因 |
|---|---|
| 继续推进 Go 内嵌服务层 | 工具链未装、移动端 FFI 产物链路未验证；阶段收益 < 成本 |
| Go 层降级为 CLI 调试工具 | 没有需要 CLI 才能做的调试场景，属提前建设 |
| 引入 go_router | 8 页导航用 Navigator 已足够；多一个依赖与迁移成本 |
| 引入 drift/SQLite | 当前持久化需求是键值对；引入 ORM 与迁移机制是过度设计 |
| 引入代码生成（freezed/json_serializable） | Emby 字段缺失是常态，手写防御式 `fromJson` 比生成代码更好控制兜底逻辑 |

## 影响范围

- **不需要**：`go/`、`bridge/`、`scripts/gen_bridge.sh`、`scripts/smoke_bridge.sh`、
  `go vet` / `go test` 相关门禁——这些在 ADR 0001 下才有意义，本仓库不建。
- 需要：`docs/architecture.md` 描述真实分层；`AGENTS.md` §1 说明与计划书的关系；
  质量门禁只保留 Flutter 侧 + 门禁脚本。
- **不破坏 `MediaProvider` 抽象层**：本次决策强化而非削弱它——正因为不再有 Go 层，
  `MediaProvider` 成为唯一的跨源边界，更需守住。
- 遗留风险：`lib/` 下 8 个文件直接 import `emby_provider.dart`（主要为 `EmbyException`），
  违反"UI 只依赖抽象"的约定，见 `AGENTS.md` §7.13。这是抽象层唯一的现实缺口。

## 回退条件

若将来出现以下任一情况，需重新评审本 ADR：

- 需要接入多个媒体源且它们的鉴权/风控逻辑复杂到 Dart 难以维护（如 115 的 Cookie 刷新与 QPS 控制）；
- 出现必须用原生库才能完成的能力（如自研解码、系统级投屏协议栈）；
- 弹幕聚合需要高频并发抓取与复杂重试策略，Dart 侧实现开始明显笨重。

回退时：新建 ADR 取代本 ADR，并同步 `docs/architecture.md` 与 `AGENTS.md` §1 的路线图表。
**不得直接修改本 ADR 的结论**（历史只增不改）。

## 参考

- `docs/DEVELOPMENT.md` §1.2 的分层图与选型理由（本决策的落地说明）
- `lib/data/media_provider.dart` 的接口注释（抽象层契约）
- 播放内核依赖：`media-kit/media-kit`（libmpv 封装）

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本：记录放弃 Go 内嵌服务层的理由、保留项、替代方案与回退条件 |
