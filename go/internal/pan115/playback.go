package pan115

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// DirectLink 是一条可播放的直链。
//
// ## ★ 为什么 Headers 必须一起传给播放器（最容易静默失败的地方）
//
// 115 的 CDN 直链与"取地址时所用的 UA"**强绑定**：取地址用 UA-A，
// 播放时也必须用 UA-A，否则 CDN 返回 403。
// 上游证据：`SheltonZhu/115driver` 的 issue #80 原文"CDN 链接与默认 UA 强绑定"
// （起因是 resty 会强制注入默认 UA，破坏了空 UA 取址）；
// 同类客户端也专门用"按 URL 前缀记住取址时的 UA 并在播放时回放"的注册表实现。
//
// 另外取地址响应可能回 `Set-Cookie`（如 `download_token`），
// 这些 cookie **必须合并进下载/播放请求**，否则也会被拒。
//
// 因此本结构把 Headers 与 URL 绑在一起返回——**只传 URL 给播放器是不够的**。
// Dart 侧需把 Headers 原样塞进 media_kit 的 `httpHeaders`
// （media_kit 会转成 mpv 的 `http-header-fields`，已核实支持）。
type DirectLink struct {
	URL      string
	FileName string
	FileSize int64
	Headers  map[string]string
	// RequestedAt 记录取地址时刻。**不是服务端给的过期时间**
	// （115 不返回任何过期字段），只用于本地缓存判断与日志。
	RequestedAt time.Time
}

// linkTTL 是本地直链缓存时长。
//
// ⚠️ 这是**我们自己拍的保守值**，不是 115 给的：
// 官方与 webapi 都**不返回任何过期时间字段**（上游文档亦无），
// 只能靠"用就用，403 判限流、401/410 判过期"来兜。
// 取 30 分钟偏保守——过期只是多取一次地址，而用失效地址会让用户看到播放失败。
const linkTTL = 30 * time.Minute

// directLinkCache 缓存已取到的直链，避免每次起播都请求（115 对此有限流）。
//
// 键是 pickCode。用互斥锁而不是 sync.Map：需要"读-判断-写"的原子性，
// 且条目数很少（用户同时播放的片子不会多），锁竞争可忽略。
type directLinkCache struct {
	mu sync.Mutex
	m  map[string]DirectLink
}

func newDirectLinkCache() *directLinkCache {
	return &directLinkCache{m: make(map[string]DirectLink)}
}

func (c *directLinkCache) get(pickCode string) (DirectLink, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	l, ok := c.m[pickCode]
	if !ok {
		return DirectLink{}, false
	}
	if time.Since(l.RequestedAt) > linkTTL {
		delete(c.m, pickCode)
		return DirectLink{}, false
	}
	return l, true
}

func (c *directLinkCache) put(pickCode string, l DirectLink) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m[pickCode] = l
}

// Invalidate clears a cached link (e.g. after a 401/410 from the CDN).
func (c *directLinkCache) invalidate(pickCode string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.m, pickCode)
}

// downloadResp 是取直链接口的响应。
//
// ★ 两个关键形状（实测与上游一致）：
//  1. `data` **是加密字符串**（m115 算法），不是对象——必须先解密再解析 JSON
//  2. 解密后是**以文件 ID 为键的 map**，不是数组；url 路径是两层
//     `data.<fileId>.url.url`
type downloadResp struct {
	envelope
	EncodedData string `json:"data"`
}

// downloadInfo 是解密后的单条下载信息。
type downloadInfo struct {
	FileName string      `json:"file_name"`
	FileSize rawInt64    `json:"file_size"`
	PickCode string      `json:"pick_code"`
	URL      downloadURL `json:"url"`
}

type downloadURL struct {
	URL string `json:"url"`
}

// UnmarshalJSON 兼容 `url` 字段的多种非对象形状：布尔 false / null / 空串 / 字符串 URL。
//
// ★ 为什么要兼容这些：**取地址失败时 115 会返回 `"url": false` 而不是报错**。
// 若按对象解析会得到"JSON 类型错误"，掩盖真实原因（文件违规/被和谐/需要会员），
// 用户只会看到莫名的解析失败。空串同理——表示"没有地址"而非"数据损坏"。
func (d *downloadURL) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if s == "false" || s == "null" || s == "" || s == `""` {
		return nil
	}
	// 极少数情况下 url 直接是字符串（而非 {url: "..."}）
	if s[0] == '"' {
		var str string
		if err := json.Unmarshal(b, &str); err != nil {
			return err
		}
		*d = downloadURL{URL: str}
		return nil
	}
	type alias downloadURL
	var a alias
	if err := json.Unmarshal(b, &a); err != nil {
		return err
	}
	*d = downloadURL(a)
	return nil
}

// PickCodeFor 由文件 ID 反查 pickCode。
//
// ## 为什么需要这一步
//
// 115 取直链用 **pickCode**（不是文件 ID），而文件列表里两者都有。
// 但 UI/路由传的是文件 ID（与 Emby 侧 `itemId` 语义对齐），
// 所以播放时需要一次映射。
//
// 实现上直接列父目录再匹配，避免额外依赖一个"按 ID 查文件"的接口
// （该接口在不同端点上行为不一致）。命中的是同一个 pickCode 时缓存由上层负责。
func (c *Client) PickCodeFor(fileID string) (string, error) {
	if fileID == "" {
		return "", fmt.Errorf("文件 ID 为空")
	}
	// 先在根目录找（媒体库的常见结构是根目录下直接放文件夹/文件）
	files, err := c.ListAll(RootCID, ListOptions{ShowDir: true}, 20)
	if err != nil {
		return "", err
	}
	if pc, ok := findByID(files, fileID); ok {
		return pc, nil
	}
	// 再下钻一层目录（覆盖"根/分类/文件"的常见组织方式）
	for _, f := range files {
		if !f.IsDir {
			continue
		}
		sub, err := c.ListAll(f.ID, ListOptions{ShowDir: true}, 20)
		if err != nil {
			// 单个子目录失败不影响整体：继续找其他的
			continue
		}
		if pc, ok := findByID(sub, fileID); ok {
			return pc, nil
		}
	}
	return "", fmt.Errorf("未找到文件（id=%s）的提取码，可能已被移动或删除", fileID)
}

func findByID(files []File, id string) (string, bool) {
	for _, f := range files {
		if f.ID == id && f.PickCode != "" {
			return f.PickCode, true
		}
	}
	return "", false
}

// ResolveDirectLink 取文件的播放/下载直链（带缓存）。
//
// [pickCode] 来自文件列表的 `pc` 字段。
//
// 实现要点（每条都对应一个上游踩过的坑）：
//  1. 请求体是 **m115 加密后的 `data` 表单字段**，不是明文 JSON
//  2. 必须带固定 UA（见 DefaultUA：CDN 直链与取地址 UA 强绑定）
//  3. 响应 `data` 是加密串，需解密
//  4. 解密后是 map，取第一条
//  5. 返回值必须**携带取地址时的请求头**，供播放器原样回放
func (c *Client) ResolveDirectLink(pickCode string) (DirectLink, error) {
	if !c.LoggedIn() {
		return DirectLink{}, &LoginError{Msg: "尚未登录 115 网盘", NeedsQR: true}
	}
	if strings.TrimSpace(pickCode) == "" {
		return DirectLink{}, fmt.Errorf("提取码为空")
	}
	if l, ok := c.links.get(pickCode); ok {
		return l, nil
	}

	key, payload, err := encodePickCode(pickCode)
	if err != nil {
		return DirectLink{}, err
	}

	form := url.Values{}
	form.Set("data", payload)

	req, err := http.NewRequest(http.MethodPost, URLDownURL+"?t="+nowUnix(),
		strings.NewReader(form.Encode()))
	if err != nil {
		return DirectLink{}, err
	}
	req.Header.Set("User-Agent", c.ua)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if cred := c.Credential(); cred.Valid() {
		req.Header.Set("Cookie", cred.Cookie())
	}

	env, err := c.do(req)
	if err != nil {
		return DirectLink{}, err
	}
	if !env.OK() {
		errno := env.errnoOf()
		return DirectLink{}, &LoginError{
			Msg:     orDefault(env.text(), "获取播放地址失败"),
			Errno:   errno,
			NeedsQR: needsRelogin(errno),
		}
	}

	// 取原始 data 字符串（加密串），再解密
	var dr downloadResp
	if err := json.Unmarshal(env.raw, &dr); err != nil {
		return DirectLink{}, fmt.Errorf("播放地址响应解析失败: %w", err)
	}
	if dr.EncodedData == "" {
		return DirectLink{}, fmt.Errorf("播放地址响应为空（该文件可能不可播放）")
	}

	plain, err := decodePayload(dr.EncodedData, key)
	if err != nil {
		return DirectLink{}, fmt.Errorf("播放地址解密失败: %w", err)
	}

	// ★ data 是 map（键为文件 ID），不是数组
	var infos map[string]downloadInfo
	if err := json.Unmarshal(plain, &infos); err != nil {
		return DirectLink{}, fmt.Errorf("播放地址内容解析失败: %w", err)
	}
	for _, info := range infos {
		u := strings.TrimSpace(info.URL.URL)
		if u == "" {
			// url 为 false/空：115 未给出地址。这不是解析错误，
			// 而是"该文件不可下载/播放"（常见原因：违规文件、需要会员）。
			return DirectLink{}, fmt.Errorf(
				"115 未返回播放地址：该文件可能违规受限或需要会员（file=%s）", info.FileName)
		}
		// ★ 把取地址响应里的 Set-Cookie 一并带进播放头。
		// 漏掉它们会出现"地址取到了但播不了"——CDN 侧的一次性凭证
		// 只在 Set-Cookie 里给，不在 URL 里。这类现象极难排查。
		link := DirectLink{
			URL:         u,
			FileName:    info.FileName,
			FileSize:    int64(info.FileSize),
			Headers:     c.playbackHeaders(env.cookiePairs()),
			RequestedAt: time.Now(),
		}
		c.links.put(pickCode, link)
		return link, nil
	}
	return DirectLink{}, fmt.Errorf("播放地址响应中没有条目")
}

// playbackHeaders 返回播放器必须原样携带的请求头。
//
// ★ 这是本文件的核心约定：**取地址与播放必须用同一个 UA**（逐字节一致）。
// 少带 UA 会 403；带错 UA 同样 403（因为 CDN 绑定的是**取地址时**用的那个）。
//
// [extraCookies] 是取地址响应里 `Set-Cookie` 给出的 cookie
// （上游测试夹具里叫 `download_token`）。**必须合并进来**——
// 它是 CDN 侧的一次性凭证，漏掉会导致"地址取到了但播不了"。
//
// 合并规则（对齐上游 buildDownloadHeaders 的语义）：
// 已有的 Cookie 串在前，各响应 cookie 依序追加，用 "; " 连接。
// 不做去重：同名 cookie 由 CDN 自行按后出现者优先处理。
func (c *Client) playbackHeaders(extraCookies []string) map[string]string {
	h := map[string]string{
		"User-Agent": c.ua,
	}
	cookies := make([]string, 0, len(extraCookies)+1)
	if cred := c.Credential(); cred.Valid() {
		cookies = append(cookies, cred.Cookie())
	}
	for _, ck := range extraCookies {
		if s := strings.TrimSpace(ck); s != "" {
			cookies = append(cookies, s)
		}
	}
	if len(cookies) > 0 {
		h["Cookie"] = strings.Join(cookies, "; ")
	}
	// 注意**不设 Referer**：上游取证结论是普通取直链与列表都不需要 Referer，
	// 只有"分享"接口才需要（形如 https://115cdn.com/s/<code>?password=<pw>&）。
	// 设一个无关的 Referer 反而可能触发风控，故不加。
	return h
}

// InvalidateLink 使某文件的直链缓存失效（CDN 返回 401/410 时调用）。
//
// 错误分类很重要，别搞混：
//   - CDN **401/410** → 地址过期 → 调用本方法后重新取地址
//   - CDN **403** → **限流**，不是过期：应退避 + 降并发，**不要**反复重取地址
//     （重取只会加重限流）
func (c *Client) InvalidateLink(pickCode string) {
	c.links.invalidate(pickCode)
}

// nowUnix 返回当前 Unix 秒字符串（接口要求带 `t` 参数）。
func nowUnix() string {
	return fmt.Sprintf("%d", time.Now().Unix())
}
