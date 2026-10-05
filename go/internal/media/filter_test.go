package media

import "testing"

func ptrI(v int) *int         { return &v }
func ptrI64(v int64) *int64   { return &v }
func ptrF(v float64) *float64 { return &v }

// TestIsPlayable 覆盖实测踩过的两类坑：
//  1. `/Latest` 会混入 BoxSet / Folder 等非媒体条目
//  2. 服务端**无视** IncludeItemTypes，只能客户端复筛
func TestIsPlayable(t *testing.T) {
	cases := []struct {
		typ  string
		want bool
	}{
		{"Movie", true},
		{"Episode", true},
		{"Series", true}, // 合法浏览入口，起播时下钻到 Episode
		{"BoxSet", false},
		{"Folder", false},
		{"CollectionFolder", false},
		{"Person", false},
		{"", false},
	}
	for _, c := range cases {
		if got := IsPlayable(Item{Type: c.typ}); got != c.want {
			t.Errorf("IsPlayable(%q) = %v, 期望 %v", c.typ, got, c.want)
		}
	}
}

func TestNormalizeLatest(t *testing.T) {
	in := []Item{
		{ID: "1", Type: "Movie"},
		{ID: "2", Type: "BoxSet"}, // 裸数组里混进来的
		{ID: "3", Type: "Episode"},
		{ID: "4", Type: "Folder"},
	}
	out := NormalizeLatest(in)
	if len(out) != 2 {
		t.Fatalf("应滤剩 2 条，实得 %d", len(out))
	}
	if out[0].ID != "1" || out[1].ID != "3" {
		t.Errorf("顺序/内容不符: %+v", out)
	}
}

func TestNormalizeLatest_EmptyInput(t *testing.T) {
	out := NormalizeLatest(nil)
	if out == nil {
		t.Error("应返回空切片而非 nil（JSON 才会序列化成 []，nil 会变 null）")
	}
	if len(out) != 0 {
		t.Errorf("期望空，实得 %d", len(out))
	}
}

func TestFilterByType(t *testing.T) {
	in := []Item{{ID: "1", Type: "Movie"}, {ID: "2", Type: "Series"}, {ID: "3", Type: "Episode"}}

	if got := FilterByType(in, nil); len(got) != 3 {
		t.Errorf("空筛选应不过滤，实得 %d", len(got))
	}
	if got := FilterByType(in, []string{"Movie"}); len(got) != 1 || got[0].ID != "1" {
		t.Errorf("按 Movie 筛选结果不符: %+v", got)
	}
	if got := FilterByType(in, []string{"Movie", "Episode"}); len(got) != 2 {
		t.Errorf("多类型筛选应得 2 条，实得 %d", len(got))
	}
	// 大小写敏感：Emby 的 Type 是固定帕斯卡命名
	if got := FilterByType(in, []string{"movie"}); len(got) != 0 {
		t.Errorf("应大小写敏感，实得 %d", len(got))
	}
}

// TestDefaultDirection 是缺陷 §7.2 的回归线。
// 曾因省略方向，导致"最近添加"实际返回最旧条目。
func TestDefaultDirection(t *testing.T) {
	cases := map[SortField]Direction{
		SortByDateCreated:     Descending, // ← 关键：不能是 Ascending
		SortByCommunityRating: Descending,
		SortByProductionYear:  Descending,
		SortByRuntime:         Descending,
		SortBySortName:        Ascending,
		"":                    Ascending, // 未知保守
	}
	for f, want := range cases {
		if got := DefaultDirection(f); got != want {
			t.Errorf("DefaultDirection(%q) = %v, 期望 %v", f, got, want)
		}
	}
}

// TestSortSpecNormalize 覆盖"省略方向"与"次级键"两个约束。
func TestSortSpecNormalize(t *testing.T) {
	// 省略方向 → 用字段默认（而非服务端默认）
	by, order := SortSpec{Field: SortByDateCreated}.Normalize()
	if by != "DateCreated,SortName" {
		t.Errorf("应追加次级键，实得 %q", by)
	}
	if order != "Descending,Ascending" {
		t.Errorf("方向应为 Descending,Ascending，实得 %q", order)
	}

	// 显式方向优先
	by, order = SortSpec{Field: SortByDateCreated, Direction: Ascending}.Normalize()
	if order != "Ascending,Ascending" {
		t.Errorf("显式方向应被尊重，实得 %q", order)
	}

	// 主键已是名称 → 不重复追加
	by, order = SortSpec{Field: SortBySortName}.Normalize()
	if by != "SortName" || order != "Ascending" {
		t.Errorf("名称排序不应重复追加，实得 %q / %q", by, order)
	}

	// 空字段 → 退化为名称升序（保证有确定顺序）
	by, order = SortSpec{}.Normalize()
	if by != "SortName" || order != "Ascending" {
		t.Errorf("空字段应退化，实得 %q / %q", by, order)
	}
}

// TestProgress 覆盖实测口径：PlayedPercentage 可能为 null，须有兜底。
func TestProgress(t *testing.T) {
	// 已播完优先
	if p := Progress(Item{Played: true}); p != 1 {
		t.Errorf("已播完应为 1，实得 %v", p)
	}
	// 服务端显式百分比（0~100 → 0~1）
	if p := Progress(Item{PlayedPercentage: ptrF(34)}); p < 0.33 || p > 0.35 {
		t.Errorf("34%% 应约 0.34，实得 %v", p)
	}
	// 百分比缺失 → 用 ticks 兜底
	if p := Progress(Item{PositionTicks: ptrI64(50 * 10_000_000), RuntimeTicks: ptrI64(100 * 10_000_000)}); p != 0.5 {
		t.Errorf("ticks 兜底应得 0.5，实得 %v", p)
	}
	// 全缺失 → 0（不 panic）
	if p := Progress(Item{}); p != 0 {
		t.Errorf("无数据应为 0，实得 %v", p)
	}
	// RunTimeTicks 为 0 → 不能除零
	if p := Progress(Item{PositionTicks: ptrI64(100), RuntimeTicks: ptrI64(0)}); p != 0 {
		t.Errorf("运行时长为 0 应得 0，实得 %v", p)
	}
	// 百分比越界要夹到 1
	if p := Progress(Item{PlayedPercentage: ptrF(150)}); p != 1 {
		t.Errorf("越界应夹到 1，实得 %v", p)
	}
}

// TestCompleted 锁定 95% 阈值口径（详情页与播放器必须一致）。
func TestCompleted(t *testing.T) {
	cases := []struct {
		name string
		it   Item
		want bool
	}{
		{"显式已看", Item{Played: true}, true},
		{"百分比 96%", Item{PlayedPercentage: ptrF(96)}, true},
		{"百分比 94%", Item{PlayedPercentage: ptrF(94)}, false},
		{"ticks 恰好 95%", Item{
			PositionTicks: ptrI64(95), RuntimeTicks: ptrI64(100),
		}, true},
		{"ticks 94.9%", Item{
			PositionTicks: ptrI64(949), RuntimeTicks: ptrI64(1000),
		}, false},
		{"无数据", Item{}, false},
	}
	for _, c := range cases {
		if got := Completed(c.it); got != c.want {
			t.Errorf("%s: Completed = %v, 期望 %v", c.name, got, c.want)
		}
	}
}

func TestRemainingMinutes(t *testing.T) {
	// 100 分钟片，看了 34% → 剩 66 分钟
	it := Item{
		RuntimeTicks:     ptrI64(100 * 60 * 10_000_000),
		PlayedPercentage: ptrF(34),
	}
	if got := RemainingMinutes(it); got != 66 {
		t.Errorf("应剩 66 分钟，实得 %d", got)
	}
	// 已看完 → 0
	if got := RemainingMinutes(Item{Played: true, RuntimeTicks: ptrI64(100)}); got != 0 {
		t.Errorf("看完应剩 0，实得 %d", got)
	}
	// 无时长 → 0
	if got := RemainingMinutes(Item{}); got != 0 {
		t.Errorf("无时长应得 0，实得 %d", got)
	}
}

// TestLess_MissingSortsLast 锁定"缺失值恒排末尾"（含降序）。
// 若把缺失当 0 参与降序，它们会冒到最前，看起来像数据错乱。
func TestLess_MissingSortsLast(t *testing.T) {
	withRating := Item{ID: "a", Name: "A", CommunityRating: ptrF(5)}
	noRating := Item{ID: "b", Name: "B"}

	for _, dir := range []Direction{Ascending, Descending} {
		if !Less(withRating, noRating, SortByCommunityRating, dir) {
			t.Errorf("%v 方向：有值应排在无值之前", dir)
		}
		if Less(noRating, withRating, SortByCommunityRating, dir) {
			t.Errorf("%v 方向：无值不应排在有值之前", dir)
		}
	}
}

func TestSortItems_Deterministic(t *testing.T) {
	items := []Item{
		{ID: "1", Name: "b"},
		{ID: "2", Name: "a"},
		{ID: "3", Name: "c"},
	}
	SortItems(items, SortBySortName, Ascending)
	got := []string{items[0].Name, items[1].Name, items[2].Name}
	want := []string{"a", "b", "c"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("排序结果 %v，期望 %v", got, want)
		}
	}
}
