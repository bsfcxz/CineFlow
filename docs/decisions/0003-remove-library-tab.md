# ADR 0003 · 移除「媒体库」一级 Tab，列表页待全量重构

- 状态：**已采纳**（2026-10-04）
- 决策者：项目所有者
- 影响范围：`lib/pages/home_shell.dart`、`lib/pages/library_page.dart`（删除）、`docs/task-board.md`

## 背景

`LibraryPage` 是最早实现的页面之一，堆叠了较多在当时合理、但整体交互未经打磨的机制：

- 服务端分页（`StartIndex`/`Limit`）+ 滚动加载
- 排序三态循环（最近添加 / 名称 / 评分）+ 次级排序键
- 未观看筛选、库内搜索
- 类型/年份筛选（原为客户端复筛，2026-10 改为服务端 `Genres`/`Years`）
- 海报/列表双视图切换
- 库分类 chips

结果是：功能齐全但信息密度高、筛选入口层级深，作为**一级 Tab** 的体验不达标。
所有者判断列表页 UI 需要**全量重构**，而不是在现有结构上继续修补；
在重构完成前，不应继续把它暴露为一级入口。

## 决策

1. **移除底部 Tab 的「媒体库」**。一级导航变为三项：首页 / 排行榜 / 我的。
2. **删除 `lib/pages/library_page.dart`**（连同其客户端排序/筛选 UI）。
3. **保留数据层能力**，因为它们是已被实测验证的协议知识，且被其他页面复用：

   | 保留项 | 位置 | 谁在用 |
   |---|---|---|
   | `getItems`（含 `genres`/`years`/`sortOrder`） | `MediaProvider` / `EmbyProvider` | 首页合集、详情页合集内嵌、我的统计四格 |
   | `getGenres`（`/Genres?ParentId=`） | 同上 | 待重构的列表页 |
   | `getYearRange`（`ProductionYear` 双探针） | 同上 | 同上 |
   | `getViews`（`/Users/{uid}/Views`） | 同上 | 待重构的列表页 |

4. **不保留**页面级的排序标签/循环/次级键 helper —— 它们属于已删除的 UI，
   重构时应按新设计重新决定（避免"照搬旧交互"）。

## 保留的协议结论（重构时直接用，无需重新实测）

这些结论来自 curl 实测，已写入代码注释：

1. **`SortOrder` 必须由客户端显式指定**。`DateCreated + Ascending` 返回**最旧**，
   `Descending` 才是"最近添加"。
2. **`SortBy`/`SortOrder` 支持逗号分隔多字段**（如 `DateCreated,SortName` +
   `Descending,Ascending`），可用于加次级键稳定翻页顺序。
3. **`Genres` / `Years` 服务端筛选有效**：
   华语电影库 `Genres=动作` → TotalRecordCount 2035→823，返回条目确实都含「动作」；
   `Years=2024` → 67；两者组合 → 19（交集语义）。
   分页场景必须走服务端，客户端复筛只作用于已加载页。
4. **`/Genres?ParentId=&UserId=` → 200 + `{Items:[{Name}]}`**，空 `Name` 需滤掉。
5. **年份没有可用的分面端点**（`/Items/Filters`、`/Items/Filters2` 在本服务器均返回
   "找不到文件"）。取区间用两次 `ProductionYear` 探针 + `Limit=1`
   （本服务器 1931–2026）。
6. **一个分面挂掉不能拖垮整块面板**：分面失败只是少了筛选项，不应报错。

## 后果

- **正面**：一级导航更聚焦；不再维护一个注定要被重写的页面。
- **负面 / 待补**：
  - 首页的「媒体库 ›」入口原本就是 `showComingSoon` 占位，现在仍无真实落地页。
    重构前，用户进入某个库的路径是：首页 → 合集/继续观看 → 详情。
  - `CF-P4-UI-010`（类型/年份改服务端查询）**其 UI 部分随本 ADR 作废**，
    但数据层实现与单测保留（`test/server_filter_test.dart` 覆盖参数拼装）。
  - 「我的」页的统计四格仍调用 `getItems`，不受影响。

## 相关

- `docs/decisions/0002-pure-dart-mvp.md`（现行架构）
- `test/server_filter_test.dart`（服务端筛选参数回归线）
- `AGENTS.md` §7 缺陷台账 7.15 条目
