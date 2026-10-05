package rpc

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// TestLivePan115QRFlow 直接打**真实 115 接口**验证整条 Go 侧链路。
//
// ## 为什么必须存在这个测试
//
// 单测用 httptest 只能证明"我按我以为的形状解析正确"，
// **不能证明服务端真的那样返回**。而扫码轮询这条路上有一堆
// "解析成功但语义错了"的坑（如 data 为空对象、state 是数字、长轮询超时），
// 这些只有打真实接口才暴露。
//
// ## 为什么默认跳过
//
// 它会发真实网络请求、并且**一次轮询要等约 30 秒**（服务端长轮询）。
// 放进默认 `go test ./...` 会让每次跑测试都慢半分钟，且依赖外网可达——
// 那会让 CI 变脆。故用环境变量显式开启：
//
//	CF_LIVE_115=1 go test ./internal/rpc -run TestLivePan115QRFlow -v -timeout 3m
func TestLivePan115QRFlow(t *testing.T) {
	if os.Getenv("CF_LIVE_115") == "" {
		t.Skip("跳过真实网络测试；设 CF_LIVE_115=1 开启")
	}

	// ① 申请二维码 —— 走与生产完全相同的 Dispatch 入口
	startRaw := Dispatch("pan115.qr.start", "")
	t.Logf("qr.start 原始响应: %s", startRaw)

	var startResp struct {
		OK     bool   `json:"ok"`
		Error  string `json:"error"`
		Result struct {
			UID      string `json:"uid"`
			Time     int64  `json:"time"`
			Sign     string `json:"sign"`
			QRCode   string `json:"qrcode"`
			ImageURL string `json:"imageUrl"`
		} `json:"result"`
	}
	if err := json.Unmarshal([]byte(startRaw), &startResp); err != nil {
		t.Fatalf("qr.start 响应不是合法 JSON: %v", err)
	}
	if !startResp.OK {
		t.Fatalf("qr.start 失败: %s", startResp.Error)
	}
	s := startResp.Result
	if s.UID == "" || s.Sign == "" {
		t.Fatalf("qr.start 返回缺少 uid/sign: %+v", s)
	}
	t.Logf("✅ qr.start 成功 uid=%s… time=%d sign 长度=%d",
		s.UID[:min(12, len(s.UID))], s.Time, len(s.Sign))

	// ② 轮询 —— 这里是用户遇到问题的环节。
	// 必须把 uid/time/sign 按 Dart 侧完全相同的字段名传回去，
	// 否则就在测一个不存在的路径（Dart 侧发的键名就是这三个）。
	payload := `{"uid":"` + s.UID + `","time":` +
		jsonInt(s.Time) + `,"sign":"` + s.Sign + `"}`

	t.Log("开始轮询（服务端长轮询，预计等约 30 秒）…")
	began := time.Now()
	pollRaw := Dispatch("pan115.qr.poll", payload)
	elapsed := time.Since(began)
	t.Logf("qr.poll 耗时 %v，原始响应: %s", elapsed.Round(time.Millisecond), pollRaw)

	var pollResp struct {
		OK     bool   `json:"ok"`
		Error  string `json:"error"`
		Result struct {
			Status   int    `json:"status"`
			Label    string `json:"label"`
			Terminal bool   `json:"terminal"`
			Allowed  bool   `json:"allowed"`
		} `json:"result"`
	}
	if err := json.Unmarshal([]byte(pollRaw), &pollResp); err != nil {
		t.Fatalf("qr.poll 响应不是合法 JSON: %v", err)
	}

	// ★ 这条断言就是用户报的问题：
	// UI 显示"等待二维码…"说明 Dart 侧拿到的 ok=false（或解析失败）。
	// 若这里 ok=true，说明 Go 侧是好的，问题在 Dart/FFI 层。
	if !pollResp.OK {
		t.Fatalf("❌ qr.poll 失败（这会导致 UI 一直显示「等待二维码…」）: %s",
			pollResp.Error)
	}
	t.Logf("✅ qr.poll 成功 status=%d label=%q terminal=%v allowed=%v",
		pollResp.Result.Status, pollResp.Result.Label,
		pollResp.Result.Terminal, pollResp.Result.Allowed)

	// 未扫码时应是"等待"且非终态、不可换凭据
	if pollResp.Result.Status != 0 {
		t.Logf("注意：未扫码时 status=%d（预期 0=等待）", pollResp.Result.Status)
	}
	if pollResp.Result.Terminal {
		t.Error("未扫码不应是终态，否则 UI 会停止轮询")
	}
	if pollResp.Result.Allowed {
		t.Error("未扫码不应 allowed，否则会误调 login（可能返回误导性的「老乡验证失败」）")
	}
	if pollResp.Result.Label == "" {
		t.Error("label 为空会让 UI 无法显示状态")
	}

	// ★ 关键一步：若扫码已确认（status==2），就走完 login 并**打印真实响应形状**。
	//
	// 这一步存在的理由是一个真实缺陷：`data.cookie` 的字段名与我原先
	// 按上游源码写的形状**对不上**，导致 Dart 侧拿到空凭据
	// （症状：登录卡在最后一步，日志显示 uid=false cid=false…）。
	// 而"解析出零值"不会报错——只有把**原始响应打出来**才能看到真实形状。
	if pollResp.Result.Status == 2 || pollResp.Result.Allowed {
		loginRaw := Dispatch("pan115.qr.finish", payload)
		t.Logf("★ qr.finish 原始响应: %s", loginRaw)

		var loginResp struct {
			OK    bool   `json:"ok"`
			Error string `json:"error"`
		}
		_ = json.Unmarshal([]byte(loginRaw), &loginResp)
		if !loginResp.OK {
			t.Errorf("qr.finish 失败: %s", loginResp.Error)
		} else {
			t.Log("✅ qr.finish 成功（凭据已取得；值不打印）")
		}
	} else {
		t.Log("未确认扫码，跳过 login 步骤（无法观测成功响应形状）")
	}

	// ③ 顺带确认二维码图片端点真的返回 PNG（Dart 侧直接 Image.network 用它）
	req, err := sessions.get("default").NewReqForTest("GET", s.ImageURL)
	if err != nil {
		t.Fatalf("构造图片请求失败: %v", err)
	}
	imgBody, ctype, err := sessions.get("default").FetchBytesForTest(req)
	if err != nil {
		t.Fatalf("拉取二维码图片失败: %v", err)
	}
	if !strings.HasPrefix(ctype, "image/") {
		t.Errorf("二维码端点 Content-Type=%q（预期 image/*）", ctype)
	}
	if len(imgBody) < 100 {
		t.Errorf("二维码图片只有 %d 字节，可疑", len(imgBody))
	}
	// PNG 魔数
	if len(imgBody) >= 4 && !(imgBody[0] == 0x89 && imgBody[1] == 0x50) {
		t.Errorf("二维码图片不是 PNG（前 4 字节 % X）", imgBody[:4])
	}
	t.Logf("✅ 二维码图片 %d 字节，Content-Type=%s（Dart 侧可 Image.network 直用）",
		len(imgBody), ctype)
}

func jsonInt(v int64) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
