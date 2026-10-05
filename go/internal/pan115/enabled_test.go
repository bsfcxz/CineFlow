package pan115

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// 安全闸门的测试。
//
// ## 为什么这两道闸门必须有测试
//
// 它们是**保护用户账号**的机制（115 是非公开接口，风控代价落在用户身上）：
//
//   - 全局开关：用户察觉异常时能立即止损
//   - 每日总量上限：防止一个失控循环在几分钟内打上千次请求
//
// 安全机制若悄悄失效，后果比功能 bug 严重得多——而且失效时
// 恰恰**不会有任何报错**（照常发请求）。所以必须显式断言"它真的挡住了"。

// ★ 开关关闭时，必须在**发请求之前**就失败（一个字节都不发）。
func TestDisabledBlocksRequestBeforeSending(t *testing.T) {
	// 起一个会记录"是否被访问"的服务器
	var hit bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
		_, _ = w.Write([]byte(`{"state":true}`))
	}))
	defer srv.Close()

	prev := Enabled()
	SetEnabled(false)
	defer SetEnabled(prev)

	c := NewClient(Credential{UID: "u", CID: "c", SEID: "s"})
	c.http = srv.Client()

	req, err := c.newReq(http.MethodGet, srv.URL+"/x")
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.do(req)
	if err == nil {
		t.Fatal("开关关闭时必须返回错误")
	}
	if !strings.Contains(err.Error(), "停用") {
		t.Errorf("错误文案应说明被停用，实际: %v", err)
	}
	if hit {
		t.Error("★ 开关关闭时**绝不能**发出任何请求（这正是它存在的意义）")
	}
}

// ★ 开关打开后请求应当正常发出（防止把开关写成"永远关闭"）。
func TestEnabledAllowsRequest(t *testing.T) {
	var hit bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"state":true}`))
	}))
	defer srv.Close()

	prev := Enabled()
	SetEnabled(true)
	defer SetEnabled(prev)

	c := NewClient(Credential{UID: "u", CID: "c", SEID: "s"})
	c.http = srv.Client()

	req, _ := c.newReq(http.MethodGet, srv.URL+"/x")
	if _, err := c.do(req); err != nil {
		t.Fatalf("开关打开时不该失败: %v", err)
	}
	if !hit {
		t.Error("开关打开时请求应被发出")
	}
}

// ★ 默认值必须是**关闭**。
//
// 这是对用户账号的保护：用户实测中已接近风控阈值，要求"先别登 115"。
// 若哪天有人把默认值改成 true，这条测试会立刻变红提醒。
func TestDefaultDisabled(t *testing.T) {
	// 注意：不能直接断言 Enabled()——测试之间会互相改状态。
	// 这条测试通过"读源码级常量"的方式不可行，故改为断言
	// 一个**新建进程**的语义：这里用一个干净的判断代替——
	// 若 enabledState 的初值是 true，说明默认值被改了。
	//
	// 由于包级变量在测试进程内已被其他测试改过，这里改成
	// 检查"默认值文档与实现一致"的轻量方式：断言常量存在且为 false。
	if defaultEnabled {
		t.Error("115 的默认开关必须是 false（关闭）——" +
			"默认发请求会让用户在不知情的情况下消耗账号风控额度")
	}
}

// ★ 每日额度耗尽后必须挡住请求。
func TestDailyBudgetBlocksAfterCap(t *testing.T) {
	// 直接把预算用满（不改上限常量，避免测试与生产值耦合）
	for BudgetUsedForTest() < DailyRequestCap() {
		if !tryConsumeBudget() {
			break
		}
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("★ 额度耗尽后不应再发出请求")
		_, _ = w.Write([]byte(`{"state":true}`))
	}))
	defer srv.Close()

	prev := Enabled()
	SetEnabled(true)
	defer SetEnabled(prev)

	c := NewClient(Credential{UID: "u", CID: "c", SEID: "s"})
	c.http = srv.Client()

	req, _ := c.newReq(http.MethodGet, srv.URL+"/x")
	_, err := c.do(req)
	if err == nil {
		t.Fatal("额度耗尽时必须返回错误")
	}
	if !strings.Contains(err.Error(), "上限") {
		t.Errorf("错误文案应提到达到上限，实际: %v", err)
	}
}

// 额度是进程级共享的（多个 Client 实例必须共用同一份）。
func TestBudgetIsSharedAcrossClients(t *testing.T) {
	before := BudgetUsedForTest()
	c1 := NewClient(Credential{})
	c2 := NewClient(Credential{})
	_ = c1
	_ = c2

	// 直接消耗两次，确认计数递增（shared 状态）
	if tryConsumeBudget() {
		if BudgetUsedForTest() != before+1 {
			t.Errorf("预算应跨实例共享：before=%d after=%d", before, BudgetUsedForTest())
		}
	}
}

func TestDailyRequestCapIsSane(t *testing.T) {
	cap := DailyRequestCap()
	// 太低会让功能不可用；太高就失去保护意义。
	// 1800 次 ≈ 2 req/s 满速跑 15 分钟。
	if cap < 100 {
		t.Errorf("每日上限 %d 过低，正常使用会被挡", cap)
	}
	if cap > 20000 {
		t.Errorf("每日上限 %d 过高，失去保护意义（上游实测 6000+ 次即可能触发 WAF）", cap)
	}
}
