package pan115

import (
	"encoding/json"
	"net/http"
	"testing"
)

// 账号信息解析的**形状容错**测试。
//
// ## 这个测试针对一个真实缺陷
//
// 实测 `my.115.com/?ct=ajax&ac=nav` 返回的 `face` 字段是**字符串**，
// 而文档/上游源码里是 `{face_s, face_m, face_l}` **对象**。
// 我原先用一个大 struct 整体 Unmarshal，于是：
//
//	json: cannot unmarshal string into Go struct field .face of type struct {...}
//
// **整个账号信息解析失败** → 拿不到用户名/VIP/容量 → UI 判定"未登录"。
//
// 一个**装饰性字段**（头像）搞挂了登录状态判定，这是最典型的
// "服务端字段形状不可信"问题（AGENTS.md §5.3）。
//
// 修法：逐字段用宽容类型取，坏字段只影响它自己。

// fetchInfoWithBody 用给定响应体构造一个假的 user.info 调用。
func fetchInfoWithBody(t *testing.T, body string) (UserInfo, error) {
	t.Helper()
	c, srv := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	})
	// 让 newReq 指向 httptest：临时替换 URL 不可行，故直接走 do() 的等价路径。
	// 这里用 FetchUserInfo 需要 URLUserInfo，所以改用较低层的验证方式：
	// 直接解析我们关心的形状（解析逻辑本身经 parseUserInfo 复用）。
	_ = c
	_ = srv

	var env envelope
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		return UserInfo{}, err
	}
	if !env.OK() {
		return UserInfo{}, newErr(env.errnoOf(), env.text())
	}
	return parseUserInfo(env.Data)
}

// ★ face 是字符串时必须仍能取到其它字段（真实缺陷的回归线）。
func TestUserInfoToleratesFaceAsString(t *testing.T) {
	// 实测形状：face 是字符串
	body := `{"state":true,"data":{
		"user_id":12345,"user_name":"测试用户","face":"https://avatar.115.com/x.jpg",
		"vip_info":{"level_name":"VIP","expire":1791100000},
		"rt_space_info":{"all_total":{"size":1099511627776},"all_use":{"size":549755813888}}
	}}`
	info, err := fetchInfoWithBody(t, body)
	if err != nil {
		t.Fatalf("face 为字符串时不该解析失败（这正是 bug）: %v", err)
	}
	if info.UserName != "测试用户" {
		t.Errorf("UserName = %q", info.UserName)
	}
	if info.FaceSmall != "https://avatar.115.com/x.jpg" {
		t.Errorf("FaceSmall = %q（字符串形状应被接受）", info.FaceSmall)
	}
	if info.VipName != "VIP" {
		t.Errorf("VipName = %q", info.VipName)
	}
	if info.TotalSize != 1099511627776 {
		t.Errorf("TotalSize = %d", info.TotalSize)
	}
	if info.UsedSize != 549755813888 {
		t.Errorf("UsedSize = %d", info.UsedSize)
	}
	if info.UserID != "12345" {
		t.Errorf("UserID = %q（数字应被转成字符串）", info.UserID)
	}
}

// face 是对象时也要能取到（文档形状），保证两种都对。
func TestUserInfoToleratesFaceAsObject(t *testing.T) {
	body := `{"state":true,"data":{
		"user_name":"u","face":{"face_s":"s.jpg","face_m":"m.jpg","face_l":"l.jpg"}
	}}`
	info, err := fetchInfoWithBody(t, body)
	if err != nil {
		t.Fatalf("face 为对象时解析失败: %v", err)
	}
	if info.FaceSmall != "s.jpg" {
		t.Errorf("FaceSmall = %q（应优先取 face_s）", info.FaceSmall)
	}
}

// ★ 单个字段类型异常不能连累其它字段（这是本文件的核心不变式）。
func TestUserInfoPartialBadFieldsDoNotKillOthers(t *testing.T) {
	// vip_info 是字符串（坏）、rt_space_info 是数组（坏），
	// 但 user_name 是好的 —— 它必须仍然能被取到。
	body := `{"state":true,"data":{
		"user_name":"幸存的用户名",
		"vip_info":"not-an-object",
		"rt_space_info":[1,2,3],
		"face":12345,
		"user_id":{"nested":"object"}
	}}`
	info, err := fetchInfoWithBody(t, body)
	if err != nil {
		t.Fatalf("坏字段不该让整体解析失败: %v", err)
	}
	if info.UserName != "幸存的用户名" {
		t.Errorf("UserName = %q（好字段必须保住）", info.UserName)
	}
	// 坏字段取默认值，不 panic
	if info.VipName != "" || info.TotalSize != 0 || info.FaceSmall != "" {
		t.Errorf("坏字段应取零值: vip=%q total=%d face=%q",
			info.VipName, info.TotalSize, info.FaceSmall)
	}
}

func TestUserInfoEmptyData(t *testing.T) {
	info, err := fetchInfoWithBody(t, `{"state":true,"data":{}}`)
	if err != nil {
		t.Fatalf("空 data 不该报错: %v", err)
	}
	if info.UserName != "" || info.TotalSize != 0 {
		t.Errorf("空 data 应得零值，得到 %+v", info)
	}
}

// 数值字段用字符串给出时也要能读到（115 的类型不稳定是常态）。
func TestUserInfoNumericAsString(t *testing.T) {
	body := `{"state":true,"data":{
		"user_id":"999","user_name":"u",
		"rt_space_info":{"all_total":{"size":"1073741824"},"all_use":{"size":"536870912"}}
	}}`
	info, err := fetchInfoWithBody(t, body)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if info.UserID != "999" {
		t.Errorf("UserID = %q", info.UserID)
	}
	if info.TotalSize != 1073741824 {
		t.Errorf("TotalSize = %d（字符串数字应被解析）", info.TotalSize)
	}
	if info.UsedSize != 536870912 {
		t.Errorf("UsedSize = %d", info.UsedSize)
	}
}

func TestFaceURLVariants(t *testing.T) {
	cases := []struct {
		in   any
		want string
	}{
		{nil, ""},
		{"http://a/b.jpg", "http://a/b.jpg"},
		{map[string]any{"face_s": "s"}, "s"},
		{map[string]any{"face_m": "m"}, "m"}, // 无 face_s 时回退
		{map[string]any{"face_l": "l"}, "l"}, // 只有 face_l 也接受
		{map[string]any{"face_s": ""}, ""},   // 空串不算命中
		{12345, ""},                          // 数字：取不到就空，不 panic
		{[]any{"x"}, ""},                     // 数组：同上
	}
	for _, c := range cases {
		if got := faceURL(c.in); got != c.want {
			t.Errorf("faceURL(%#v) = %q, want %q", c.in, got, c.want)
		}
	}
}
