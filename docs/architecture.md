# 架构与接口契约 · CineFlow

> 接口变更时**先改本文件，再改代码**。文档与代码不一致视为未完成（AGENTS §7-8）。
> 本文件描述的是**当前代码的真实形态**（纯 Dart/Flutter，无 Go 层，见 [ADR 0002](decisions/0002-pure-dart-mvp.md)）。
> 变更历史见文末。

## 1. 分层

```text
Flutter UI (pages/ · player/ · widgets/)
        │  watch / read
        ▼
riverpod providers (state/)          ── SessionNotifier / homeProvider / douban providers
        │
        ▼
MediaProvider 抽象 (data/media_provider.dart)   ← UI 唯一依赖的媒体源契约
        │
        ├─► EmbyProvider (data/emby_provider.dart) ──► Emby Server REST API
        └─► (未来 Pan115Provider 等，UI 无需改动)
        │
        ├─► 豆瓣客户端 (data/douban/) ──────────────► m.douban.com rexxar v2
        ▼
SessionStore (flutter_secure_storage)
        ▲
media_kit (libmpv)  ── 本地播放，与 UI 解耦
```

| 约束 | 意思 |
|---|---|
| UI 不直连 Emby | UI 只依赖 `MediaProvider` 抽象；**例外见 §5 遗留缺口** |
| 无跨语言层 | 本仓库无 Go/FFI/Protobuf；不存在桥接边界（ADR 0002） |
| 防御式解析 | 服务器字段缺失是常态，模型层全部手写 `fromJson` 且不得非空断言 |
| 弹幕独立于媒体源 | 弹幕匹配走统一媒体信息（标题 + 集数 + 尺寸指纹），不依赖 provider 内部字段（阶段五） |

## 2. `MediaProvider` 契约

权威定义在 `lib/data/media_provider.dart`（`abstract interface class`）。UI 层只依赖它，
当前唯一实现是 `EmbyProvider`。

```dart
abstract interface class MediaProvider {
  // 浏览
  Future<List<EmbyView>> getViews();
  Future<List<EmbyItem>> getLatest({int limit});
  Future<List<EmbyItem>> getResume({int limit});
  Future<ItemPage> getItems({
    String? parentId, String includeTypes, String? searchTerm,
    String sortBy, String sortOrder, bool recursive,
    bool unplayedOnly, String? filters, int startIndex, int limit,
  });
  Future<List<EmbyItem>> search(String keyword, {int limit});

  // 详情
  Future<EmbyItemDetail> getItemDetail(String itemId);
  Future<List<EmbyItem>> getSeasons(String seriesId);
  Future<List<EmbyItem>> getEpisodes(String seriesId, String seasonId);
  Future<List<EmbyItem>> getSimilar(String itemId);
  Future<List<EmbyChapter>> getChapters(String itemId);

  // 图片直链
  String imageUrl(String itemId, {String type, int position, String? tag, int maxWidth});

  // 交互
  Future<bool> toggleFavorite(String itemId, {required bool favorite});
  Future<bool> togglePlayed(String itemId, {required bool played});

  // 播放
  Future<PlaybackLaunch> resolvePlayback(String itemId, {String? mediaSourceId});
  void reportPlaybackStart({...});
  void reportPlaybackProgress({...});
  void reportPlaybackStop({...});
}
```

**新增媒体能力时先想清楚要不要进这个接口**：凡未来其它媒体源也需要的能力
（媒体库 / 详情 / 播放 / 进度），必须先在 `media_provider.dart` 定义，再在 `EmbyProvider` 实现。

`PlaybackLaunch` 是一次可执行的播放会话：`url`（含 `api_key` 的直连流）、
`itemId`、`mediaSourceId`、`playSessionId`，以及 `videoLabel` / `audioLabel` / `container` 用于展示。

### 2.1 模型层命名说明

模型类名为 `EmbyView` / `EmbyItem` / `EmbyItemDetail`，是历史命名（阶段二直接对接 Emby 时定下）。
它们**承载的是统一模型职责**，字段已按 UI 需要裁剪。改名为 `MediaItem` 等是独立的重构任务，
当前不做（避免制造大范围无关 diff）。**新增代码请沿用现有命名**，不要混用两套。

## 3. 状态管理（riverpod）

| Provider | 职责 |
|---|---|
| `SessionNotifier`（`AsyncNotifier`） | 启动恢复持久化会话；未登录 → 登录页；登录成功写入已存服务器列表 |
| `embyApiProvider` | 由会话派生 `EmbyProvider` 实例（会话变了就重建） |
| `homeProvider` | 首页聚合数据（见 §4） |
| 豆瓣 providers（`douban_providers.dart`） | 榜单 / 热门搜索 / 详情 + SQLite（drift）缓存 |

## 4. 首页聚合：单区块失败不拖垮整页

`HomeRepository.fetch` 依次拉取 Latest / Resume / Collections（BoxSet），
**单个区块异常吞掉并降级为空列表**，其余照常渲染。轮播（featured）不单独发请求，
它由 Latest 中有背景图的条目派生。

若**全部区块都为空且至少发生过一个错误**，把首个错误放进 `HomeData.fatalError`，
由 UI 显示错误页 + 重试。
（注意判定条件是"全空 + 有错误"，不是"有错误"——服务器真的没有内容时不应报错。）

原则：**「加载失败」与「真的没有内容」必须可区分**。媒体库同理——
`_reload` 失败时保留 `_error`，空列表时优先渲染 `CfErrorView` 而不是"该库暂无内容"。

## 5. 遗留缺口（与契约不一致之处，勿当成已完成）

| 缺口 | 位置 | 影响 |
|---|---|---|
| UI 层 8 个文件直接 import `emby_provider.dart`（主要为 `EmbyException`） | detail/player/library/login/profile/search/home/providers | 违反"UI 只依赖抽象"；新代码不得加重 |
| 无 401 统一处理 | `emby_provider.dart` 拦截器 | token 失效只能看错误页，无自愈 |

完整台账见 `AGENTS.md` §7。

## 6. 数据与凭据

| 数据 | 存放 |
|---|---|
| AccessToken / 服务器凭据 / 设备 ID | `flutter_secure_storage`（Android Keystore），**不入库、不落项目目录** |
| 搜索历史 / 播放偏好（`cf_pref_*`） | `SessionStore`（同上） |
| 豆瓣榜单与详情 | **SQLite（drift）**：`douban_caches` 表，`expires_at` 固化 TTL，过期判断在 SQL 里 |
| 本机播放历史 | **SQLite（drift）**：`play_histories` 表，按条目 upsert（为离线"继续观看"准备） |

设备 ID 首启生成 UUID v4 并持久化——Emby 用它识别设备与会话。

## 7. 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始版本：分层与约束、`MediaProvider` 契约（含 `Capabilities` 能力位）、桥接契约、115 预留层范围与阶段八接入路径、数据层表设计 |
| v1.1 | 2026-10-04 | **按实际代码重写**：删除 Go 服务层/桥接 proto/115 预留/数据表设计四节（本仓库无 Go 层，见 ADR 0002）；`MediaProvider` 契约改为引用 `lib/data/media_provider.dart` 的真实签名；新增 §2.1 模型命名说明、§3 状态管理表、§4 首页降级原则、§5 遗留缺口 |
