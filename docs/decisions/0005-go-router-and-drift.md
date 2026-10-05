# ADR 0005 · 路由迁移到 go_router；引入 drift 本地库

- 状态：**已采纳**（2026-10-04）
- 决策者：项目所有者（要求技术栈含 `go_router` 与 `SQLite (drift)`）
- 影响范围：新增 `lib/core/router.dart`、`lib/player/player_routes.dart`、
  `lib/data/db/`；改动 8 个页面的跳转；`douban_client.dart` 的缓存契约

本 ADR 记录两件相关但独立的事：**路由**与**本地库**。
合并成一篇是因为它们同属"按技术栈补齐被 ADR 0002 放弃的选型"，
且都在同一次变更里落地。

---

## 一、go_router

### 背景

原先全用 `Navigator.push(MaterialPageRoute(...))`，ADR 0002 时代够用。
迁移动机有两个，**都不是"为了用而用"**：

1. **可由 id 直达的 URL 语义**：详情页要能从任意位置打开
   （搜索结果、豆瓣榜单、未来的通知/深链）。`Navigator.push` 必须持有
   `BuildContext` 并在页面内构造 widget，而 `/detail/:id` 可以从任何地方跳。
2. **会话门控集中化**：原 `_SessionGate` 是个 `session.when`，
   迁到 `redirect` 后登录/未登录的跳转规则集中在一处可断言。

### 决策

- 路由表见 `lib/core/router.dart`，路径常量集中在 `Routes`
- **播放器需要 `extra` + 深链回退**：`EmbyItem`、整季分集、多版本选择
  无法塞进 URL；`state.extra` 是内存对象，**进程重启/深链进入会丢**。
  故 `/play/:id` 在 extra 缺失时**按 id 拉详情再播**（见 `player_routes.dart`）。
  没有这条回退，`/play/xxx` 这种链接进来只会白屏。
- **弹窗内的 `Navigator.pop` 不动**：`showDialog`/`showModalBottomSheet`
  走根 Navigator，与路由表无关；改成 go_router 反而会断。
- **会话门控抽成纯函数** `resolveRedirect(session:, location:)`。

### 为什么门控要抽成纯函数（测试教训）

第一版测试用 `pumpWidget(MaterialApp.router(...))` 跑真实页面，**失败**：
页面需要 `ProviderScope` 并发网络请求——测的其实是"整个 app 能不能启动"，
与门控逻辑无关，且会因无关原因变红。

抽成纯函数后可覆盖全部分支（含 `AsyncLoading` → splash：
冷启动时会话未恢复完，若不特判会**闪一下登录页**），毫秒级、零网络依赖。

### 为什么 router 用 Provider 承载

GoRouter 的导航栈挂在实例上。若 `watch(sessionProvider)` 后重建，
会话一变就清空用户当前页面栈（表现为"登录成功后回到首页而非原目标页"）。
故：**实例只建一次**，会话变化用 `refreshListenable` 通知重跑 `redirect`。

---

## 二、drift（SQLite）

### 背景

引入前只有两种本地存储：`flutter_secure_storage`（会话，需加密）
与文件缓存。文件缓存留在**开放缺陷 §7.4**。

### 决策

引入 drift，建两张表（`lib/data/db/app_database.dart`）：

| 表 | 用途 |
|---|---|
| `douban_caches` | 豆瓣接口缓存，`expires_at` 固化 TTL + `idx_douban_expires` 索引 |
| `play_histories` | 本机播放历史（按 itemId upsert），为离线"继续观看"准备 |

### 修复 §7.4：TTL 移到**写入时**（关键改动）

旧契约 `get(key, ttl:)` + `put(key, value)` 有**结构性漏洞**：
TTL 只在读的时候传，实现方**可以完全忽略那个参数**，且编译期与静态分析
都发现不了——实测正是如此（`MemoryDoubanCache.get` 就是 `return _store[key]`）。

新契约把过期时刻在写入时固化：
- `put(key, value, {required Duration ttl})` —— 不给 ttl 编译不过
- `get(key)` —— **没有可忽略的参数**

于是"忘记过期"从"实现方自觉"变成"类型系统强制"。
旧 `FileDoubanCache` 已删除（写好却零引用），由 `DriftDoubanCache` 取代。

### 依赖钉版的坑（真机实测）

`sqlite3` **必须钉在 2.x**，drift 家族钉在 **2.31.x**：

- sqlite3 3.x 改用 Dart **native assets** 加载原生库，未启用时运行期抛
  `Couldn't resolve native function 'sqlite3_temp_directory' ... No available native assets`
- 且 `sqlite3_flutter_libs` 3.x 配套版本标 `+eol`（停止维护）
- 实测 `drift_dev 2.31.0` 是最后一个仍依赖 sqlite3 2.x 的版本

同时 `drift_flutter` → `path_provider_foundation` → `objective_c`
**硬要求** `flutter config --enable-native-assets`，故该开关必须开启。

> ⚠️ 另一个坑：**hot restart 不重新注册新插件**。
> 首次接入 sqlite3 时报 `MissingPluginException: sqlite3_flutter_libs`，
> 必须**完整重建安装**（`flutter run` 全量）而非 hot restart。

### 连接与降级

- 生产：`drift_flutter` 的 `driftDatabase()`，文件在 `app_flutter/`（**非 cache**：
  播放历史是用户数据，被系统当缓存清掉就丢了）
- 测试：`NativeDatabase.memory()`（每个测试独立、不落盘）
- **打开失败不阻塞启动**：只记日志，缓存与历史不可用但应用照常能浏览播放

## 替代方案（及未选原因）

| 方案 | 为什么没选 |
|---|---|
| 保持 Navigator + 文件缓存 | 用户明确要求技术栈含 go_router / drift |
| 路由只迁页面、播放器仍用 Navigator | 播放器是"可由 URL 打开"的主要诉求点，漏它等于没迁 |
| drift 用最新 2.35 + sqlite3 3.7 | 真机实测符号解析失败；3.7 需要 native assets 且配套库已 eol |
| 把 TTL 继续放在 get 上（只修实现体） | 只修实现体不改契约，下一个人仍可写出忽略 ttl 的实现 |

## 回退条件

- 路由：若 go_router 在某平台的返回手势/深链行为无法接受，
  可退回 Navigator（路由表是薄层，页面本身不依赖 go_router 的 API）
- drift：若 SQLite 在某 ABI 上不可用，可退回内存缓存 +
  `flutter_secure_storage`（会重新丢失 §7.4 的持久化收益）

回退时更新：本 ADR 标"被取代"、`AGENTS.md` §1 技术栈表、
`docs/architecture.md` §存储。

## 参考

- go_router 官方文档：<https://pub.dev/packages/go_router>
- drift 官方文档：<https://drift.simonbinder.eu/>
- drift 多数据库警告：<https://drift.simonbinder.eu/faq/#using-the-database>

## 变更日志

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-04 | 初始：路由迁移 + drift 接入 + §7.4 修复；记录 sqlite3 钉版与 native assets 坑 |
