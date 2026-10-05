package pan115

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// 用 httptest 而不是打真实 115 接口：单元测试必须可离线、
// 可重复、且不碰用户账号。真实端点可达性由独立的手工探针确认（见 AGENTS.md）。

func TestQRStatusLabelAndTerminal(t *testing.T) {
	cases := []struct {
		st       QRStatus
		terminal bool
		label    string
	}{
		{QRWaiting, false, "请用 115 App 扫码"},
		{QRScanned, false, "已扫码，请在手机上确认登录"},
		{QRAllowed, true, "已确认，正在登录…"},
		{QRExpired, true, "二维码已过期，请刷新"},
		{QRCanceled, true, "已取消登录"},
	}
	for _, c := range cases {
		if got := c.st.Terminal(); got != c.terminal {
			t.Errorf("QRStatus(%d).Terminal() = %v, want %v", c.st, got, c.terminal)
		}
		if got := c.st.Label(); got != c.label {
			t.Errorf("QRStatus(%d).Label() = %q, want %q", c.st, got, c.label)
		}
	}
}

// ★ 未知状态必须当作"等待"而不是报错。
// 若当成错误，115 将来新增一个状态值就会让登录流程直接中断。
func TestUnknownQRStatusIsNotFatal(t *testing.T) {
	var st QRStatus = 99
	if st.Terminal() {
		t.Error("未知状态不应被视为终态（否则登录会中断）")
	}
	if !strings.Contains(st.Label(), "未知") {
		t.Errorf("未知状态应给出可读描述，得到 %q", st.Label())
	}
}

func TestQRSessionImageURL(t *testing.T) {
	s := QRSession{UID: "abc123"}
	want := URLQRImage + "?uid=abc123"
	if got := s.ImageURL(); got != want {
		t.Errorf("ImageURL() = %q, want %q", got, want)
	}
}

// ★ 实测确认的差异：二维码体系 state 是数字 1，webapi 体系是 true。
// 用 *bool 反序列化数字会整体报错，直接导致登录失败。
func TestEnvelopeStateFlexibleNumericAndBoolean(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{"二维码 state=1（数字）", `{"state":1,"code":0,"data":{}}`, true},
		{"二维码 state=0（数字）", `{"state":0,"code":0}`, false},
		{"webapi state=true", `{"state":true}`, true},
		{"webapi state=false", `{"state":false,"errno":990001}`, false},
		{"state 缺失", `{"data":{}}`, true},
		{"state=null", `{"state":null,"data":{}}`, true},
	}
	for _, c := range cases {
		var env envelope
		if err := json.Unmarshal([]byte(c.body), &env); err != nil {
			t.Fatalf("%s: 反序列化失败（这正是要防的缺陷）: %v", c.name, err)
		}
		if got := env.OK(); got != c.want {
			t.Errorf("%s: OK() = %v, want %v", c.name, got, c.want)
		}
	}
}

// errno 与 errNo 两种拼写都出现过，都要能读到。
func TestEnvelopeErrnoBothSpellings(t *testing.T) {
	for _, body := range []string{
		`{"state":false,"errno":990001,"error":"登录超时"}`,
		`{"state":false,"errNo":990001,"error":"登录超时"}`,
	} {
		var env envelope
		if err := json.Unmarshal([]byte(body), &env); err != nil {
			t.Fatalf("反序列化失败: %v", err)
		}
		if got := env.errnoOf(); got != ErrnoLoginExpired {
			t.Errorf("errnoOf() = %d, want %d（body=%s）", got, ErrnoLoginExpired, body)
		}
		if env.OK() {
			t.Error("errno≠0 时 OK() 必须为 false")
		}
	}
}

// ★ 登录过期类错误必须标记 NeedsQR（重试无意义）。
// 带着失效凭据反复重试会触发风控，可能导致授权被永久标记失效。
func TestNeedsReloginClassification(t *testing.T) {
	mustRelogin := []int{ErrnoLoginExpired, ErrnoNotLoggedIn, ErrnoNeedVerify}
	for _, e := range mustRelogin {
		if !needsRelogin(e) {
			t.Errorf("errno %d 应当要求重新登录（否则会无限重试）", e)
		}
	}
	// 普通错误不应要求重新登录——否则用户会被无谓地踢去扫码
	for _, e := range []int{0, 500, 1001} {
		if needsRelogin(e) {
			t.Errorf("errno %d 不应要求重新登录", e)
		}
	}
}

// ★ Cookie 四项缺一不可，且顺序固定。
// 缺 SEID 会 401；缺 CID 更危险——会拿到空列表（表现为"网盘是空的"而非报错）。
func TestCredentialCookie(t *testing.T) {
	full := Credential{UID: "u", CID: "c", SEID: "s", KID: "k"}
	if got, want := full.Cookie(), "UID=u; CID=c; SEID=s; KID=k"; got != want {
		t.Errorf("Cookie() = %q, want %q", got, want)
	}
	if !full.Valid() {
		t.Error("四项齐全时 Valid() 应为 true")
	}

	// 缺 SEID → 无效
	if (Credential{UID: "u", CID: "c"}).Valid() {
		t.Error("缺 SEID 时 Valid() 应为 false（否则会 401）")
	}
	// 缺 CID → 无效（这条尤其重要：缺 CID 不报错，只是列表为空）
	if (Credential{UID: "u", SEID: "s"}).Valid() {
		t.Error("缺 CID 时 Valid() 应为 false（否则会静默返回空列表）")
	}
	// KID 可缺省，不应影响有效性
	if !(Credential{UID: "u", CID: "c", SEID: "s"}).Valid() {
		t.Error("KID 缺失不应导致凭据无效")
	}
}

// ★ 固定 UA：取地址与播放必须一致，改 UA 会让已发出的直链失效。
func TestUserAgentIsStableAndNonEmpty(t *testing.T) {
	if DefaultUA == "" {
		t.Fatal("DefaultUA 不能为空（否则请求会被 WAF 拦）")
	}
	c := NewClient(Credential{})
	if c.UserAgent() != DefaultUA {
		t.Errorf("UserAgent() = %q, want %q", c.UserAgent(), DefaultUA)
	}
	// 断言它看起来像个浏览器/客户端 UA，而不是被误改成"Go-http-client"
	if strings.Contains(DefaultUA, "Go-http-client") {
		t.Error("UA 不能是 Go 默认值：115 的 CDN 直链与取地址时的 UA 强绑定")
	}
}

func TestClientCredentialRoundTrip(t *testing.T) {
	c := NewClient(Credential{})
	if c.LoggedIn() {
		t.Error("零值凭据时不应视为已登录")
	}
	cred := Credential{UID: "u", CID: "c", SEID: "s", KID: "k"}
	c.SetCredential(cred)
	if !c.LoggedIn() {
		t.Error("设置完整凭据后应视为已登录")
	}
	if got := c.Credential(); got.UID != "u" || got.CID != "c" {
		t.Errorf("Credential() = %+v, want 与设置值一致", got)
	}
}

// ---------------- 用 httptest 覆盖各响应形状 ----------------

// newTestClient 让客户端打到 httptest 服务器。
//
// ⚠️ 必须显式打开全局开关：本项目默认**停用** 115（防止误触发风控，
// 见 enabled.go）。但单元测试打的是**本地 httptest**，
// 一个字节都不会到 115——所以测试里要打开，否则 do() 会在
// 发请求前就被开关拦下，导致一堆与测试意图无关的失败。
func newTestClient(t *testing.T, handler http.HandlerFunc) (*Client, *httptest.Server) {
	t.Helper()
	// 保存并恢复，避免测试之间互相影响（Go 测试默认同包串行，
	// 但显式恢复能防止将来并行化时出问题）。
	prev := Enabled()
	SetEnabled(true)
	ResetBudgetForTest()
	t.Cleanup(func() {
		SetEnabled(prev)
		ResetBudgetForTest()
	})

	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	c := NewClient(Credential{})
	c.http = srv.Client()
	return c, srv
}

func TestRequestQRCodeParsesRealShape(t *testing.T) {
	// 这是 2026-10-05 实测抓到的真实响应形状（uid/sign 已改成假值）
	const realBody = `{"state":1,"code":0,"message":"","data":{"uid":"testuid123",` +
		`"time":1791102171,"sign":"165bf9f6a8a2bf4e44315c7d65e3900c",` +
		`"qrcode":"https://115.com/scan/dg-testuid123"}}`

	c, srv := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		// 二维码请求不应带 cookie
		if r.Header.Get("Cookie") != "" {
			t.Errorf("申请二维码时不应带 cookie，实际: %q", r.Header.Get("Cookie"))
		}
		if r.Header.Get("User-Agent") == "" {
			t.Error("必须带 User-Agent（否则会被 WAF 拦）")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(realBody))
	})

	// 让 newReq 指向 httptest：替换 URL 常量不便，故直接构造请求走 do()
	req, err := http.NewRequest(http.MethodGet, srv.URL+"/token", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("User-Agent", DefaultUA)
	env, err := c.do(req)
	if err != nil {
		t.Fatalf("do() 失败: %v", err)
	}
	if !env.OK() {
		t.Fatal("真实响应形状应被判定为成功")
	}
	var s QRSession
	if err := json.Unmarshal(env.Data, &s); err != nil {
		t.Fatalf("解析 QRSession 失败: %v", err)
	}
	if s.UID != "testuid123" {
		t.Errorf("UID = %q, want testuid123", s.UID)
	}
	if s.Time != 1791102171 {
		t.Errorf("Time = %d, want 1791102171", s.Time)
	}
	if s.Sign == "" || s.QRCode == "" {
		t.Error("sign 与 qrcode 都应被解析出来")
	}
}

// ★ 长轮询下"状态未变"返回空 data，这必须被当成"继续等待"而不是错误。
// 这是最高频的返回分支，处理错会让登录流程在第一秒就失败。
func TestPollEmptyDataMeansStillWaiting(t *testing.T) {
	for _, body := range []string{
		`{"state":1,"code":0,"message":"","data":{}}`, // 实测形状
		`{"state":1,"code":0,"data":null}`,
		`{"state":1,"code":0}`,
	} {
		var env envelope
		if err := json.Unmarshal([]byte(body), &env); err != nil {
			t.Fatalf("解析失败: %v", err)
		}
		if !env.OK() {
			t.Errorf("空 data 不应被判为失败: %s", body)
		}
		trimmed := strings.TrimSpace(string(env.Data))
		if trimmed != "" && trimmed != "{}" && trimmed != "null" {
			t.Errorf("期望识别为空 data，实际 %q（body=%s）", trimmed, body)
		}
	}
}

func TestPollStatusValueParsing(t *testing.T) {
	cases := map[string]QRStatus{
		`{"state":1,"code":0,"data":{"status":0}}`:  QRWaiting,
		`{"state":1,"code":0,"data":{"status":1}}`:  QRScanned,
		`{"state":1,"code":0,"data":{"status":2}}`:  QRAllowed,
		`{"state":1,"code":0,"data":{"status":-1}}`: QRExpired,
		`{"state":1,"code":0,"data":{"status":-2}}`: QRCanceled,
		`{"state":1,"code":0,"data":{"status":77}}`: QRWaiting, // 未知 → 等待
	}
	for body, want := range cases {
		var env envelope
		if err := json.Unmarshal([]byte(body), &env); err != nil {
			t.Fatalf("解析失败: %v", err)
		}
		var st struct {
			Status int `json:"status"`
		}
		if err := json.Unmarshal(env.Data, &st); err != nil {
			t.Fatalf("解析 status 失败: %v", err)
		}
		got := QRStatus(st.Status)
		switch got {
		case QRWaiting, QRScanned, QRAllowed, QRExpired, QRCanceled:
			// 已知取值，正常
		default:
			got = QRWaiting
		}
		if got != want {
			t.Errorf("body=%s: got %d, want %d", body, got, want)
		}
	}
}

// ★ 凭据解析要兼容两种嵌套形状（上游源码用 {cookie:{...}}，
// 但不同版本出现过顶层直接就是凭据的情况）。
func TestParseCredentialBothShapes(t *testing.T) {
	wrapped := json.RawMessage(`{"cookie":{"UID":"u1","CID":"c1","SEID":"s1","KID":"k1"}}`)
	got, err := parseCredential(wrapped)
	if err != nil {
		t.Fatalf("解析 {cookie:{...}} 失败: %v", err)
	}
	if got.UID != "u1" || got.CID != "c1" || got.SEID != "s1" || got.KID != "k1" {
		t.Errorf("嵌套形状解析错误: %+v", got)
	}

	direct := json.RawMessage(`{"UID":"u2","CID":"c2","SEID":"s2"}`)
	got2, err := parseCredential(direct)
	if err != nil {
		t.Fatalf("解析顶层形状失败: %v", err)
	}
	if got2.UID != "u2" || got2.CID != "c2" || got2.SEID != "s2" {
		t.Errorf("顶层形状解析错误: %+v", got2)
	}

	if _, err := parseCredential(json.RawMessage(`{}`)); err != nil {
		// 空对象解析成零值凭据是可以的；由调用方用 Valid() 判定
		t.Logf("空对象解析: %v", err)
	}
}

// ★ WAF 拦截必须给出可操作的提示，而不是把 HTML 当 JSON 报"解析失败"。
//
// 两类要分开提示（这是取证结论带来的改进）：
//   - A 类（小写 doctypehtml 的 405）通常由"漏带 UID cookie"引起
//     → 提示应指向"检查登录状态"
//   - B 类（WAF 品牌页 / HTTP 418）是真风控 → 只能退避等待
func TestWAFInterceptionDetected(t *testing.T) {
	// A 类
	c, srv := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusMethodNotAllowed)
		_, _ = w.Write([]byte(`<!doctypehtml><html lang="zh-cn"><title>405</title>` +
			`<div>很抱歉，由于您访问的URL有可能对网站造成安全威胁，您的访问被阻断。</div>`))
	})
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/files", nil)
	_, err := c.do(req)
	if err == nil {
		t.Fatal("WAF 拦截必须返回错误")
	}
	if msg := err.Error(); !strings.Contains(msg, "登录") {
		t.Errorf("A 类应提示检查登录状态（主因是漏带 cookie），实际: %v", msg)
	}

	// B 类：WAF 品牌页 → 应提示风控/退避
	c2, srv2 := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot) // 418，上游实测的限流响应码
		_, _ = w.Write([]byte(`<!DOCTYPE html><html><title>阿里云 Web应用防火墙</title></html>`))
	})
	req2, _ := http.NewRequest(http.MethodGet, srv2.URL+"/files", nil)
	_, err2 := c2.do(req2)
	if err2 == nil {
		t.Fatal("418 WAF 必须返回错误")
	}
	if msg := err2.Error(); !strings.Contains(msg, "风控") {
		t.Errorf("B 类应提示风控，实际: %v", msg)
	}
}

func TestLooksLikeWAF(t *testing.T) {
	yes := [][]byte{
		[]byte(`<!doctypehtml><html>`),
		[]byte(`<html><body>blocked</body></html>`),
		[]byte(`很抱歉，由于您访问的URL有可能对网站造成安全威胁，您的访问被阻断。`),
	}
	for _, b := range yes {
		if !looksLikeWAF(b) {
			t.Errorf("应识别为 WAF 拦截: %s", string(b[:min(40, len(b))]))
		}
	}
	no := [][]byte{
		[]byte(`{"state":false,"error":"请先登录"}`),
		[]byte(``),
	}
	for _, b := range no {
		if looksLikeWAF(b) {
			t.Errorf("不应识别为 WAF 拦截: %s", string(b))
		}
	}
}

// 业务错误（HTTP 200 + state=false）必须被识别，否则"未登录"会被当成"网盘为空"。
func TestBusinessErrorInsideHTTP200(t *testing.T) {
	c, srv := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		// 实测形状：未登录时 aps.115.com 返回这个
		_, _ = w.Write([]byte(`{"state":false,"error":"请先登录"}`))
	})
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/files", nil)
	env, err := c.do(req)
	if err != nil {
		t.Fatalf("HTTP 200 不应返回传输层错误: %v", err)
	}
	if env.OK() {
		t.Error("state=false 必须被判为失败（否则会静默返回空列表）")
	}
	if env.text() != "请先登录" {
		t.Errorf("错误文案 = %q, want 请先登录", env.text())
	}
}

func TestAnyToString(t *testing.T) {
	cases := []struct {
		in   any
		want string
	}{
		{nil, ""},
		{"abc", "abc"},
		{float64(12345678), "12345678"}, // 不能出现科学计数法
		{float64(1.5), "1"},
		{true, "true"},
		{false, "false"},
	}
	for _, c := range cases {
		if got := anyToString(c.in); got != c.want {
			t.Errorf("anyToString(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
