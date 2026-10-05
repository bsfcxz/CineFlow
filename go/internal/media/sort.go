package media

import (
	"sort"
	"strings"
)

// SortField 是排序字段的稳定标识。
//
// 用自定义类型而不是裸 string：这些值会跨 FFI 传（JSON），
// 拼错字符串会静默退化成"默认排序"，类型化能让编译器挡住一部分。
type SortField string

const (
	SortByDateCreated     SortField = "DateCreated"
	SortBySortName        SortField = "SortName"
	SortByCommunityRating SortField = "CommunityRating"
	SortByProductionYear  SortField = "ProductionYear"
	SortByRuntime         SortField = "Runtime"
	SortByDatePlayed      SortField = "DatePlayed"
	SortByPlayCount       SortField = "PlayCount"
)

// Direction 是排序方向。
type Direction string

const (
	Ascending  Direction = "Ascending"
	Descending Direction = "Descending"
)

// DefaultDirection 返回某字段的默认排序方向。
//
// 这是**实测 + 社区对照**双重确认的规则（AGENTS.md §6.1 / §10.6），
// 不要凭直觉改：
//
//   - 本机 curl 实测：`DateCreated+Ascending` 返回**最旧**，
//     `Descending` 才返回最新。若省略方向，媒体库的"最近添加"
//     实际显示的是最旧的条目（曾是真实缺陷 §7.2）。

// 未知字段保守返回 Ascending（与 Emby 服务端默认一致）。
func DefaultDirection(f SortField) Direction {
	switch f {
	case SortByDateCreated, SortByCommunityRating, SortByProductionYear,
		SortByRuntime, SortByDatePlayed, SortByPlayCount:
		return Descending
	case SortBySortName:
		return Ascending
	default:
		return Ascending
	}
}

// SortSpec 是一次排序的完整描述。
type SortSpec struct {
	Field     SortField `json:"field"`
	Direction Direction `json:"direction"`
}

// Normalize 补齐方向并加次级键。
//
// 为什么必须加次级键：实测同一天入库的条目主键相同，
// Emby 对相同主键的返回顺序不稳定，翻页时会**重复或漏出**条目。
// 追加 SortName 后顺序确定（对照 plezy `browse.dart:2088` 的多字段写法）。
func (s SortSpec) Normalize() (by string, order string) {
	dir := s.Direction
	if dir == "" {
		dir = DefaultDirection(s.Field)
	}
	field := string(s.Field)
	if field == "" {
		field = string(SortBySortName)
		dir = Ascending
	}
	if field == string(SortBySortName) {
		// 主键已是名称，再加一次是冗余
		return field, string(dir)
	}
	return field + "," + string(SortBySortName),
		string(dir) + "," + string(Ascending)
}

// Less 供本地排序使用（与 Go 侧查询参数无关的离线场景）。
//
// 缺失值一律排到末尾——与 descending 无关。
// 这条规则来自 plezy `media_item_sort.go` 的注释：
// "Missing values always sort last — including under descending"。
// 若把缺失当 0 参与降序，它们会冒到最前面，看起来像"数据错乱"。
func Less(a, b Item, f SortField, d Direction) bool {
	less, aMissing, bMissing := compare(a, b, f)
	if aMissing && bMissing {
		return a.Name < b.Name
	}
	if aMissing {
		return false
	}
	if bMissing {
		return true
	}
	if d == Descending {
		return !less
	}
	return less
}

func compare(a, b Item, f SortField) (less bool, aMissing bool, bMissing bool) {
	switch f {
	case SortBySortName:
		return strings.ToLower(a.Name) < strings.ToLower(b.Name), false, false
	case SortByCommunityRating:
		if a.CommunityRating == nil || b.CommunityRating == nil {
			return false, a.CommunityRating == nil, b.CommunityRating == nil
		}
		return *a.CommunityRating < *b.CommunityRating, false, false
	case SortByProductionYear:
		if a.ProductionYear == nil || b.ProductionYear == nil {
			return false, a.ProductionYear == nil, b.ProductionYear == nil
		}
		return *a.ProductionYear < *b.ProductionYear, false, false
	case SortByRuntime:
		if a.RuntimeTicks == nil || b.RuntimeTicks == nil {
			return false, a.RuntimeTicks == nil, b.RuntimeTicks == nil
		}
		return *a.RuntimeTicks < *b.RuntimeTicks, false, false
	default:
		// 未知字段退化为按名称，保证有确定顺序
		return strings.ToLower(a.Name) < strings.ToLower(b.Name), false, false
	}
}

// SortItems 是 Less 的稳定排序封装（本地场景用）。
func SortItems(items []Item, f SortField, d Direction) {
	sort.SliceStable(items, func(i, j int) bool {
		return Less(items[i], items[j], f, d)
	})
}
