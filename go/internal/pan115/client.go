// Package pan115 承载 115 网盘（webapi 路线）的**纯 Go** 协议逻辑。
//
// ## 为什么零 cgo（这是刻意的架构约束）
//
// 本包**不 import "C"**，因此 `go test ./internal/pan115` 在任意环境可跑
// （含 `CGO_ENABLED=0` 且无 gcc 的本机）。桥接层 `go/bridge.go` 含 `import "C"`，
// 会让整个 main 包依赖 cgo——所以业务逻辑一律放这里，见 ADR 0004。
//
// ## 路线选择（见 ADR 0007）
//
// 115 有**两套互不相通**的接口体系：
//
//	(i) 官方开放平台 `proapi.115.com/open/*`
//	    OAuth 设备码 + PKCE，需申请 AppId；服务端签名，正规但需开发者资质
//	(ii) 逆向 webapi `webapi.115.com/*` / `aps.115.com/*`
//	    Cookie（UID/CID/SEID/KID），扫码即用，无需资质
//
// 本项目走 **(ii)**，理由是用户明确要求"试用 115driver 路线"，
// 且 (i) 需要用户先花约 2 周走完 115 的开发者审核。**风险已在 ADR 0007 与 UI 中明示**：
// 这是非官方接口，115 可能变更或有风控，使用者自行承担。
//
// ## ⚠️ 版权纪律（务必遵守）
//
// 协议事实取自 `SheltonZhu/115driver`（**MIT**，仅提取 URL/参数名/字段名/状态码）。
// **不要**从这个仓库或任何 GPL 项目复制实现代码与注释。
// 同类聚合播放器多为 GPL-3.0，**禁止参考其代码**；本包协议事实全部来自公开抓包与 curl 实测。
package pan115

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
)

// 协议端点。全部来自 115driver（MIT）的 pkg/driver/api.go。
//
// ⚠️ 实测（2026-10-05）：`https://webapi.115.com/files` **被阿里云 WAF 拦截**
// （HTTPS 405 + "您的访问被阻断" HTML，换 UA/加 Referer 都无效）。
// 故文件列表**不用**它，改用下面实测 200 的替代端点。
const (
	// 登录
	URLQRCodeSession = "https://qrcodeapi.115.com/api/1.0/web/1.0/token"
	URLQRStatus      = "https://qrcodeapi.115.com/get/status/"
	URLQRImage       = "https://qrcodeapi.115.com/api/1.0/mac/1.0/qrcode"
	URLLoginQR       = "https://passportapi.115.com/app/1.0/web/1.0/login/qrcode"
	URLLoginSSO      = "https://passportapi.115.com/app/1.0/web/1.0/check/sso"
	URLUserInfo      = "https://my.115.com/?ct=ajax&ac=nav"
	URLStatusChk     = "https://my.115.com/?ct=guide&ac=status"

	// 文件
	//
	// URLFileList 用 `aps.115.com/natsort/files.php`：
	// 实测返回 `{"state":false,"error":"请先登录"}` —— 正常业务响应，说明只差 cookie。
	// 而 `webapi.115.com/files` 被 WAF 拦。
	URLFileList   = "https://aps.115.com/natsort/files.php"
	URLFileList2  = "https://web.api.115.com/files"
	URLFileSearch = "https://webapi.115.com/files/search"
	URLFileStat   = "https://webapi.115.com/category/get"
	URLFileInfo   = "https://webapi.115.com/files/get_info"

	// 下载 / 播放直链
	URLDownURL = "https://proapi.115.com/app/chrome/downurl"
)

// DefaultUA 是**固定**的 User-Agent。
//
// ⚠️ **UA 绑定**是本路线最容易静默失败的地方（现象是 403）：
// 115 的 CDN 直链与"取地址时所用的 UA"**强绑定**，取地址与播放必须用**同一个** UA 串。
// 上游证据：`SheltonZhu/115driver` 的 issue #80 原文"CDN 链接与默认 UA 强绑定"
// （起因是 resty 会强制注入默认 UA，破坏了空 UA 取址）。
//
// 因此：
//   - 本值**全局唯一**，取地址与播放（media_kit 的 http_headers）都用它
//   - **不要**随手改这个字符串：改了会让已发出的直链全部失效
//   - 参考值取自 115driver 的 `UA115Disk`（MIT，仅协议事实）
const DefaultUA = "Mozilla/5.0 115disk/30.1.0"

// QRStatus 是扫码状态。取值语义来自 115driver（MIT）。
type QRStatus int

const (
	QRWaiting  QRStatus = 0  // 等待扫码
	QRScanned  QRStatus = 1  // 已扫码，待用户确认
	QRAllowed  QRStatus = 2  // 已确认，可换 token
	QRExpired  QRStatus = -1 // 已过期
	QRCanceled QRStatus = -2 // 已取消
)

// Label 返回中文状态描述（UI 直接用）。
func (s QRStatus) Label() string {
	switch s {
	case QRWaiting:
		return "请用 115 App 扫码"
	case QRScanned:
		return "已扫码，请在手机上确认登录"
	case QRAllowed:
		return "已确认，正在登录…"
	case QRExpired:
		return "二维码已过期，请刷新"
	case QRCanceled:
		return "已取消登录"
	default:
		return fmt.Sprintf("未知状态(%d)", int(s))
	}
}

// Terminal 表示该状态已结束，轮询应停止。
func (s QRStatus) Terminal() bool {
	return s == QRAllowed || s == QRExpired || s == QRCanceled
}

// QRSession 是一次扫码会话。
type QRSession struct {
	UID    string `json:"uid"`
	Time   int64  `json:"time"`
	Sign   string `json:"sign"`
	QRCode string `json:"qrcode"` // 扫码内容（https URL），非图片
}

// ImageURL 返回**可直接显示**的二维码图片地址。
//
// 实测确认：该端点返回 `image/png`（554 字节，PNG 魔数 89 50 4E 47），
// 所以 Dart 侧直接 `Image.network` 即可，**无需引入二维码生成库**。
func (s QRSession) ImageURL() string {
	return URLQRImage + "?uid=" + s.UID
}

// Credential 是登录后拿到的会话凭据，等价于 115 的 cookie 四项。
//
// ⚠️ **这是敏感数据**：它等价于账号登录态。只存设备安全存储
// （flutter_secure_storage / Android Keystore），**绝不入库、不打日志**。
type Credential struct {
	UID  string `json:"UID"`
	CID  string `json:"CID"`
	SEID string `json:"SEID"`
	KID  string `json:"KID"`

	// UserID 是 115 的用户 ID（与 UID 不同，UID 是会话标识）。
	UserID string `json:"user_id,omitempty"`
	// UserName 仅用于界面展示，便于用户确认登录的是哪个账号。
	UserName string `json:"user_name,omitempty"`
}

// Valid 判断凭据是否可用于发起请求。
func (c Credential) Valid() bool {
	return c.UID != "" && c.CID != "" && c.SEID != ""
}

// Cookie 组装 Cookie 头。
//
// ⚠️ 顺序无关但**四项都不能少**：缺 SEID 会 401，缺 CID 会拿到空的文件列表
// （后者尤其危险——表现为"网盘是空的"而不是报错）。
func (c Credential) Cookie() string {
	parts := make([]string, 0, 4)
	if c.UID != "" {
		parts = append(parts, "UID="+c.UID)
	}
	if c.CID != "" {
		parts = append(parts, "CID="+c.CID)
	}
	if c.SEID != "" {
		parts = append(parts, "SEID="+c.SEID)
	}
	if c.KID != "" {
		parts = append(parts, "KID="+c.KID)
	}
	return strings.Join(parts, "; ")
}

// Client 是 115 webapi 客户端。
//
// 并发安全：cred 由 mu 保护，因为刷新与业务请求可能并发。
type Client struct {
	http *http.Client
	ua   string

	mu   sync.RWMutex
	cred Credential

	// links 缓存已取到的播放直链，减少对 115 的取址请求（该接口有限流）。
	links directLinkCache

	// limiter 全局限速器。放在 do() 里对所有请求生效，无法绕过。
	limiter *rateLimiter
}

// NewClient 构造客户端。[cred] 可为零值（未登录），登录后再 SetCredential。
func NewClient(cred Credential) *Client {
	return &Client{
		// 超时给足：扫码状态轮询是**长轮询**，实测单次最长约 30 秒才返回，
		// 若沿用常规 10s 超时会把正常的长轮询误判为超时失败。
		http:    &http.Client{Timeout: 45 * time.Second},
		ua:      DefaultUA,
		cred:    cred,
		links:   *newDirectLinkCache(),
		limiter: newRateLimiter(DefaultRPS),
	}
}

// SetCredential 更新凭据（登录成功或刷新后调用）。
func (c *Client) SetCredential(cred Credential) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.cred = cred
}

// Credential 返回当前凭据的副本。
func (c *Client) Credential() Credential {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.cred
}

// LoggedIn 是否已持有可用凭据。
func (c *Client) LoggedIn() bool { return c.Credential().Valid() }

// UserAgent 返回固定 UA（取地址与播放必须一致，见 DefaultUA 注释）。
func (c *Client) UserAgent() string { return c.ua }

// newReq 构造带固定头的请求。
//
// 头是**必须**的：实测不加 UA 会被 WAF 拦截（405 访问被阻断）。
func (c *Client) newReq(method, url string) (*http.Request, error) {
	req, err := http.NewRequest(method, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", c.ua)
	req.Header.Set("Referer", "https://115.com/")
	req.Header.Set("Accept", "application/json, text/plain, */*")
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	if cred := c.Credential(); cred.Valid() {
		req.Header.Set("Cookie", cred.Cookie())
	}
	return req, nil
}

// envelope 是 115 webapi 的通用响应外壳。
//
// ⚠️ 115 的响应有两套并存的形状：
//
//	{state:true,  data:{...}}                   —— 成功
//	{state:false, errno:990001, error:"登录超时"} —— 业务错误（HTTP 仍为 200）
//
// **只看 HTTP 状态码是不够的**：业务错误全部包在 200 里。
// 这也是为什么必须显式检查 state/errno，否则"未登录"会被当成"网盘为空"。
type envelope struct {
	State   flexBool        `json:"state"`
	Code    int             `json:"code"`
	Errno   int             `json:"errno"`
	ErrNo   int             `json:"errNo"`
	Message string          `json:"message"`
	Error   string          `json:"error"`
	Data    json.RawMessage `json:"data"`

	// raw 保留**完整原始响应体**。
	//
	// 为什么信封里还要存原文：115 的多数接口把有用字段放在**顶层**
	// （如文件列表的 `count`/`offset` 与 `data` 平级），
	// 只解析 data 会丢掉它们。保留原文后，各接口可在校验信封之后
	// 再按自己的形状解析一次，无需重复发请求或让 do() 返回两个值。
	raw []byte

	// setCookies 是响应里的 `Set-Cookie`（原样字符串）。
	//
	// ★ 取直链时必须用它：CDN 会回一个一次性凭证（上游测试夹具里叫
	// `download_token`），**必须合并进真正下载/播放请求的 Cookie 头**，
	// 否则会出现"地址取到了但播不了"——这类现象极难排查。
	//
	// 用原样字符串而不是解析成 http.Cookie 再重组：Set-Cookie 的属性
	// （Domain/Path/Expires）与我们要往请求里塞的东西无关，
	// 而重组可能丢失 `name=value` 之外的信息（如多值）。
	setCookies []string
}

// cookiePairs 返回可直接拼进请求 Cookie 头的 `name=value` 列表。
//
// 只取每个 Set-Cookie 的第一个分号之前的部分（即 name=value），
// 丢弃属性段（Domain/Path/HttpOnly 等）——那些是给浏览器用的，
// 放进请求头会让 CDN 认为 cookie 非法。
func (e envelope) cookiePairs() []string {
	out := make([]string, 0, len(e.setCookies))
	for _, sc := range e.setCookies {
		pair := sc
		if i := strings.IndexByte(pair, ';'); i >= 0 {
			pair = pair[:i]
		}
		pair = strings.TrimSpace(pair)
		// 只接受形如 name=value 且 name 非空
		if eq := strings.IndexByte(pair, '='); eq > 0 {
			out = append(out, pair)
		}
	}
	return out
}

// flexBool 兼容 `state` 字段的两种编码。
//
// ⚠️ 这是实测踩出来的差异，不处理会导致**登录流程直接失败**：
//
//	二维码体系：{"state":1,   "code":0}        ← 数字
//	webapi 体系：{"state":true, ...}            ← 布尔
//
// 用 *bool 反序列化数字会报 `cannot unmarshal number into bool`，
// 整个响应解析失败；反之亦然。故两种都接。
type flexBool struct {
	val  bool
	set  bool
	zero bool // 字段缺失
}

func (f *flexBool) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	switch {
	case s == "null" || s == "":
		f.zero = true
	case s == "true":
		f.val, f.set = true, true
	case s == "false":
		f.val, f.set = false, true
	default:
		// 数字：0 视为 false，非 0 视为 true
		var n float64
		if err := json.Unmarshal(b, &n); err != nil {
			return err
		}
		f.val, f.set = n != 0, true
	}
	return nil
}

// errnoOf 兼容 errno / errNo 两种拼写（115 两套体系都用过，实测都出现过）。
func (e envelope) errnoOf() int {
	switch {
	case e.Errno != 0:
		return e.Errno
	case e.ErrNo != 0:
		return e.ErrNo
	default:
		return e.Code
	}
}

// text 返回可展示的错误文案。
func (e envelope) text() string {
	switch {
	case e.Error != "":
		return e.Error
	case e.Message != "":
		return e.Message
	default:
		return ""
	}
}

// OK 判断业务是否成功。
//
// `state` 字段缺失时按"成功"处理：部分端点只给 data 不给 state
// （如实测的状态轮询返回 `{"state":1,"code":0,"data":{}}`）。
func (e envelope) OK() bool {
	if e.State.set && !e.State.val {
		return false
	}
	return e.errnoOf() == 0
}
