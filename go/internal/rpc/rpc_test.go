// Package rpc 的单元测试。
//
// 关键：本包**零 cgo 依赖**，因此 `go test ./internal/rpc` 在任何环境
// （包括无 C 编译器的机器、CI 默认 CGO_ENABLED=0）都能跑。
// 这是把路由逻辑从含 `import "C"` 的 main 包拆出来的直接收益。
package rpc

import (
	"encoding/json"
	"testing"

	"cineflow/go/internal/media"
)

// call 跑一次 Dispatch 并解码信封。
//
// 走 Dispatch 而不是 CineFlowCall：后者涉及 C 堆分配/释放，
// 而这里要验证的是**路由与信封形状**。cgo 边界的正确性由真机验证覆盖
// （logcat 已确认 ping 往返 {pong: cineflow-go, version: 1}）。
func call(t *testing.T, method string, req Request) Response {
	t.Helper()
	payload := ""
	if b, err := json.Marshal(req); err == nil {
		payload = string(b)
	}
	var resp Response
	if err := json.Unmarshal([]byte(Dispatch(method, payload)), &resp); err != nil {
		t.Fatalf("返回信封不是合法 JSON: %v", err)
	}
	return resp
}

func TestDispatch_UnknownMethod(t *testing.T) {
	resp := call(t, "no.such.method", Request{})
	if resp.Ok {
		t.Error("未知方法应返回 ok=false")
	}
	if resp.Error == "" {
		t.Error("未知方法应带错误信息")
	}
}

func TestDispatch_SystemVersion(t *testing.T) {
	resp := call(t, "system.version", Request{})
	if !resp.Ok {
		t.Fatalf("应成功，实得 %s", resp.Error)
	}
	var out map[string]string
	if err := json.Unmarshal(resp.Result, &out); err != nil {
		t.Fatalf("结果解析失败: %v", err)
	}
	if out["bridge"] != BridgeVersion {
		t.Errorf("bridge = %q，期望 %q", out["bridge"], BridgeVersion)
	}
}

// TestDispatch_EchoRoundTrip 证明结构体能原样穿过 JSON 边界（含中文）。
func TestDispatch_EchoRoundTrip(t *testing.T) {
	resp := call(t, "system.echo", Request{
		Items: []media.Item{{ID: "x1", Name: "中文名"}},
		Types: []string{"Movie"},
	})
	if !resp.Ok {
		t.Fatalf("应成功，实得 %s", resp.Error)
	}
	var out struct {
		Echo Request `json:"echo"`
	}
	if err := json.Unmarshal(resp.Result, &out); err != nil {
		t.Fatalf("结果解析失败: %v", err)
	}
	if len(out.Echo.Items) != 1 || out.Echo.Items[0].Name != "中文名" {
		t.Errorf("中文往返失败: %+v", out.Echo.Items)
	}
}

func TestDispatch_NormalizeLatest(t *testing.T) {
	resp := call(t, "media.normalizeLatest", Request{
		Items: []media.Item{
			{ID: "1", Type: "Movie"},
			{ID: "2", Type: "BoxSet"}, // 裸数组里混进来的
		},
	})
	if !resp.Ok {
		t.Fatalf("应成功，实得 %s", resp.Error)
	}
	var out struct {
		Count int `json:"count"`
	}
	if err := json.Unmarshal(resp.Result, &out); err != nil {
		t.Fatalf("结果解析失败: %v", err)
	}
	if out.Count != 1 {
		t.Errorf("应滤剩 1 条，实得 %d", out.Count)
	}
}

// TestDispatch_SortParams 是缺陷 §7.2 的跨语言回归线：
// 省略方向时必须补成 Descending（不能依赖服务端默认，那会返回最旧）。
func TestDispatch_SortParams(t *testing.T) {
	resp := call(t, "media.sortParams", Request{Field: media.SortByDateCreated})
	if !resp.Ok {
		t.Fatalf("应成功，实得 %s", resp.Error)
	}
	var out map[string]string
	if err := json.Unmarshal(resp.Result, &out); err != nil {
		t.Fatalf("结果解析失败: %v", err)
	}
	if out["sortBy"] != "DateCreated,SortName" {
		t.Errorf("sortBy = %q，期望带次级键", out["sortBy"])
	}
	if out["sortOrder"] != "Descending,Ascending" {
		t.Errorf("sortOrder = %q，期望 Descending,Ascending", out["sortOrder"])
	}
}

// TestDispatch_SortParams_ExplicitSpec 显式 spec 优先于 field。
func TestDispatch_SortParams_ExplicitSpec(t *testing.T) {
	resp := call(t, "media.sortParams", Request{
		Field: media.SortByDateCreated, // 会被 spec 覆盖
		Spec: &media.SortSpec{
			Field:     media.SortBySortName,
			Direction: media.Ascending,
		},
	})
	if !resp.Ok {
		t.Fatalf("应成功，实得 %s", resp.Error)
	}
	var out map[string]string
	if err := json.Unmarshal(resp.Result, &out); err != nil {
		t.Fatalf("结果解析失败: %v", err)
	}
	if out["sortBy"] != "SortName" {
		t.Errorf("spec 应优先，实得 sortBy=%q", out["sortBy"])
	}
}

func TestDispatch_FilterByType(t *testing.T) {
	resp := call(t, "media.filterByType", Request{
		Items: []media.Item{
			{ID: "1", Type: "Movie"},
			{ID: "2", Type: "Series"},
		},
		Types: []string{"Movie"},
	})
	if !resp.Ok {
		t.Fatalf("应成功，实得 %s", resp.Error)
	}
	var out struct {
		Count int `json:"count"`
	}
	if err := json.Unmarshal(resp.Result, &out); err != nil {
		t.Fatalf("结果解析失败: %v", err)
	}
	if out.Count != 1 {
		t.Errorf("按 Movie 筛应得 1 条，实得 %d", out.Count)
	}
}

func TestDispatch_Progress_EmptyItems(t *testing.T) {
	resp := call(t, "media.progress", Request{})
	if resp.Ok {
		t.Error("没有 item 时应报错，而不是返回零值")
	}
}

func TestDispatch_Progress(t *testing.T) {
	resp := call(t, "media.progress", Request{
		Items: []media.Item{{ID: "1", Type: "Movie"}},
	})
	if !resp.Ok {
		t.Fatalf("应成功，实得 %s", resp.Error)
	}
	var out map[string]any
	if err := json.Unmarshal(resp.Result, &out); err != nil {
		t.Fatalf("结果解析失败: %v", err)
	}
	if out["playable"] != true {
		t.Errorf("Movie 应可播，实得 %v", out["playable"])
	}
}

func TestParseRequest_EmptyIsNotError(t *testing.T) {
	if _, err := ParseRequest(""); err != nil {
		t.Errorf("空 payload 不应报错，实得 %v", err)
	}
}

func TestParseRequest_InvalidJSON(t *testing.T) {
	if _, err := ParseRequest("{not json"); err == nil {
		t.Error("非法 JSON 应报错")
	}
}

// TestDispatch_MalformedItemsShape 锁定"非法入参返回错误信封而非崩溃"。
// items 传成字符串而非数组。
func TestDispatch_MalformedItemsShape(t *testing.T) {
	var resp Response
	if err := json.Unmarshal(
		[]byte(Dispatch("media.normalizeLatest", `{"items":"not-an-array"}`)),
		&resp,
	); err != nil {
		t.Fatalf("信封本身必须是合法 JSON: %v", err)
	}
	if resp.Ok {
		t.Error("非法 items 形状应返回错误信封")
	}
}
