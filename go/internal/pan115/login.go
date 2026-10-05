package pan115

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
)

// 登录/鉴权相关的业务错误码。
//
// 来源：115driver（MIT）的 error.go + 实测试探。**分类很重要**——
// 有些错误重试有意义，有些必须让用户重新登录。
//
// ⚠️ 两个实测陷阱（不处理会导致误判）：
//  1. `check/sso` 接口**失败时 state 仍是 1**，必须判 code/errno；
//  2. `errno` 与 `errNo` 两种拼写都用过，**要同时查**，取非 0 的那个。
const (
	ErrnoLoginExpired = 990001   // 登录超时/未登录
	ErrnoNotLoggedIn  = 99       // proapi 的"请重新登录"
	ErrnoNeedVerify   = 40101017 // "老乡验证失败"（换 cookie 失败；⚠️ uid 未确认也返回它）
	ErrnoQRCKeyBad    = 40199002 // 二维码失效 / key invalid
	ErrnoParamBad     = 40100000 // 参数错误
	ErrnoCredInvalid  = 40101032 // 凭证无效
	ErrnoKickedOut    = 40101035 // 被多设备登录管理踢出
	ErrnoSessionEnded = 40101037 // 会话已退出
	ErrnoRepeatLogin  = 40101033 // 重复登录
	ErrnoRepeatLogin2 = 40101038 // 重复登录（另一取值）
	ErrnoTooBigToDown = 50028    // 文件太大无法下载（需 VIP）
	ErrnoFileGone     = 70005    // 文件不存在或已删除
	ErrnoPickGone     = 50003    // pickcode 不存在/已删除
)

// needsRelogin 判断错误码是否表示"必须重新登录"。
//
// ★ 上游一致的做法是**立即停止重试**：带着失效凭据反复请求会触发风控，
// 可能导致该授权被永久标记失效——那时用户只能重新扫码，无其他补救手段。
// 上游文档专门点名"后台常驻程序尤其要实现该逻辑"。
func needsRelogin(errno int) bool {
	switch errno {
	case ErrnoLoginExpired, ErrnoNotLoggedIn, ErrnoNeedVerify,
		ErrnoCredInvalid, ErrnoKickedOut, ErrnoSessionEnded,
		ErrnoRepeatLogin, ErrnoRepeatLogin2:
		return true
	default:
		return false
	}
}

// needsVIP 判断是否属于"需要会员"类错误。
//
// 单独成一类是为了给出**可行动**的提示（引导开通会员），
// 而不是笼统的"操作失败"——用户否则会反复重试。
func needsVIP(errno int) bool {
	return errno == ErrnoTooBigToDown || errno == 10010
}

// errnoLabel 返回错误码的中文语义（用于日志与提示）。
func errnoLabel(errno int) string {
	switch errno {
	case ErrnoLoginExpired:
		return "登录已超时"
	case ErrnoNotLoggedIn:
		return "未登录"
	case ErrnoNeedVerify:
		return "凭证校验失败"
	case ErrnoQRCKeyBad:
		return "二维码已失效"
	case ErrnoParamBad:
		return "请求参数有误"
	case ErrnoCredInvalid:
		return "凭证无效"
	case ErrnoKickedOut:
		return "账号已在其他设备登录"
	case ErrnoSessionEnded:
		return "会话已退出"
	case ErrnoTooBigToDown:
		return "文件过大，需要会员才能下载"
	case ErrnoFileGone:
		return "文件不存在或已删除"
	case ErrnoPickGone:
		return "文件提取码已失效"
	default:
		return ""
	}
}

// LoginError 是登录/鉴权类错误。
//
// 单独成类型而不是笼统 error：UI 要据此决定是"提示重试"、"引导重新扫码"
// 还是"提示开通会员"。这个区分做错会让用户卡在无限重试里，
// 而重试又可能加重风控——所以分类不是体验问题，是安全问题。
type LoginError struct {
	Msg      string
	Errno    int
	NeedsQR  bool // true = 必须重新扫码，重试无用
	NeedsVIP bool // true = 需要会员，重试无用
}

func (e *LoginError) Error() string {
	if e.Msg != "" {
		return e.Msg
	}
	if lbl := errnoLabel(e.Errno); lbl != "" {
		return lbl
	}
	return fmt.Sprintf("登录失败(errno=%d)", e.Errno)
}

// newErr 按错误码构造带正确分类的错误。
//
// 统一入口而不是各处手写 LoginError：分类逻辑散落时最容易漏掉某一类
// （如忘记标记 NeedsQR），而漏掉的表现正是"无限重试"。
func newErr(errno int, msg string) *LoginError {
	if msg == "" {
		msg = errnoLabel(errno)
	}
	return &LoginError{
		Msg:      msg,
		Errno:    errno,
		NeedsQR:  needsRelogin(errno),
		NeedsVIP: needsVIP(errno),
	}
}

// ---------------- 扫码登录 ----------------

// RequestQRCode 申请一个扫码会话。
//
// 实测确认（2026-10-05）：无需任何凭据即可调用，返回
//
//	{"state":1,"code":0,"data":{"uid":"...","time":1791102171,
//	 "sign":"165bf9f6...","qrcode":"https://115.com/scan/dg-..."}}
func (c *Client) RequestQRCode() (QRSession, error) {
	req, err := c.newReq(http.MethodGet, URLQRCodeSession)
	if err != nil {
		return QRSession{}, err
	}
	// 二维码接口**不要**带 cookie：带上失效 cookie 反而会干扰
	req.Header.Del("Cookie")

	env, err := c.do(req)
	if err != nil {
		return QRSession{}, err
	}
	if !env.OK() {
		return QRSession{}, &LoginError{
			Msg:   orDefault(env.text(), "获取二维码失败"),
			Errno: env.errnoOf(),
		}
	}
	var s QRSession
	if err := json.Unmarshal(env.Data, &s); err != nil {
		return QRSession{}, fmt.Errorf("二维码响应解析失败: %w", err)
	}
	if s.UID == "" {
		return QRSession{}, fmt.Errorf("二维码响应缺少 uid")
	}
	return s, nil
}

// PollQRStatus 查询扫码状态。
//
// ⚠️ **这是长轮询**（实测单次约 30.18 秒才返回，且未扫码时 data 为空对象 `{}`）。
// 因此：
//   - HTTP 客户端超时必须 > 30s（Client 里给的 45s 就是这个原因）
//   - UI 侧不要用"每 2 秒一次"的短间隔轮询，会打出无意义的并发长请求
//   - data 为空 = 状态未变（仍是上一次的状态），**不是错误**
func (c *Client) PollQRStatus(s QRSession) (QRStatus, error) {
	q := url.Values{}
	q.Set("uid", s.UID)
	q.Set("time", strconv.FormatInt(s.Time, 10))
	q.Set("sign", s.Sign)

	req, err := c.newReq(http.MethodGet, URLQRStatus+"?"+q.Encode())
	if err != nil {
		return QRWaiting, err
	}
	req.Header.Del("Cookie")

	env, err := c.do(req)
	if err != nil {
		return QRWaiting, err
	}
	if !env.OK() {
		return QRWaiting, &LoginError{
			Msg:   orDefault(env.text(), "查询扫码状态失败"),
			Errno: env.errnoOf(),
		}
	}

	// data 为空对象时表示状态未变——返回"等待中"让调用方继续轮询。
	// 注意不能报错：长轮询下这是**最常见**的返回。
	trimmed := strings.TrimSpace(string(env.Data))
	if trimmed == "" || trimmed == "{}" || trimmed == "null" {
		return QRWaiting, nil
	}

	var st struct {
		Status int `json:"status"`
	}
	if err := json.Unmarshal(env.Data, &st); err != nil {
		return QRWaiting, fmt.Errorf("扫码状态解析失败: %w", err)
	}
	switch QRStatus(st.Status) {
	case QRWaiting, QRScanned, QRAllowed, QRExpired, QRCanceled:
		return QRStatus(st.Status), nil
	default:
		// 未知取值当成"等待"，避免因 115 新增状态而中断登录流程
		return QRWaiting, nil
	}
}

// LoginByQRCode 用已确认的扫码会话换取凭据。
//
// ⚠️ **必须先轮询到 [QRAllowed]（status==2）再调本方法**。
// 实测纠错：一个真实但**尚未扫码确认**的 uid 调此接口，会返回
// `40101017 老乡验证失败`——与"完全非法 uid"的响应**一模一样**。
// 也就是说 40101017 **无法区分**"uid 非法"与"uid 未确认"，
// 若在未确认时就调用，用户会看到一个误导性的"验证失败"，
// 而正确做法是继续等待用户扫码。
//
// 返回的 Credential 四项（UID/CID/SEID/KID）等价于 115 的登录 cookie，
// **属敏感数据**，只应存入设备安全存储。
func (c *Client) LoginByQRCode(s QRSession) (Credential, error) {
	if s.UID == "" {
		return Credential{}, fmt.Errorf("扫码会话缺少 uid")
	}
	form := url.Values{}
	form.Set("account", s.UID)
	form.Set("app", "web")

	req, err := http.NewRequest(http.MethodPost, URLLoginQR,
		strings.NewReader(form.Encode()))
	if err != nil {
		return Credential{}, err
	}
	req.Header.Set("User-Agent", c.ua)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Del("Cookie") // 登录前不应带旧 cookie

	c.limiter.wait()
	env, err := c.do(req)
	if err != nil {
		return Credential{}, err
	}
	if !env.OK() {
		errno := env.errnoOf()
		return Credential{}, &LoginError{
			Msg:     orDefault(env.text(), "登录失败"),
			Errno:   errno,
			NeedsQR: true, // 登录这一步失败只能重新扫码
		}
	}

	// 响应形状：`data.cookie` 是对象。
	//
	// ⚠️ 这里曾经出过一个真实缺陷：凭据的**字段名大小写**与我按上游源码
	// 设想的形状对不上，于是解析出**全零 Credential**——
	// 而"解析出零值"不会报错，Dart 侧只看到"凭据不完整"，
	// 表现为登录卡在最后一步。教训：这类"静默零值"必须靠
	// **打印真实响应的键名**来定位（见 LogRawKeys）。
	cred, err := parseCredential(env.Data)
	if err != nil {
		return Credential{}, err
	}
	if !cred.Valid() {
		// 把**实际收到的键名**带进错误信息（只有键名，没有值）——
		// 这是排查"字段名对不上"的唯一有效线索。
		return Credential{}, &LoginError{
			Msg: fmt.Sprintf(
				"登录响应中缺少必要凭据（需要 UID/CID/SEID）。实际收到的键: %s",
				rawKeys(env.Data)),
			NeedsQR: true,
		}
	}
	c.SetCredential(cred)
	return cred, nil
}

// rawKeys 返回 JSON 对象的**键名**列表（不包含任何值）。
//
// 专为排查"字段名对不上"而写：这种缺陷的现象是"解析出零值"而非报错，
// 不打键名就只能靠猜。**刻意只取键名**——值里可能含凭据。
func rawKeys(raw json.RawMessage) string {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		s := strings.TrimSpace(string(raw))
		if len(s) > 80 {
			s = s[:80] + "…"
		}
		return fmt.Sprintf("(非对象) %s", s)
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	// 若某个值是嵌套对象（如 cookie），把它的键名也带上——
	// 凭据就在下一层，只报外层键名仍然定位不到。
	var parts []string
	for _, k := range keys {
		if sub := m[k]; len(sub) > 0 && sub[0] == '{' {
			parts = append(parts, k+"{"+rawKeys(sub)+"}")
		} else {
			parts = append(parts, k)
		}
	}
	return strings.Join(parts, ", ")
}

// parseCredential 从 login 响应里提取凭据，兼容几种已知嵌套形状。
func parseCredential(raw json.RawMessage) (Credential, error) {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "null" {
		return Credential{}, fmt.Errorf("登录响应缺少 data")
	}

	// 优先按 {cookie:{...}} 形状解析（上游源码使用的形状）
	var wrapped struct {
		Cookie *Credential `json:"cookie"`
	}
	if err := json.Unmarshal(raw, &wrapped); err == nil && wrapped.Cookie != nil {
		return *wrapped.Cookie, nil
	}
	// 退回顶层直接就是凭据的形状
	var direct Credential
	if err := json.Unmarshal(raw, &direct); err != nil {
		return Credential{}, fmt.Errorf("登录响应解析失败: %w", err)
	}
	return direct, nil
}

// ---------------- 用户信息 ----------------

// UserInfo 是账号信息，用于设置页展示（让用户确认登录的是哪个账号、
// 以及为什么某些视频不可播——115 的清晰度/能力与会员等级相关）。
type UserInfo struct {
	UserID    string `json:"user_id"`
	UserName  string `json:"user_name"`
	VipName   string `json:"vip_name"`
	VipExpire string `json:"vip_expire"`
	TotalSize int64  `json:"total_size"`
	UsedSize  int64  `json:"used_size"`
	FaceSmall string `json:"face_small"`
}

// FetchUserInfo 拉取账号信息，用于验证凭据是否仍然有效。
//
// 用途有两个，都是必要的：
//  1. 登录后立刻确认凭据可用（避免"看起来登录成功但实际不能列文件"）
//  2. 应用启动时校验已存凭据（失效则引导重新扫码，而不是等用户点开文件夹才报错）
func (c *Client) FetchUserInfo() (UserInfo, error) {
	req, err := c.newReq(http.MethodGet, URLUserInfo)
	if err != nil {
		return UserInfo{}, err
	}
	env, err := c.do(req)
	if err != nil {
		return UserInfo{}, err
	}
	if !env.OK() {
		return UserInfo{}, newErr(env.errnoOf(), orDefault(env.text(), "获取账号信息失败"))
	}
	return parseUserInfo(env.Data)
}

// parseUserInfo 从 user.info 的 `data` 里逐字段取账号信息。
//
// ## 为什么逐字段取而不是一个大 struct（踩过的真实缺陷）
//
// 实测 `my.115.com/?ct=ajax&ac=nav` 返回的 `face` 是**字符串**，
// 而文档/上游源码里是 `{face_s, face_m, face_l}` **对象**。
// 原先用一个大 struct 整体 Unmarshal，于是：
//
//	json: cannot unmarshal string into Go struct field .face of type struct {...}
//
// **整个账号信息解析失败** → 拿不到用户名/VIP/容量 → UI 判定"未登录"。
// 一个**装饰性字段**（头像）搞挂了登录状态判定——这是最典型的
// "服务端字段形状不可信"问题（AGENTS.md §5.3 防御式解析）。
//
// 独立成函数而非内联：便于用单元测试喂各种畸形形状（见 userinfo_test.go），
// 不必真的发网络请求。
func parseUserInfo(raw json.RawMessage) (UserInfo, error) {
	var d map[string]any
	if err := json.Unmarshal(raw, &d); err != nil {
		return UserInfo{}, fmt.Errorf("账号信息解析失败: %w", err)
	}

	// 小工具：安全取嵌套 map（任一层不是对象就返回 nil）与宽容取值。
	// 这些工具刻意局部定义——它们只服务于本函数，放外面会变成
	// 无人使用的通用工具（且容易与其它包的同名工具混淆）。
	sub := func(m map[string]any, k string) map[string]any {
		if v, ok := m[k].(map[string]any); ok {
			return v
		}
		return nil
	}
	num := func(m map[string]any, k string) int64 {
		if m == nil {
			return 0
		}
		switch v := m[k].(type) {
		case float64:
			return int64(v)
		case string:
			if n, err := strconv.ParseInt(v, 10, 64); err == nil {
				return n
			}
		}
		return 0
	}
	str := func(m map[string]any, k string) string {
		if m == nil {
			return ""
		}
		if s, ok := m[k].(string); ok {
			return s
		}
		return ""
	}

	vip := sub(d, "vip_info")
	space := sub(d, "rt_space_info")

	return UserInfo{
		UserID:    anyToString(d["user_id"]),
		UserName:  str(d, "user_name"),
		VipName:   str(vip, "level_name"),
		VipExpire: anyToString(vip["expire"]),
		TotalSize: num(sub(space, "all_total"), "size"),
		UsedSize:  num(sub(space, "all_use"), "size"),
		// face 可能是字符串（实测）也可能是对象（文档）——两种都容忍。
		// 它只用于显示头像，**绝不该影响登录状态判定**。
		FaceSmall: faceURL(d["face"]),
	}, nil
}

// faceURL 从 `face` 字段里取头像地址。
//
// ⚠️ 实测该字段是**字符串**（不是文档里的 `{face_s,face_m,face_l}` 对象），
// 而按对象解析会让整个账号信息解析失败——一个装饰性字段搞挂登录状态。
// 故两种形状都接受，取不到就返回空（头像缺失无所谓）。
func faceURL(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case map[string]any:
		for _, k := range []string{"face_s", "face_m", "face_l"} {
			if s, ok := t[k].(string); ok && s != "" {
				return s
			}
		}
	}
	return ""
}

// ---------------- 内部工具 ----------------

// do 发请求并把响应解析成 envelope。
//
// ⚠️ 两层错误必须都处理：
//  1. HTTP 层：非 2xx（且注意 **405 可能是 WAF 拦截**而非接口不存在）
//  2. 业务层：HTTP 200 里 state=false / errno≠0
//
// 只看 HTTP 状态码会把"未登录"当成"网盘为空"（静默空列表），
// 这是这类客户端最常见的缺陷。
func (c *Client) do(req *http.Request) (envelope, error) {
	var env envelope
	// ★ 全局限速：2 请求/秒、严格串行（见 ratelimit.go 的风险说明）。
	// **所有**请求都经这里，所以限流无法被绕过——这正是把它放在 do() 的原因：
	// 若放在各业务方法里，新增方法时极易漏加。
	// ★ 两道闸门，都在**发请求之前**：
	//
	//  1. 每日总量上限（防"总量累积"触发风控——
	//     限速只管速率，管不住一个失控循环在几分钟内打上千次）
	//  2. 全局开关（用户可一键停用 115，此时任何请求都不发）
	//
	// 顺序上先判开关再判预算：开关是可逆的用户意图，
	// 预算消耗掉就不该退（退了会让上限形同虚设）。
	if !pan115Enabled() {
		return env, fmt.Errorf("115 功能已被停用（可在设置中重新开启）")
	}
	if !tryConsumeBudget() {
		return env, fmt.Errorf(
			"今日 115 请求已达上限（%d 次），为避免账号风控已暂停。"+
				"重启应用或明天可继续", dailyRequestCap)
	}

	c.limiter.wait()

	resp, err := c.http.Do(req)
	if err != nil {
		return env, fmt.Errorf("网络请求失败: %w", err)
	}
	defer resp.Body.Close()

	// 响应体上限：防止异常响应打爆内存（文件列表单页最大 1150 条，
	// 正常响应都在数百 KB 内，8MB 足够且留有充足余量）。
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return env, fmt.Errorf("读取响应失败: %w", err)
	}

	if resp.StatusCode == http.StatusForbidden ||
		resp.StatusCode == http.StatusMethodNotAllowed ||
		resp.StatusCode == http.StatusTeapot { // 418：上游实测的 WAF 限流响应
		// 405/403/418 且返回 HTML 时，几乎总是阿里云 WAF 拦截。
		// 给出可操作的提示，而不是把 HTML 当 JSON 解析后报莫名其妙的错。
		//
		// ★ A/B 两类要分开提示：A 类（小写 doctypehtml 的 405）通常由
		// "漏带 UID cookie"引起，提示用户检查登录状态才有用；
		// B 类（WAF 品牌页）是真正的风控，只能退避等待。
		if blocked, classB := isWAFBlocked(body); blocked {
			if classB || resp.StatusCode == http.StatusTeapot {
				return env, fmt.Errorf(
					"请求被 115 风控拦截（HTTP %d）：可能因请求过于频繁，请稍后重试。"+
						"（本项目已限速 2 次/秒且串行翻页；若仍被拦，请减少扫库频率）",
					resp.StatusCode)
			}
			return env, fmt.Errorf(
				"请求被 115 网关拦截（HTTP %d）：该端点对查询串有额外校验，"+
					"请确认已登录（缺少登录态 cookie 时最容易触发）",
				resp.StatusCode)
		}
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return env, fmt.Errorf("115 返回 HTTP %d", resp.StatusCode)
	}

	if err := json.Unmarshal(body, &env); err != nil {
		return env, fmt.Errorf("响应不是合法 JSON（可能被风控拦截）: %w", err)
	}
	env.raw = body
	// 保留 Set-Cookie 原文：取直链需要把 CDN 凭证合并进播放请求（见 cookiePairs）。
	for _, sc := range resp.Header.Values("Set-Cookie") {
		if strings.TrimSpace(sc) != "" {
			env.setCookies = append(env.setCookies, sc)
		}
	}
	return env, nil
}

// orDefault 空串时取默认值。
func orDefault(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}

// anyToString 把可能是数字或字符串的 JSON 值统一成字符串。
func anyToString(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case float64:
		// 大整数（用户 ID）用无小数形式，避免出现 "1.2345678e+07"
		return strconv.FormatInt(int64(t), 10)
	case json.Number:
		return t.String()
	case bool:
		if t {
			return "true"
		}
		return "false"
	default:
		return fmt.Sprint(t)
	}
}
