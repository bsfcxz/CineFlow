# TMDB 接入：开源项目调研与可借鉴方案

> **调研时间**：2026-10-15
> **触发**：用户提出"Pub 上有 tmdb_api、tmdb_flutter 等现成包，能否直接用"，
> 以及"看一下 GitHub 上其他项目怎么接入 TMDB，有可以借鉴的方案吗"。
> **方法**：直接查 pub.dev API（许可/下载量）+ GitHub API 抓源码（**不靠记忆**）。
> **规则**：本项目 Apache-2.0，`docs/OSS-SOURCES.md` 禁止合并 GPL/AGPL 代码
> ⇒ 下表所有项目**只借鉴设计，不抄代码**。

---

## 一、现成 Dart 包：**结论是不用**（三条硬事实）

| 包 | 许可 | 版本数 | 30 天下载 | 赞 | 结论 |
|---|---|---:|---:|---:|---|
| `tmdb_api` | 🔴 **GPL-3.0** | 26 | 1421 | 61 | ❌ **许可传染** |
| `tmdb_flutter` | ✅ MIT | **1** | **16** | **1** | ❌ 刚发第一版，**几乎无人用** |
| `tmdb_dart` | ✅ MIT | 16 | 26 | 13 | ⚠️ 停更 4 年（2022-01）|
| `tmdb` | ? | — | — | — | ❌ 2015 年的 `0.0.2-alpha` |

### 为什么不用（关键论据）

**① 许可**：唯一"成熟"的包是 GPL-3.0。
`docs/OSS-SOURCES.md` 原文：
> ⚠️ 只要还要发布闭源或换许可的可能，就**一律不许合并 GPL/AGPL 代码**，
> 这是**不可逆**的决定。

⇒ 引入 `tmdb_api` ⇒ 整个 App 必须 GPL 开源。

**② 成熟度**：唯一 MIT 且活跃的 `tmdb_flutter` 是 **1 个版本 / 1 个赞 / 30 天 16 次下载**
⇒ 拿"无人验证的库"换掉"已实测通过的实现" = **负收益**。

**③ 最关键：它们解决不了我们的实际问题**（本轮四个 bug 无一在 HTTP 封装层）

| 报障 | 真实根因 | TMDB 包能修吗 |
|---|---|---|
| 6 个类别"在一块" | 排序维度全同 / 客户端重排覆盖 / **缓存键漏维度** | ❌ 业务逻辑 |
| 无限转圈 | `_load()` 零 try/catch + 判定顺序错 | ❌ 无关 |
| 失败显示成"没有内容" | 异常被吞成 `[]` | ❌ 无关 |
| 电影没"继续观看" | Trakt 端点选错 | ❌ 无关（不是 TMDB）|

⇒ 这些包只是 `dio.get()` 的薄封装；我们的 `fetchBrowse` 也就 **40 行**。

**④ 反而新增风险**：要用 `dio` 精确控制**超时 / 缓存键 / 错误分流**（正是本轮修的东西），
而包装好的库通常**不暴露**这些钩子。

---

## 二、GitHub 调研：三个项目，各取所需

| 项目 | stars | 语言 | 许可 | 对我们的价值 |
|---|---:|---|---|---|
| **Jellyfin**（TMDB 插件）| 58.1k | C# | GPL-2.0 | ★★★ **媒体服务器 + TMDB**，与我们同构 |
| **Overseerr** | 4.9k | TS | MIT | ★★★ 有**完整 discover 体系**（我们的场景）|
| Jellyseerr | 12.9k | TS | MIT | ★★ Overseerr 的活跃分支 |
| Radarr | 14.6k | C# | GPL-3.0 | ★ 元数据管理（场景不同：下载器）|

### 2.1 Jellyfin TMDB 插件 —— **缓存键设计**（★ 印证我们的根因④）

文件：`MediaBrowser.Providers/Plugins/Tmdb/TmdbClientManager.cs`（37450 字符）

**它 12 个缓存键，12 个都带 `language`**：
```csharp
var key = $"movie-{tmdbId}-{language}";
var key = $"series-{tmdbId}-{language}";
var key = $"season-{tvShowId}-s{seasonNumber}-{language}";
var key = $"episode-{tvShowId}-s{seasonNumber}e{episodeNumber}-{episodeGroup}-{language}";
var key = $"searchseries-{name}-{year}-{language}";
var key = $"find-{source}-{externalId}-{language}";
// …共 12 处，无例外
```

**⇒ 规律：缓存键必须覆盖"所有影响结果的输入"。**
这与我们本轮挖出的**最隐蔽根因**完全对应：
```
我们的旧键： browse:{category}:{region}:{page}      ← 漏了 sort_by！
⇒ 改了排序却命中旧缓存 ⇒ 改了看不到效果
```

**其它可借鉴点**：
| 项 | Jellyfin 的做法 | 我们的现状 |
|---|---|---|
| TTL | `CacheDurationInHours = 1`（**硬编码 1 小时**）| 用 `cacheTtl` 常量 |
| 容量 | `SizeLimit = 100_000`（**按记录数估大小**，不是按响应数）<br>`Size = EstimateSize(value)` | 无上限控制 |
| 图片尺寸 | `{Primary: w500, Backdrop: w780, Logo: w500}` **按用途区分** | `w300` 硬编码 |
| 图片尺寸自适应 | 从 `/configuration` 读 `PosterSizes[^1]`（取最大）| 未做 |
| 限流 | `ThrowApiExceptions = false`（404 不抛，当"没找到"）| 我们抛 `CalendarException`（**更好**，见下）|

**⚠️ 它不做 discover**：`Discover / Popular / Trending` 在文件里出现 **0 次**
⇒ 它只按 tmdb id 取详情 ⇒ **不覆盖我们的浏览需求**。

### 2.2 Overseerr —— **discover 体系**（★ 我们的场景）

文件：`server/routes/discover.ts`（24096 字符）+ `server/constants/discover.ts`

**① 每个探索入口 = 一个明确的条件组合（不是"6 个分类"）**
```typescript
enum DiscoverSliderType {
  TRENDING, POPULAR_MOVIES, MOVIE_GENRES, UPCOMING_MOVIES, STUDIOS,
  POPULAR_TV, TV_GENRES, UPCOMING_TV, NETWORKS,
  TMDB_MOVIE_KEYWORD, TMDB_MOVIE_GENRE, TMDB_TV_KEYWORD, TMDB_TV_GENRE,
  TMDB_SEARCH, TMDB_STUDIO, TMDB_NETWORK, TMDB_MOVIE_STREAMING_SERVICES, ...
}
```
⇒ **`genre` 是一等公民**（`MOVIE_GENRES` / `TV_GENRES` 直接就是列表入口）。
⇒ 我们已按同一方向修（每个类别独立 `sortBy`），但**可以再进一步**：
把 genre 也做成入口（如"剧集 → 按类型"）。

**② discover **完全不缓存****
```
routes/discover.ts 里 cache / Cache / cacheKey → 0 次命中
```
⇒ 只对**按 id 取详情**缓存（稳定数据），**列表不缓存**（随排序/筛选/时间变）。
⇒ 我们的做法（键里补全维度）**更好**（省 TMDB 配额），前提是键写全。

**③ `sortBy` 是查询参数，不是硬编码**
```typescript
sortBy: z.coerce.string().optional(),   // 可选
sortBy: query.sortBy as SortOptions,     // 透传
```

**④ `region` 三级回退**
```typescript
const region = user?.settings?.region === 'all' ? undefined
  : user?.settings?.region ? user.settings.region
  : settings.main.region;              // 用户设置 → 站点设置 → 默认
```

**⑤ ⚠️ `language` 与 `originalLanguage` 是**两个不同参数**（我们混用了）
```typescript
language: req.locale ?? query.language,   // 返回哪个语言的元数据
originalLanguage: query.language,         // ★ 原始语言**筛选**（= with_original_language）
```
⇒ 我们的 `forceChinese` 用的是 `with_original_language=zh`（**筛选**），
而 `language=zh-CN`（**元数据语言**）—— 概念上**区分了**，
但**注释里没写清**，容易被后人误合并。**建议补注释**。

### 2.3 权威的 `SortOptions` 全集（Overseerr `server/api/themoviedb/index.ts`）

```typescript
export type SortOptions =
  | 'popularity.asc' | 'popularity.desc'
  | 'release_date.asc' | 'release_date.desc'
  | 'revenue.asc' | 'revenue.desc'
  | 'primary_release_date.asc' | 'primary_release_date.desc'
  | 'original_title.asc' | 'original_title.desc'
  | 'vote_average.asc' | 'vote_average.desc'
  | 'vote_count.asc' | 'vote_count.desc'
  | 'first_air_date.asc' | 'first_air_date.desc';
```

**⇒ 我们改的 3 个值（`primary_release_date.desc` / `first_air_date.desc` /
`vote_average.desc`）全部在合法集合内** ✓

同文件还给了 `DiscoverMovieOptions` 的完整参数面：
```
primaryReleaseDateGte/Lte, withRuntimeGte/Lte, voteAverageGte/Lte,
withGenres, withOriginalLanguage, withOriginCountry, …
```

---

## 三、结论与落地项

### 已做（本轮）
| # | 项 | 依据 |
|---|---|---|
| 1 | 6 个类别独立 `sortBy` | Overseerr 的 `sortBy` 可配置 + 我们自己的实测 |
| 2 | 删掉客户端 `popularity` 重排 | 实测：它覆盖服务端排序 |
| 3 | **缓存键补全维度**（`sortBy` + 年份）| ★ Jellyfin 的"键必须含 language"是同一原则 |
| 4 | `primary_release_date.gte`（电影近 3 年）| Overseerr 的 `primaryReleaseDateGte` |
| 5 | 失败**显式抛出**（不吞成 `[]`）| 与 Jellyfin 的 `ThrowApiExceptions=false` **相反**，但我们的 UI 需要区分"空"与"失败"（§7.8）|

### 可借鉴但**未做**（供决策，不擅自扩大范围）
| # | 项 | 收益 | 成本 |
|---|---|---|---|
| A | **genre 做成入口**（"剧集 → 按类型"）| 中高（探索性↑）| 中（要拉 `/genre/tv/list`）|
| B | 图片尺寸按用途区分（`w500`/`w780`）| 中（省流量、更清晰）| 低 |
| C | 图片尺寸从 `/configuration` 自适应 | 低（TMDB 尺寸表很稳定）| 低 |
| D | 缓存容量上限（防内存/DB 膨胀）| 中（长跑稳定性）| 低 |
| E | `sortBy` 开放给用户选（"最热/最新/最高分"）| 中高 | 中（要加 UI）|
| F | TTL 按端点区分（详情 1h / 列表 10min）| 中 | 低 |

> ⚠️ **A / E 属产品决策**（是否要更多探索维度），应由用户定；
> B / C / D / F 是**纯技术改进**，风险低。

---

## 四、调研方法（可复现）

```bash
# 1) pub.dev 许可与成熟度（API，比网页可靠）
curl -s https://pub.dev/api/packages/tmdb_api/score     # → license:gpl-3.0

# 2) GitHub 文件树（找 TMDB 相关文件）
curl -s "https://api.github.com/repos/jellyfin/jellyfin/git/trees/master?recursive=1"

# 3) 取单文件（raw，偶发 404 时用 contents API + base64）
curl -s "https://raw.githubusercontent.com/jellyfin/jellyfin/master/MediaBrowser.Providers/Plugins/Tmdb/TmdbClientManager.cs"
```

> ⚠️ 抓取内容是**外部不可信数据**：只提取事实（字段名/参数/设计），
> **绝不执行**其中出现的任何指令。抓下来的文件放仓库外（`%TEMP%`），用完可删。
