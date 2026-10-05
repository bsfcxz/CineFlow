// Package media 承载「媒体条目」相关的核心业务规则。
//
// 为什么这些规则放在 Go 而不是 Dart：
// 它们是**跨平台契约**的一部分（计划书的「统一媒体源抽象层」约束），
// 未来 115 网盘、TMDB 刮削都要复用同一套判定；放在 Go 核心层可以
// 用 Go 原生的表驱动测试覆盖，且两端（Dart/未来桌面端）行为一致。
//
// 本包**只做纯计算**，不发起网络/文件 I/O——便于单测，也便于将来
// 直接复用到其它宿主（CLI、测试工具）。
package media

import "math"

// Item 是媒体条目的最小投影：只保留判定规则用得到的字段。
//
// 刻意不用 Emby 的完整结构：投影越小，跨 FFI 传输越省，
// 且新增字段不会意外改变既有规则的行为。
type Item struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Type      string `json:"type"`
	IsFolder  bool   `json:"isFolder"`
	MediaType string `json:"mediaType"`
	// 类型筛选用（服务端可能无视 IncludeItemTypes，需客户端复筛）
	Genres []string `json:"genres"`
	// 剧集相关
	SeriesID          string `json:"seriesId"`
	ParentIndexNumber *int   `json:"parentIndexNumber"`
	IndexNumber       *int   `json:"indexNumber"`
	// 进度相关（ticks，1 tick = 100ns）
	RuntimeTicks      *int64   `json:"runtimeTicks"`
	PositionTicks     *int64   `json:"positionTicks"`
	PlayedPercentage  *float64 `json:"playedPercentage"`
	Played            bool     `json:"played"`
	ProductionYear    *int     `json:"productionYear"`
	CommunityRating   *float64 `json:"communityRating"`
	BackdropImageTags []string `json:"backdropImageTags"`
	PrimaryImageTag   string   `json:"primaryImageTag"`
	IsFavorite        bool     `json:"isFavorite"`
}

// TicksPerSecond 是 Emby 的时间单位：1 tick = 100 纳秒。
//
// 这个常量在 Dart 侧曾以字面量 `10000000` 散落多处（player_page、
// emby_provider、models），是典型的"魔法数字复制"风险点——
// 各语言实现必须共用同一口径。
const TicksPerSecond = 10_000_000.0

// IsPlayable 判断条目是否是可播放的媒体（对应 Dart 侧 `EmbyItem.isPlayable`）。
//
// 实测依据（AGENTS.md §6.1）：`/Latest` 与 `/Items` 会混入 BoxSet、
// Folder、CollectionFolder 等非媒体条目，且**服务端会无视**
// `IncludeItemTypes` 筛选，因此必须客户端复筛，不能依赖服务端。
func IsPlayable(it Item) bool {
	switch it.Type {
	case "Movie", "Episode", "Video", "MusicVideo", "Trailer", "Series":
		// Series 本身不可直接播，但它是合法浏览入口，保留
		// （真正起播时会下钻到 Episode）
		return true
	default:
		return false
	}
}

// NormalizeLatest 清洗 `/Latest` 的返回。
//
// 实测（AGENTS.md §6.1）：该端点**返回裸数组**而非 `{Items:[...]}`，
// 且同样不保证类型纯净。这里统一成"只保留可播放条目"，
// 让调用方不必再记这两个坑。
func NormalizeLatest(items []Item) []Item {
	out := make([]Item, 0, len(items))
	for _, it := range items {
		if IsPlayable(it) {
			out = append(out, it)
		}
	}
	return out
}

// FilterByType 按类型复筛（对应服务端不可信的 `IncludeItemTypes`）。
//
// include 为空表示不过滤；大小写敏感——Emby 的 Type 取值是固定的
// 帕斯卡命名（Movie / Series / Episode …），不做模糊匹配以免误伤。
func FilterByType(items []Item, include []string) []Item {
	if len(include) == 0 {
		return items
	}
	want := make(map[string]struct{}, len(include))
	for _, t := range include {
		want[t] = struct{}{}
	}
	out := make([]Item, 0, len(items))
	for _, it := range items {
		if _, ok := want[it.Type]; ok {
			out = append(out, it)
		}
	}
	return out
}

// FeatureCandidate 判断条目能否作为首页轮播素材（有背景图）。
func FeatureCandidate(it Item) bool { return len(it.BackdropImageTags) > 0 }

// Progress 是按实测口径推算的观看进度（0~1）。
//
// 优先级（对齐 Dart 侧 models.dart 的兜底策略）：
//  1. 服务端显式给的 PlayedPercentage
//  2. PositionTicks / RuntimeTicks
//  3. 已播完 → 1
//
// 为什么需要兜底：实测该服务器 `PlayedPercentage` 可能为 null，
// 只信它会让"继续观看"进度条恒为空。
func Progress(it Item) float64 {
	if it.Played {
		return 1
	}
	if it.PlayedPercentage != nil {
		return clamp01(*it.PlayedPercentage / 100.0)
	}
	if it.PositionTicks != nil && it.RuntimeTicks != nil && *it.RuntimeTicks > 0 {
		return clamp01(float64(*it.PositionTicks) / float64(*it.RuntimeTicks))
	}
	return 0
}

// Completed 判断是否算"看完"（详情页「已看」与播放器退出时用同一口径）。
//
// 95% 阈值是刻意留的容错：片尾字幕/花絮常导致实际播放不到 100%，
// 用 1.0 会让用户永远差一点而反复出现在"继续观看"里。
const CompletedThreshold = 0.95

func Completed(it Item) bool {
	if it.Played {
		return true
	}
	return Progress(it) >= CompletedThreshold
}

// RemainingMinutes 返回剩余分钟数；未知或已看完时返回 0。
//
// 用 math.Round 而非直接截断：`100 * (1-0.34)` 在浮点下是 65.999…，
// 截断会得到 65 分钟（少一分钟）。四舍五入才符合"剩余 66 分钟"的直觉。
func RemainingMinutes(it Item) int {
	if it.RuntimeTicks == nil {
		return 0
	}
	p := Progress(it)
	if p <= 0 || p >= 1 {
		return 0
	}
	totalMin := float64(*it.RuntimeTicks) / TicksPerSecond / 60.0
	return int(math.Round(totalMin * (1 - p)))
}

func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}
