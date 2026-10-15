# 第三方 API 接入作业规则

> **本文档从 [`AGENTS.md`](../AGENTS.md) §6.10 外移而来。**
>
> ## 为什么外移（真实原因）
> `AGENTS.md` 有 **65536 字节**的工作区指令预算 —— 加上本节后实测
> **70625 > 65536**，被系统**自动截断**到 65226 字节，
> 后果是 **§7 / §8 / §9 / §10 中间整段消失**（而文件末尾仍是 §12
> ⇒ 光看末尾**发现不了**）。
>
> ⇒ 与 §4 目录地图、§8.4 验证纪律**同一做法**：详细内容外移，AGENTS 只留摘要。
>
> ⚠️ **改本文件不受预算限制**，但仍要保持"每条规矩都有真实事故支撑"。

---

## 用户原话（2026-10-14）

> 你接入他的可用的 api，然后自己测试一下，跑通，你还得保证其他人安装后也能有用。
> 以后你做一个工作让你借助他的 api，**你必须比我们更加的了解**，
> 接入 api 后**跑通它的所有可实现的功能后**，再给我汇报。

本节是这句的**操作化** —— 拆成可执行、可验收的步骤。
下面每条都来自**真实踩坑**（不是"最佳实践"空话）。

---

## ① 先拿机器可读的契约，不要照网页文档写

| 优先级 | 来源 | 例子 |
|---|---|---|
| 1 | **官方 OpenAPI / JSON Schema** | `GET /openapi.json` |
| 2 | **类型化契约源码**（ts-rest / zod / protobuf）| `trakt/trakt-api` 的 `projects/api/src/contracts/` |
| 3 | **官方多语言 SDK** | Emby 的 `MediaBrowser/Emby.ApiClients` |
| 4 | 网页文档 | ⚠️ **最不可靠**（可能是客户端渲染 ⇒ 抓不到内容）|

**实测教训**：`developer.trakt.tv` 的 reference 页是**客户端渲染**
（`web_fetch` 只拿到导航壳）⇒ 差点靠猜。改从官方仓库的
`contracts/*/index.ts`（ts-rest + zod）取，**字段级精确**。

**连通性差时的取法**（GitHub API 有 60 次/小时限流，实测撞 403；
git clone 直连可能 `Recv failure: Connection was reset`）：
```bash
# 镜像（实测 ghproxy.net 可用）
git clone --depth 1 --filter=blob:none --sparse \
  https://ghproxy.net/https://github.com/<owner>/<repo>.git
git sparse-checkout set <只要的目录>
```

---

## ② 契约 ≠ 现实 —— 每个要用的端点必须实测

实测抓到的三类"契约与现实不符"：

| 现象 | 实例 |
|---|---|
| 契约里**有**，服务端**已移除** | `/shows/streaming/{period}` → `404 {"error":"endpoint removed"}` |
| `summary` 同名但**语义不同** | `"Get hot shows"` 既是全站榜也是剧级（靠 `pathPrefix` 区分）|
| 端点合法但**返回 204** | `/shows/{id}/next_episode` 对已完结剧 → `204` 空 body |

**判据要强于"状态码 200"** —— 必须看**响应内容**：
```
✅ 真榜单：200 + list，每项含 show/movie（或有 title）
⚠️ 单对象：200 + dict 含 title ⇒ 这不是榜单（可能是剧级端点）
❌ 名不副实：200 但内容是"标题恰好含关键词的剧"（实测 /shows/hot → "ドラHOT+"）
```

---

## ③ 实现**所有**可实现的，并给出**实测矩阵**

汇报必须附一张表，**每个端点一行**：
`分组 | 方法 | 路径 | 状态码 | 耗时 | 响应形状 | 结论`

**不允许**只写"已接入 X" —— 那是**没有信息量的汇报**。
用户要的"**比我们更了解**"就体现在这张表上。

**区分四种"不是失败"**（否则会把正常当异常）：

| 状态 | 含义 | 处理 |
|---|---|---|
| `200` + 空数组 | 合法但无数据 | ✅ 正常 |
| `204` | 明确"无此资源" | ✅ 正常（**不要当失败**）|
| `401/403` | 需要 OAuth | 🔒 记入"需鉴权"，不是 bug |
| `404 endpoint removed` | 上游已弃用 | ❌ **从实现删掉**，注释写明 |

---

## ④ 接线完整性检查（`analyze` 抓不到死代码）

**真实事故**：我实现了 `addEpisodesToHistory` / `getWatchedShows` / `getPlayback`，
但**调用点全为 0** ⇒ 用户开开关后**什么也没发生**，而
`flutter analyze` **0 error / 0 warning**、测试**全绿**。

⇒ **收工前必须跑**：
```python
# 每个"新能力"都要有调用点，否则就是死代码
for api in ('addEpisodesToHistory', 'getWatchedShows', 'getPlayback'):
    hits = grep(api)
    call = [h for h in hits if 'Future<' not in h]   # 排除定义处
    assert call, f'{api} 定义了但没人调用 ⇒ 功能静默失效'
```
**同时检查"开关被读"**（不只是被写）：
```python
for key in ('kTraktTrackKey', 'kTraktSyncKey', 'kTraktResumeKey'):
    assert has_read(key), f'{key} 只被写、无人读 ⇒ 开关是死的'
```

---

## ⑤ 接 UI 前先读该文件既有模式

**真实事故 1**：我调 `await _toast(...)`，但 `detail_page.dart` **没有** `_toast`
（它一直用 `ScaffoldMessenger.of(context).showSnackBar`）⇒ **8 个编译错**。
⇒ 先 `grep` 目标文件里的同类调用，**复用它的模式**，不新造第二套。

**真实事故 2**：大文件里用正则匹配 `void initState()` 命中了**别的类**
（`_BrowseInDetailState` 而非 `_DetailPageState`）⇒ 4 个编译错。
⇒ **改 >1000 行的文件前，先列出所有 `class` 与方法的行号**，按**行号**定位。

---

## ⑥ 响应形状要**全测**，不能只测一种

**真实事故**：Trakt 榜单有**三种形状**
```
/shows/trending  → [{watchers, show:{...}}]   ← 外层包裹
/shows/popular   → [{ids, year, title}]        ← 裸对象
/media/trending  → [{watchers, show:{...}}]
```
只按一种解析 ⇒ 另一种**静默返回空列表**（用户看到空榜单，**日志无错误**）。

⇒ 规矩：**fixture 必须来自真实响应**（不是按文档编的），每种形状各一个用例。

---

## ⑦ 断言前先想清 API 语义（我为此错了两次）

**真实事故**：验证"UTC → 本地时区"时我写
```dart
expect(local.difference(utc), isNot(Duration.zero));     // ❌ 恒为 0
expect(local.difference(utc), Duration(hours: offsetH)); // ❌ 还是 0
```
`DateTime.difference` 比的是**时刻（instant）**，而 `toLocal()`
**只改表示、不改时刻** ⇒ `difference` **恒为 0**，与时区无关。

⇒ 正确判据（三条，全时区无关）：
```dart
expect(local.millisecondsSinceEpoch, utc.millisecondsSinceEpoch);  // 时刻不变
expect(local.isUtc, isFalse);                                      // 已转本地
expect(local.timeZoneOffset, DateTime.now().timeZoneOffset);       // 用本地时区
```

---

## ⑧ 凭据与"别人装完也能用"

**两条独立要求**（常被混为一谈）：

| 要求 | 做法 |
|---|---|
| **凭据不入库** | 用户填的存 `secure_storage`；内置的用**签名绑定混淆**（见 `lib/data/builtin_secret.dart`）|
| **别人装完就能用** | 公开端点（榜单/日历）**内置 Client ID** 即可用；需 OAuth 的功能必须**先走设备码登录**，入口放在用户找得到的地方 |

⚠️ **公开端点也需要 `trakt-api-key` 头**（实测无 key → 403）
⇒ "公开"指"不需要**用户**登录"，**不**指"不需要 Client ID"。

⚠️ **每个未验证项都要在汇报里点名**（本仓库 §8.3）——
   例如"真机完整授权尚未走通"必须写明，不能写成"已支持登录"。

---

## 实测附录：Trakt 端点矩阵（2026-10-14）

**环境**：Client ID 有效；无 OAuth token（需鉴权的预期 401）。
**总计 62 个端点实测** ⇒ 46 可用 / 8 需 OAuth / 其余为 204-405-400-404。

### 无需登录即可用（★ 决定"新人装完就能用"）

| 分组 | 端点 | 实测 |
|---|---|---|
| 元数据 | `/genres/{shows,movies}` | 200，`list[37]` / `list[27]` |
| 元数据 | `/languages/shows` `/countries/shows` | 200，`list[115]` / `list[156]` |
| 元数据 | `/networks` | 200，`list[5535]`（4.6s，**慢**）|
| 元数据 | `/certifications/shows` | 200，`dict` |
| 榜单 | `/shows/{trending,popular,anticipated}` | 200，`list[10]` |
| 榜单 | `/shows/{watched,played,collected,favorited}/weekly` | 200，`list[10]` |
| 榜单 | `/movies/{trending,popular,anticipated}` | 200，`list[10]` |
| 榜单 | `/movies/{watched,played,collected,favorited}/weekly` | 200，`list[10]` |
| 榜单 | `/movies/boxoffice` | 200，`list[10]` |
| 榜单 | `/media/{trending,popular,anticipated}` | 200，`list[10]` |
| 榜单 | ~~`/shows/streaming/{p}`~~ ~~`/movies/streaming/{p}`~~ | ❌ **404 endpoint removed** |
| 详情 | `/shows/{id}?extended=full` `/seasons` `/seasons/{n}/episodes` | 200 |
| 详情 | `/shows/{id}/{next,last}_episode` | 200 / **204**（已完结 ⇒ 204 正常）|
| 详情 | `/shows/{id}/{related,people,ratings,stats,videos}` | 200 |
| 日历 | `/calendars/all/shows/{date}/{days}` | 200，**418 条/周** |
| 日历 | `/calendars/all/shows/{new,premieres,finales}/{date}/{days}` | 200，13 / 64 / 40 条 |
| 日历 | `/calendars/all/{movies,streaming,dvd}/{date}/{days}` | 200，32 / 67 / 44 条 |
| 搜索 | `/search/{show,movie}?query=` | 200 |
| 搜索 | `/search/tmdb/{id}?type={show,movie}` | 200 |
| 列表 | `/lists/{trending,popular}` | 200 |
| 评论 | `/shows/{id}/comments/newest` | 200 |
| 人物 | `/people/{id}?extended=full` `/people/{id}/shows` | 200 |
| 网络 | `/calendars/all/shows/...` | 3.4s（**首字节慢**）|

### 需要 OAuth（预期 401，已实现）

| 端点 | 用途 |
|---|---|
| `/users/me` | 用户资料 |
| `/sync/playback` | 续播进度 |
| `/sync/watched/shows` | 已看列表 |
| `/sync/history`（POST）| 写入已看 |
| `/sync/watchlist/*` | 观看清单 |
| `/sync/progress/up_next` | 下一集 |
| `/recommendations/{shows,movies}` | 推荐 |
| `/calendars/my/*` | 个性化日历 |
| `/scrobble/{start,pause,stop}` | 实时追踪 |

### 我实现时踩到的形状差异（**必须处理**）

| 端点 | 形状 |
|---|---|
| `/shows/trending` | `[{watchers, show:{...}}]` 外层包裹 |
| `/shows/popular` | `[{ids, year, title}]` **裸对象** |
| `/movies/trending` | `[{watchers, movie:{...}}]` |
| `/calendars/all/shows` | `[{show, episode, first_aired, released}]` |
| `/calendars/all/movies` | `[{movie, released}]`（**无 episode**）|

---

## 借鉴：小幻影视（RodelPlayer）的 Trakt 设计

> **来源**：`D:\小幻影视-逆向-writeup`（用户 2026-10-14 提供）
> —— 小幻影视 v2.2607.7.0 的 **NativeAOT 逆向**产物。
>
> ### ⚠️ 依据强度必须标注（AGENTS §6.10 第④条：不许把推断写成事实）
> | 标记 | 含义 |
> |---|---|
> | `[名]` | **只有方法名**（我的推断，可能错）|
> | `[实]` | 本仓库或官方文档**已实测/已证实** |
>
> ### ⚠️ 它不是可照抄的源码
> 报告自己写明：
> > NativeAOT 无 IL，"源码"为**接口级/逻辑级等价重建**：
> > 类型与方法名 100% 来自二进制真实元数据；方法体为反汇编语义重建（伪 C#）。
>
> ⇒ 我拿到的是**方法名 + 调用关系**，**不是方法体**。
>    所以本文只借鉴**设计意图**，不照搬实现。

### 它的 TraktClient 骨架（从符号表读出）

```
认证  TraktDeviceCodeRequest → DeviceCodeResponse
      → TraktDeviceTokenRequest → TraktAuthResponse
      ├─ TraktRefreshTokenRequest          （刷新）
      └─ TraktRevokeTokenRequest           （吊销 —— 登出用）
      set_TraktAccessToken / set_TraktRefreshToken / set_TraktExpiresTimestamp
      GetValidTraktAccessTokenAsync        （统一入口：取"有效" token）

同步  SyncServerToTraktAsync               （服务器 → Trakt）
      SyncTraktToServerAsync               （Trakt → 服务器）
      SyncTraktToServerAsync0GetValidAccessTokenAsync
追踪  TraktScrobbleStart/Pause/StopAsync
      BuildTraktScrobbleRequestFromSnapshot
续播  CheckTraktResumeAsync
UI    TraktSignIn / TraktSignInDescription / TraktSignInFailed
      TraktSignedInAs                      （显示"已登录为 xxx"）
```

### 采纳的三条（**均已落地并跑绿**，2026-10-14）

| # | 它的做法 | 为什么值得学 | 本仓库落地 |
|---|---|---|---|
| ① | `[名]` `set_TraktExpiresTimestamp`（存**过期时间戳**）| 能**本地算出**到期时刻 ⇒ 可"提前刷新"，不必等 401 才发现过期（少一次必然失败的请求 + 少一条误导性日志）| ✅ `SessionStore.saveTraktExpiresAt` / `traktExpiresInMs`；`TraktSync._reportExpiry` 从 `created_at + expires_in` 算出；`fromStore` 在剩余 < **1 天**时提前刷新 |
| ② | `[名]` `GetValidTraktAccessTokenAsync` 作为**唯一取 token 入口** | 避免"多处各自读 token ⇒ 加字段时漏改"。**我本轮就踩了这个坑**：三处 `TraktSync(...)` 差点让刷新成死代码 | ✅ 收口到 `TraktSync.fromStore(...)`（三处调用点全改）|
| ③ | `[名]` `TraktRevokeTokenRequest`（登出时吊销）| 只清本地的话，Trakt 服务端**仍认为 token 有效**（安全上不干净）| ✅ `TraktSync.revoke()`；`_logout()` 里**先吊销再清本地**，且吊销失败**不阻止**本地登出 |

### ③ 的实测依据（`[实]`，不凭方法名猜）

契约（`contracts/oauth/index.ts:180`）：
```
summary: 'Revoke an access_token'
path: '/revoke'   method: 'POST'
body: { token*: string, client_id*: string }
200: z.undefined()
```
实测（2026-10-14，用**假** token 探测，不消耗真实凭据）：
```
POST /oauth/revoke { token, client_id }   → 200  ✅ 契约形状
POST /oauth/revoke { access_token, ... }  → 200  （服务端宽松，不校验字段名）
POST /oauth/revoke {}                     → 401 unauthorized_client
                                             ← 证明服务端**确实在校验**
```

### 与它**一致**的地方（互相印证）
`[实]` 它有 `TraktSignedInAs`（显示"已登录为 xxx"），
而用户 2026-10-14 明确要求"这个授权成功后，显示我的 trakt 名字哇"
⇒ 两处结论一致 ⇒ 说明这个交互是**行业惯例**，不是个人偏好。

### **明确不采纳**的（附理由，不沉默跳过）

| 项 | 为什么不采纳 |
|---|---|
| 它的 `SyncServerToTrakt` / `SyncTraktToServer` **命名** | 那是"服务器"泛指（它支持 Emby/Jellyfin/Plex 多源）；本仓库只有 Emby 且已有 `MediaProvider` 抽象 ⇒ `pull`/`push` 更准确 |
| `[名]` `BuildTraktScrobbleRequestFromSnapshot` | 无法确认"快照"指什么（可能是它的播放状态模型）⇒ 本仓库 `TraktPlaybackReporter` 已含节流，不冒然改 |
| NativeAOT 逆向手法本身 | 与 Android 播放器无关（那是 Windows 桌面端逆向）|

### 它**没有**而我们有的（反向对照，避免误以为我们缺很多）

| 我们的做法 | 它的骨架里没有对应符号 |
|---|---|
| `TraktEpisodeResolver`（**实测的 episode id 解析链**：tmdb → trakt show → 某季集列表）| 未见同名/近义方法 ⇒ 它可能走了别的路径（或符号被内联）|
| `TraktPlaybackReporter` 的**节流**（同类动作 minInterval 内不重发）| `[名]` 只见 `TraktScrobble*Async`，未见节流相关符号 |
| `TraktWatchedSyncer` 的**"只加不减"安全约束** | 未见对应符号 ⇒ **无法判断**它是否也有这个保护（**不能说"它有/没有"**）|

> ⚠️ 最后一行特意写成"**无法判断**"而不是"它没有" ——
> 逆向符号表只能证明"存在什么"，**不能证明"不存在什么"**
> （符号可能被内联/裁剪/改名）。

---

## 本轮新增实测（2026-10-15）

### ① 电影同步端点（实测确认存在）

用户在《生化危机爆发夜》（**电影**）上点同步报 `404`，
根因是**电影走了剧集路径**（`getSeasons(电影id)` → `/Shows/{电影id}/Seasons` → 404）。

实测电影端点的**合法取值**（假 token 探测）：

| 端点 | 状态 | 结论 |
|---|---|---|
| `/sync/watched/movies` | **401** | ✅ 存在（复数才对）|
| `/sync/watched/movie` | 405 | ❌ 单数不行 |
| `/sync/watched/shows` | 401 | ✅ 存在 |
| `/sync/watched/episodes` | 401 | ✅ 存在 |
| `/sync/watched/seasons` | **405** | ⚠️ 契约说 `:type` 可为 seasons，**但服务端 405** |
| `/sync/watched/this-does-not-exist` | 405 | （对照）|
| `POST /sync/history {movies:[{ids:{tmdb}}]}` | 401 | ✅ 端点与 body 形状对 |

⇒ 又一个"**契约 ≠ 现实**"的实例（`seasons` 在契约里合法但服务端拒绝）。
⚠️ 且 **movie 的 ids 支持 tmdb**（`movieIdsRequestSchema`），
   与 episode **不同**（那个只认 trakt/tvdb）。

### ② history vs watched —— **语义不同，不能混用**

用户报障："我的 Trakt 中有仙逆记录，但点击同步没实现"。
日志：`[TraktPull] Trakt 上 tmdb=223911 (trakt=203833) 没有已看记录`
而 Trakt 网页历史里**明明有**那两集。

契约原文（`contracts/sync/index.ts`）：
```
第 219 行 history: { summary: 'Get watched history'
    description: 'Returns movies and episodes that a user has **watched**,
                  sorted by most recent.'   path: '/:type/:id' }

第 677 行 watched: { summary: 'Get watched'
    description: 'Returns all movies, shows, seasons, or episodes
                  **watched** by the authenticated user.'
    path: '/watched/:type' }
```

| 概念 | 端点 | **写入条件** |
|---|---|---|
| **history** | `GET /sync/history/shows/:id` | **任何播放**（含看一半）|
| watched | `GET /sync/watched/shows` | 仅 `progress > 80%` |

⇒ 用户"**观看了一部分**" ⇒ 只进 history ⇒ 查 watched **必然为空**。
**修法**：`TraktWatchedSyncer.pull` 改为 **history 优先、watched 回退**。

⚠️ 注意 history 的路径**必须带 `:id`**（与 watched 不同 —— 那个是全量）。

### ③ scrobble 的三个进度区间（决定"继续观看"能否出现）

契约原文（`contracts/scrobble/index.ts:50-55`）：
```
stop: 'If the progress is **above 80%**, the video will be marked as watched.
       If the progress is **between 1% and 79%**, it will be treated as a pause
       and the action will be set to pause.
       If the progress is **less than 1%**, you'll get a 422.'
```

| 本地状态 | 应调用 | Trakt 结果 |
|---|---|---|
| `played == true` 或 `progress > 80%` | `POST /sync/history` | 已看 |
| `1% ≤ progress ≤ 79%` | **`POST /scrobble/pause`** | **继续观看** |
| `progress < 1%` | 跳过 | （发了会 422）|

⇒ 用户诉求"看了一部分的应该同步为 trakt 的**继续观看**"就是中间那一行。

### ④ Emby 侧：详情端点**必须**带 `Fields=UserData`

用户报障："电影我看了 1 分钟，但是显示的是**立即播放**"。

因果链（逐环可查）：
```
① emby_provider.dart  _detailFields 缺 'UserData'
② models.dart:234     final ud = j['UserData'] as Map?  ⇒ null
③ models.dart:260-261 playedPercentage / positionTicks  ⇒ 全 null
④ models.dart:394     progress getter ⇒ return 0
⑤ detail_page.dart    resume = progress > 0 && !played  ⇒ 恒 false
⑥ 按钮永远「立即播放」
```
**只在电影上暴露**：剧集走 `getEpisodes`（那个 Fields 本来就带 UserData）。

---

## Trakt 端点：**已实现 vs 未实现**（截至 2026-10-15）

### 已实现（19 个，全部有调用点）

| 分组 | 端点 | 用途 |
|---|---|---|
| 认证 | `POST /oauth/device/code`、`/oauth/device/token` | 设备码登录 |
| 认证 | `POST /oauth/token`（refresh） | 自动续期 |
| 认证 | `POST /oauth/revoke` | 登出吊销 |
| 用户 | `GET /users/me` | 显示 `@username` + 头像 |
| 查询 | `GET /search/tmdb/{id}` | tmdb → trakt 映射 |
| 查询 | `GET /shows/{id}/seasons/{n}/episodes` | episode id 解析 |
| 追踪 | `POST /scrobble/{start,pause,stop}` | 实时追踪 + **继续观看** |
| 同步 | `POST /sync/history` | 写已看（movies + episodes）|
| 同步 | `GET /sync/watched/{shows,movies}` | 读已看（**回退**用）|
| 同步 | `GET /sync/history/shows/{id}` | 读播放历史（**优先**）|
| 同步 | `GET /sync/playback` | 续播检查 |

### 未实现（12 个，均为**发现/社交**类）

| 端点 | 用途 | 价值判断 |
|---|---|---|
| `/sync/watchlist` | 待看列表 | 中（用户可能想要）|
| `/sync/ratings` | 评分同步 | 中 |
| `/sync/collection` | 收藏 | 中（Emby 已有收藏）|
| `/sync/favorites` | 最爱 | 低（与收藏重叠）|
| `/checkin` | 手动"正在看" | 低（scrobble 已覆盖）|
| `/sync/progress/up_next` | 下一集 | 低（Emby `NextUp` 更准）|
| `/users/me/stats` | 统计 | 低（本 App 已有统计）|
| `/users/me/history` | 播放历史列表 | 低 |
| `/recommendations` | 推荐 | 中 |
| `/sync/last_activities` | 增量同步 | **中高**（可省大量请求）|
| `/calendars/my` | 个性化日历 | 中（需 OAuth）|
| `filters`（`years`/`genres`/`ratings`…）| 榜单筛选 | 中 |

> ⚠️ **未实现 ≠ 缺陷**：这些都不在用户本轮诉求内。
> 若要做，应**先问用户优先级**（而不是擅自扩大范围）。
