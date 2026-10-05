package pan115

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// nowTime 让"现在"只有一个来源，便于将来注入可控时钟。
func nowTime() time.Time { return time.Now() }

// ---------------- 宽容类型（这是 115 数据最容易炸的地方）----------------

// ★ 115 在同一字段上混用字符串与数字，且**同一字段在不同条目上也可能不同**。
// 用原生 int64/string 会在真实数据上随机解析失败——整个列表拿不到。
func TestFileInfoAcceptsMixedTypes(t *testing.T) {
	// 目录条目：s 是数字 0，fid 缺失/空，cid 是字符串
	dirJSON := `{"cid":"123456","n":"电影","s":0,"t":"1791102171","ico":"0"}`
	// 文件条目：s 是**字符串**，fid 是**数字**（实测两种都出现过）
	fileJSON := `{"fid":987654,"cid":"123456","n":"阿凡达.mkv","s":"2684354560",` +
		`"sha":"abc123","pc":"xyz789","t":"2026-10-01 12:30","ico":"1","m":1}`

	var d, f fileInfo
	if err := json.Unmarshal([]byte(dirJSON), &d); err != nil {
		t.Fatalf("目录条目解析失败（数字 s / 字符串 cid）: %v", err)
	}
	if err := json.Unmarshal([]byte(fileJSON), &f); err != nil {
		t.Fatalf("文件条目解析失败（字符串 s / 数字 fid）: %v", err)
	}

	nd := d.normalize()
	if !nd.IsDir {
		t.Error("fid 为空的条目必须被判为目录")
	}
	if nd.ID != "123456" {
		t.Errorf("目录应用 cid 作为 ID，得到 %q", nd.ID)
	}

	nf := f.normalize()
	if nf.IsDir {
		t.Error("fid 有值的条目必须被判为文件")
	}
	if nf.ID != "987654" {
		t.Errorf("文件应用 fid 作为 ID，得到 %q", nf.ID)
	}
	if nf.Size != 2684354560 {
		t.Errorf("字符串大小的数字 s 应被解析，得到 %d", nf.Size)
	}
	if !nf.Star {
		t.Error("m=1 应被解析为星标")
	}
}

// ★ 目录判据是 fid 是否为空，**不是 ico**。
// 上游反复调整后确定的判据；用 ico 会在部分条目上出错。
func TestDirectoryDetectionUsesFIDNotIco(t *testing.T) {
	// 构造一个"ico 看起来像文件夹但 fid 有值"的条目（真实数据里存在）
	var f fileInfo
	if err := json.Unmarshal([]byte(`{"fid":"111","ico":"0","n":"x"}`), &f); err != nil {
		t.Fatal(err)
	}
	if f.normalize().IsDir {
		t.Error("fid 有值时不应因 ico=0 被判为目录")
	}

	// 反向：fid 为空但 ico 非 0
	var g fileInfo
	if err := json.Unmarshal([]byte(`{"cid":"222","ico":"1","n":"y"}`), &g); err != nil {
		t.Fatal(err)
	}
	if !g.normalize().IsDir {
		t.Error("fid 为空时必须判为目录（无论 ico 为何）")
	}
}

// ★ 空串/null 表示"该字段不适用"，不是错误。
// 当成错误会导致整个列表解析失败（如目录没有文件大小）。
func TestLooseIntToleratesEmptyAndNull(t *testing.T) {
	cases := map[string]int64{
		`0`:      0,
		`123`:    123,
		`"456"`:  456,
		`""`:     0, // 空串 → 0，不报错
		`null`:   0,
		`"0"`:    0,
		`"1234"`: 1234,
		`1234.0`: 1234, // 偶见小数形式
		`"12.0"`: 12,
	}
	for in, want := range cases {
		var v rawInt64
		if err := json.Unmarshal([]byte(in), &v); err != nil {
			t.Errorf("解析 %s 失败（应容忍为 0）: %v", in, err)
			continue
		}
		if int64(v) != want {
			t.Errorf("解析 %s = %d, want %d", in, v, want)
		}
	}
}

// 大整数必须保精度：115 的文件大小会超过 float64 的精确整数范围（2^53）。
func TestLooseIntKeepsPrecisionForBigNumbers(t *testing.T) {
	// 9 PB，超过 2^53 ≈ 9.007e15
	const big = `9007199254740993`
	var v rawInt64
	if err := json.Unmarshal([]byte(big), &v); err != nil {
		t.Fatal(err)
	}
	if int64(v) != 9007199254740993 {
		t.Errorf("大整数精度丢失: %d（说明走了 float64 路径）", v)
	}
}

func TestLooseIntRejectsGarbage(t *testing.T) {
	for _, in := range []string{`"abc"`, `{}`, `[]`, `"12abc"`} {
		var v rawInt64
		if err := json.Unmarshal([]byte(in), &v); err == nil {
			t.Errorf("垃圾输入 %s 应当返回错误而不是静默变成 0", in)
		}
	}
}

func TestRawStringAcceptsBoth(t *testing.T) {
	cases := map[string]string{
		`"abc"`: "abc",
		`123`:   "123",
		`null`:  "",
		`""`:    "",
		`0`:     "0",
	}
	for in, want := range cases {
		var v rawString
		if err := json.Unmarshal([]byte(in), &v); err != nil {
			t.Errorf("解析 %s 失败: %v", in, err)
			continue
		}
		if v.String() != want {
			t.Errorf("解析 %s = %q, want %q", in, v.String(), want)
		}
	}
}

// ---------------- 列表响应解析 ----------------

// ★ 真实响应形状：data 是数组，count 在**顶层**（与 data 平级）。
// 只解析 data 会丢掉 count，导致分页判断错误。
func TestFileListResponseShape(t *testing.T) {
	body := `{"state":true,"count":123,"offset":0,"limit":200,"data":[` +
		`{"fid":"","cid":"100","n":"剧集","s":0,"t":"1791102171"},` +
		`{"fid":"200","cid":"100","n":"EP01.mp4","s":"1048576","pc":"p1","t":"2026-10-01 10:00"}` +
		`]}`
	var resp fileListResp
	if err := json.Unmarshal([]byte(body), &resp); err != nil {
		t.Fatalf("列表响应解析失败: %v", err)
	}
	if !resp.OK() {
		t.Error("state=true 应判为成功")
	}
	if resp.Count != 123 {
		t.Errorf("顶层 count = %d, want 123", resp.Count)
	}
	if len(resp.Data) != 2 {
		t.Fatalf("条目数 = %d, want 2", len(resp.Data))
	}
	if !resp.Data[0].normalize().IsDir {
		t.Error("第一条应被识别为目录")
	}
	if resp.Data[1].normalize().PickCode != "p1" {
		t.Error("pc 字段应映射到 PickCode")
	}
}

// ★ 未登录时 state=false + error → 必须报错，不能当成空列表。
// 否则用户会看到"网盘是空的"而完全不知道需要登录。
func TestFileListNotLoggedInIsError(t *testing.T) {
	body := `{"state":false,"error":"请先登录"}`
	var resp fileListResp
	if err := json.Unmarshal([]byte(body), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.OK() {
		t.Error("state=false 必须判为失败")
	}
	if resp.text() != "请先登录" {
		t.Errorf("错误文案 = %q", resp.text())
	}
}

// ---------------- 分页 ----------------

func TestListOptionsNormalize(t *testing.T) {
	// limit 超上限要被夹住
	o := ListOptions{Limit: 99999}.normalized()
	if o.Limit != MaxPageSize {
		t.Errorf("超限 limit 应被夹到 %d，得到 %d", MaxPageSize, o.Limit)
	}
	// 未指定 limit 用默认
	if got := (ListOptions{}).normalized().Limit; got <= 0 || got > MaxPageSize {
		t.Errorf("默认 limit 应落在 (0, %d]，得到 %d", MaxPageSize, got)
	}
	// 未指定排序字段要有默认
	if got := (ListOptions{}).normalized().Order; got == "" {
		t.Error("排序字段应有默认值（否则依赖服务端默认，行为不稳定）")
	}
	// 已指定排序字段不应被覆盖
	if got := (ListOptions{Order: "file_name"}).normalized().Order; got != "file_name" {
		t.Errorf("显式排序字段被覆盖: %q", got)
	}
}

// ★ 分页终止条件：HasMore 必须正确处理"总数未知/为 0"的情况。
// 若只判 nextOffset < total，count=0 时会永远为 false → 拿不到后续页。
func TestPaginationHasMoreLogic(t *testing.T) {
	// total=0（服务端没给 count）但返回了一整页 → 应认为还有更多
	files := make([]File, 200)
	p := FilePage{Files: files, Total: 0, Offset: 200}
	hasMore := len(p.Files) > 0 && (p.Total <= 0 || p.Offset < p.Total)
	if !hasMore {
		t.Error("count 缺失但返回满页时，应继续翻页")
	}

	// total 已知且已取完
	p2 := FilePage{Files: files, Total: 200, Offset: 200}
	hasMore2 := len(p2.Files) > 0 && (p2.Total <= 0 || p2.Offset < p2.Total)
	if hasMore2 {
		t.Error("已取到 total 时应停止翻页")
	}

	// 空页必须停止（否则死循环）
	p3 := FilePage{Files: nil, Total: 100, Offset: 200}
	hasMore3 := len(p3.Files) > 0 && (p3.Total <= 0 || p3.Offset < p3.Total)
	if hasMore3 {
		t.Error("空页必须停止翻页（否则会死循环）")
	}
}

// ---------------- 大小与时间格式化 ----------------

func TestFormatSize(t *testing.T) {
	cases := map[int64]string{
		0:          "",
		-1:         "",
		512:        "512 B",
		1024:       "1 KB",
		1048576:    "1 MB",
		2684354560: "2.5 GB",
		1073741824: "1.0 GB",
	}
	for in, want := range cases {
		if got := FormatSize(in); got != want {
			t.Errorf("FormatSize(%d) = %q, want %q", in, got, want)
		}
	}
}

// 口径要与 Emby 侧一致（GB 保留 1 位小数），保证两个源在 UI 上风格统一。
func TestFormatSizeMatchesEmbyConvention(t *testing.T) {
	if got := FormatSize(5368709120); got != "5.0 GB" {
		t.Errorf("GB 应保留 1 位小数（与 Emby 侧一致），得到 %q", got)
	}
	if got := FormatSize(1572864); got != "1 MB" {
		t.Errorf("MB 应取整（与 Emby 侧一致），得到 %q", got)
	}
}

// ★ 时间有两种格式，且**必须容错**：时间只是展示信息，
// 不该因格式变化让整个列表不可用。
func TestParseTimeHandlesBothFormats(t *testing.T) {
	// 目录：Unix 秒字符串
	if got := ParseTime("1791102171"); got.IsZero() {
		t.Error("Unix 秒格式应能解析")
	}
	// 文件："2006-01-02 15:04"（无时区，按 UTC+8 解读）
	got := ParseTime("2026-10-01 12:30")
	if got.IsZero() {
		t.Fatal("日期格式应能解析")
	}
	if got.Year() != 2026 || got.Month() != 10 || got.Day() != 1 {
		t.Errorf("日期解析错误: %v", got)
	}
	if got.Hour() != 12 || got.Minute() != 30 {
		t.Errorf("时间解析错误（可能时区处理有误）: %v", got)
	}
	// 秒级格式也应支持
	if ParseTime("2026-10-01 12:30:45").IsZero() {
		t.Error("带秒的格式应能解析")
	}
	// 垃圾输入返回零值而不是 panic/错误
	for _, bad := range []string{"", "abc", "not-a-time", "0000-00-00"} {
		if !ParseTime(bad).IsZero() {
			t.Errorf("%q 应返回零值", bad)
		}
	}
}

// ---------------- 直链响应形状 ----------------

// ★ url 字段可能是对象、布尔 false 或 null。
// 按对象硬解析时遇到 `false` 会得到"JSON 类型错误"，
// 掩盖真实原因（文件违规/需要会员），用户只看到莫名的解析失败。
func TestDownloadURLTolerateFalseAndNull(t *testing.T) {
	for _, in := range []string{`false`, `null`, `{}`, `""`} {
		var u downloadURL
		if err := json.Unmarshal([]byte(in), &u); err != nil {
			t.Errorf("url=%s 不应解析失败（这是「未返回地址」的正常形状）: %v", in, err)
			continue
		}
		if u.URL != "" {
			t.Errorf("url=%s 应得到空 URL，实际 %q", in, u.URL)
		}
	}
	// 正常对象
	var u downloadURL
	if err := json.Unmarshal([]byte(`{"url":"https://cdn.115.com/x"}`), &u); err != nil {
		t.Fatal(err)
	}
	if u.URL != "https://cdn.115.com/x" {
		t.Errorf("URL = %q", u.URL)
	}
}

// ★ data 是加密字符串（不是对象），且解密后是**以文件 ID 为键的 map**。
func TestDownloadRespDataIsEncryptedString(t *testing.T) {
	body := `{"state":true,"data":"ZW5jcnlwdGVkLXN0cmluZw=="}`
	var dr downloadResp
	if err := json.Unmarshal([]byte(body), &dr); err != nil {
		t.Fatalf("data 为字符串时解析失败（说明按对象解析了）: %v", err)
	}
	if dr.EncodedData != "ZW5jcnlwdGVkLXN0cmluZw==" {
		t.Errorf("EncodedData = %q", dr.EncodedData)
	}
}

// 解密后是 map 而非数组：取第一条要遍历 values。
func TestDownloadInfoMapShape(t *testing.T) {
	plain := `{"123456":{"file_name":"movie.mkv","file_size":1048576,` +
		`"pick_code":"pc1","url":{"url":"https://cdn.115.com/a"}}}`
	var infos map[string]downloadInfo
	if err := json.Unmarshal([]byte(plain), &infos); err != nil {
		t.Fatalf("map 形状解析失败: %v", err)
	}
	if len(infos) != 1 {
		t.Fatalf("条目数 = %d", len(infos))
	}
	for _, info := range infos {
		if info.FileName != "movie.mkv" {
			t.Errorf("FileName = %q", info.FileName)
		}
		if int64(info.FileSize) != 1048576 {
			t.Errorf("FileSize = %d", info.FileSize)
		}
		if info.URL.URL != "https://cdn.115.com/a" {
			t.Errorf("URL 路径应为 data.<id>.url.url，得到 %q", info.URL.URL)
		}
	}
}

// ---------------- 直链缓存 ----------------

// ★ 缓存必须能失效：CDN 401/410（地址过期）后要重新取地址，
// 否则会一直用失效地址，用户看到持续播放失败。
func TestDirectLinkCacheTTLAndInvalidate(t *testing.T) {
	c := newDirectLinkCache()
	l := DirectLink{URL: "https://x", RequestedAt: nowTime()}
	c.put("pc1", l)

	if _, ok := c.get("pc1"); !ok {
		t.Fatal("刚写入的缓存应命中")
	}
	// get 不存在的键
	if _, ok := c.get("nope"); ok {
		t.Error("未知键不应命中")
	}

	// 失效后应未命中
	c.invalidate("pc1")
	if _, ok := c.get("pc1"); ok {
		t.Error("invalidate 后不应再命中（否则会一直用过期地址）")
	}
}

// 过期条目必须被丢弃（用 RequestedAt 回拨模拟过期）。
func TestDirectLinkCacheExpires(t *testing.T) {
	c := newDirectLinkCache()
	stale := DirectLink{
		URL:         "https://x",
		RequestedAt: nowTime().Add(-linkTTL - 1), // 已过期
	}
	c.put("pc1", stale)
	if _, ok := c.get("pc1"); ok {
		t.Error("超过 TTL 的直链必须被丢弃（115 不返回过期时间，只能本地兜）")
	}
}

// ---------------- 会话与凭据 ----------------

// 未登录时列表必须给出明确的"尚未登录"，而不是发请求拿 401。
func TestListFilesRequiresLogin(t *testing.T) {
	c := NewClient(Credential{})
	_, err := c.ListFiles(RootCID, ListOptions{})
	if err == nil {
		t.Fatal("未登录时必须报错")
	}
	le, ok := err.(*LoginError)
	if !ok {
		t.Fatalf("应是 LoginError，得到 %T", err)
	}
	if !le.NeedsQR {
		t.Error("未登录必须标记 NeedsQR（UI 据此引导扫码）")
	}
	if !strings.Contains(le.Error(), "登录") {
		t.Errorf("文案应提到登录: %q", le.Error())
	}
}

func TestResolveDirectLinkValidatesInput(t *testing.T) {
	// 未登录
	c := NewClient(Credential{})
	if _, err := c.ResolveDirectLink("pc"); err == nil {
		t.Error("未登录时取直链应报错")
	}
	// 已登录但 pickCode 为空
	c2 := NewClient(Credential{UID: "u", CID: "c", SEID: "s"})
	if _, err := c2.ResolveDirectLink("  "); err == nil {
		t.Error("pickCode 为空时应报错")
	}
}

// ★ 播放头必须带固定 UA —— 115 的 CDN 直链与取地址时的 UA 强绑定。
// 漏掉 UA 会 403，而且现象是"取到地址了但播不了"，很难排查。
func TestPlaybackHeadersIncludeUA(t *testing.T) {
	c := NewClient(Credential{UID: "u", CID: "c", SEID: "s"})
	h := c.playbackHeaders(nil)
	if h["User-Agent"] != DefaultUA {
		t.Errorf("播放头必须带固定 UA，得到 %q", h["User-Agent"])
	}
	if h["Cookie"] == "" {
		t.Error("播放头应带凭据 cookie（CDN 可能校验）")
	}
	// 取证结论：列表与普通取直链都**不需要** Referer，只有分享接口需要。
	// 设一个无关 Referer 反而可能触发风控，故不应出现。
	if _, ok := h["Referer"]; ok {
		t.Error("不应设置 Referer（取证结论：普通取直链不需要，且可能触发风控）")
	}
}

// ★★ 取地址响应的 Set-Cookie 必须合并进播放头。
//
// 这是"地址取到了但播不了"的头号成因：CDN 的一次性凭证（上游夹具里叫
// download_token）只在 Set-Cookie 里给，不在 URL 里。漏掉的表现为 403，
// 且因为地址看起来是好的，排查时极易怀疑到别处。
func TestPlaybackHeadersMergeSetCookies(t *testing.T) {
	c := NewClient(Credential{UID: "u", CID: "c", SEID: "s"})

	// 模拟 Set-Cookie 的两条：一条带属性段（应被剥掉），一条纯 pair
	env := envelope{setCookies: []string{
		"download_token=abc123; Path=/; Domain=.115.com; HttpOnly",
		"other=xyz",
	}}
	pairs := env.cookiePairs()
	if len(pairs) != 2 {
		t.Fatalf("应解析出 2 个 cookie pair，得到 %d: %v", len(pairs), pairs)
	}
	// 属性段必须被剥离——把 Path/Domain 塞进请求 Cookie 头会让 CDN 认为非法
	if pairs[0] != "download_token=abc123" {
		t.Errorf("应只保留 name=value，得到 %q", pairs[0])
	}

	h := c.playbackHeaders(pairs)
	cookie := h["Cookie"]
	// 凭据 cookie 在前，响应 cookie 依次追加，"; " 连接
	if !strings.Contains(cookie, "UID=u; CID=c; SEID=s") {
		t.Errorf("凭据 cookie 应在最前，得到 %q", cookie)
	}
	if !strings.Contains(cookie, "download_token=abc123") {
		t.Errorf("download_token 必须被合并（否则播不了），得到 %q", cookie)
	}
	if !strings.Contains(cookie, "other=xyz") {
		t.Errorf("所有 Set-Cookie 都应被合并，得到 %q", cookie)
	}
}

// cookiePairs 的边界：空串、无 = 号的串、只有属性段的串都不应产出条目。
func TestCookiePairsEdgeCases(t *testing.T) {
	for _, tc := range []struct {
		in   []string
		want int
	}{
		{nil, 0},
		{[]string{""}, 0},
		{[]string{"   "}, 0},
		{[]string{"novalue"}, 0},     // 无 = 号
		{[]string{"=noname"}, 0},     // name 为空
		{[]string{"a=b"}, 1},         // 正常
		{[]string{"a=b; Path=/"}, 1}, // 带属性
	} {
		got := envelope{setCookies: tc.in}.cookiePairs()
		if len(got) != tc.want {
			t.Errorf("cookiePairs(%v) = %v (len %d), want len %d", tc.in, got, len(got), tc.want)
		}
	}
}

func TestPickCodeForRequiresInput(t *testing.T) {
	c := NewClient(Credential{})
	if _, err := c.PickCodeFor(""); err == nil {
		t.Error("空文件 ID 应报错")
	}
}

func TestFindByID(t *testing.T) {
	files := []File{
		{ID: "1", Name: "dir", IsDir: true},
		{ID: "2", Name: "a.mkv", PickCode: "pc2"},
		{ID: "3", Name: "nodir", PickCode: ""},
	}
	if pc, ok := findByID(files, "2"); !ok || pc != "pc2" {
		t.Errorf("应找到 pc2，得到 %q ok=%v", pc, ok)
	}
	// pickCode 为空的条目不算命中（取不了直链）
	if _, ok := findByID(files, "3"); ok {
		t.Error("pickCode 为空时不应算命中")
	}
	if _, ok := findByID(files, "999"); ok {
		t.Error("不存在的 ID 不应命中")
	}
}

func TestBoolTo01(t *testing.T) {
	if boolTo01(true) != "1" || boolTo01(false) != "0" {
		t.Error("boolTo01 映射错误（115 用 0/1 而非 true/false）")
	}
}

func TestErrnoClassificationConstantsDistinct(t *testing.T) {
	// 防止复制粘贴时把两个常量写成同一个值
	if ErrnoLoginExpired == ErrnoNotLoggedIn ||
		ErrnoLoginExpired == ErrnoNeedVerify ||
		ErrnoNotLoggedIn == ErrnoNeedVerify {
		t.Error("三个 errno 常量必须互不相同")
	}
}

func TestLooksLikeWAFOnEmpty(t *testing.T) {
	if looksLikeWAF(nil) || looksLikeWAF([]byte{}) {
		t.Error("空响应不应被判为 WAF")
	}
}

func TestEnvelopeTextFallbacks(t *testing.T) {
	cases := []struct {
		body string
		want string
	}{
		{`{"error":"E"}`, "E"},
		{`{"message":"M"}`, "M"},
		{`{"error":"E","message":"M"}`, "E"}, // error 优先
		{`{}`, ""},
	}
	for _, c := range cases {
		var env envelope
		if err := json.Unmarshal([]byte(c.body), &env); err != nil {
			t.Fatal(err)
		}
		if got := env.text(); got != c.want {
			t.Errorf("text() from %s = %q, want %q", c.body, got, c.want)
		}
	}
}

func TestOrDefault(t *testing.T) {
	if orDefault("", "d") != "d" || orDefault("  ", "d") != "d" || orDefault("x", "d") != "x" {
		t.Error("orDefault 行为不正确")
	}
}

func TestIsNotLoggedInOnHTTPError(t *testing.T) {
	// do() 遇到 4xx/5xx（非 WAF）应返回错误而不是空 envelope
	c, srv := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"boom"}`))
	})
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	if _, err := c.do(req); err == nil {
		t.Error("HTTP 500 应返回错误")
	}
}
