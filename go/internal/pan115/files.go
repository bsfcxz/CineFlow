package pan115

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// 文件列表参数上限（实测与生产配置共同确定）。
//
// ⚠️ 上游源码里有 `MaxDirPageLimit=1150`，但那**可能是该库自设的防御上限**
// 而非服务端导出值；而生产级实现（OpenList）默认 `page_size=1000`。
// 本项目取 1000：宁少勿多——超限时服务端可能**静默截断**，
// 表现为"翻页少了几条"，比报错难查得多。
const (
	MaxPageSize = 1000
	// RootCID 是根目录 ID（上游把空串归一为 "0"）。
	RootCID = "0"
	// DefaultRPS 是全局请求速率上限（2 次/秒）。
	// 依据见 ratelimit.go：上游有"Emby 扫库触发 WAF 418 + 封号风险"的实例。
	DefaultRPS = 2
)

// File 是一个 115 文件/目录条目（**已归一化**的模型）。
//
// ## 为什么要有归一化层（这是踩坑点）
//
// 115 的 webapi 用**单字母短键**，且**文件与目录的字段含义不同**：
//
//	文件：fid 有值，n/s/sha/pc 有效
//	目录：fid 为**空字符串**，用 cid 标识，s=0
//
// 若直接暴露原始 JSON 给上层，UI 会到处出现 `j["n"]` 这种不可读代码，
// 且"怎么判断是目录"这种知识会散落各处。故此处一次归一化。
type File struct {
	ID       string // 文件用 fid，目录用 cid
	Name     string
	IsDir    bool
	Size     int64
	PickCode string // 取播放/下载直链用；目录为空
	SHA1     string
	// UpdateTime 是服务端给的字符串时间。**不做时间解析**——
	// 文件与目录的时间格式不同（目录是 Unix 秒、文件是 "2006-01-02 15:04"），
	// 且这两个格式在 115 各接口上并不稳定（见上游注释），
	// 故原样保留字符串，需要展示时再在 UI 层处理。
	UpdateTime string
	ThumbURL   string
	// Star 是否星标
	Star bool
}

// fileInfo 是 webapi 原始条目（字段名来自 115driver，MIT）。
//
// ⚠️ 所有字段都用"宽容类型"（rawInt/rawString）承接：
// 115 在这些字段上**混用字符串与数字**（如 `s` 可能是 `"123"` 或 `123`，
// `fid` 可能是 `123` 或 `"123"`）。用原生 int64/string 会在真实数据上随机解析失败。
type fileInfo struct {
	FID      rawString `json:"fid"`
	CID      rawString `json:"cid"`
	ParentID rawString `json:"pid"`
	Name     string    `json:"n"`
	Size     rawInt64  `json:"s"`
	SHA1     string    `json:"sha"`
	PickCode string    `json:"pc"`
	IsStar   rawInt    `json:"m"`
	UpdateT  rawString `json:"t"`
	ThumbURL string    `json:"u"`
	// ico 是图标/类型标识：0=文件夹，其他=文件类型。
	// **不要用它判目录**——上游实践表明 fid 是否为空才是可靠判据。
	Ico rawString `json:"ico"`
}

// fileListResp 是列表响应。
//
// 注意 `data` 直接是数组（不是嵌套对象），而 `count` 在**顶层**。
type fileListResp struct {
	envelope
	Count  rawInt64   `json:"count"`
	Offset rawInt64   `json:"offset"`
	Limit  rawInt64   `json:"limit"`
	Data   []fileInfo `json:"data"`
}

// FilePage 是一页文件列表。
type FilePage struct {
	Files  []File
	Total  int64
	Offset int64
	// HasMore 是否还有下一页
	HasMore bool
}

// ListOptions 是列目录的可选参数。
type ListOptions struct {
	Offset  int64
	Limit   int64
	ShowDir bool // 是否包含目录（默认 true）
	Asc     bool // 排序方向
	// Order 排序字段：file_name / file_size / user_ptime / user_utime / file_type
	Order string
	// Suffix 按后缀过滤（如 "mp4"）
	Suffix string
	// Type 文件类型过滤：0=全部 1=文档 2=图片 3=音频 4=视频 5=压缩包 6=应用 7=书籍
	Type int
}

func (o ListOptions) normalized() ListOptions {
	if o.Limit <= 0 {
		o.Limit = 200
	}
	if o.Limit > MaxPageSize {
		o.Limit = MaxPageSize
	}
	if o.Order == "" {
		// 默认按"用户修改时间"倒序：对媒体库场景最有用（新加的片子在前）
		o.Order = "user_ptime"
	}
	return o
}

// ListFiles 列出某目录下的条目。
//
// [cid] 为目录 ID，根目录传 [RootCID]（即 "0"）。
//
// ⚠️ 端点选择：用 `aps.115.com/natsort/files.php` 而**不是** `webapi.115.com/files`，
// 因为后者实测被阿里云 WAF 拦截（HTTP 405 + "访问被阻断"，换 UA 与加 Referer 都无效）。
// 前者实测返回 `{"state":false,"error":"请先登录"}`——正常业务响应，说明只差 cookie。
func (c *Client) ListFiles(cid string, opts ListOptions) (FilePage, error) {
	if !c.LoggedIn() {
		return FilePage{}, &LoginError{Msg: "尚未登录 115 网盘", NeedsQR: true}
	}
	if cid == "" {
		cid = RootCID
	}
	o := opts.normalized()

	q := url.Values{}
	q.Set("cid", cid)
	q.Set("offset", strconv.FormatInt(o.Offset, 10))
	q.Set("limit", strconv.FormatInt(o.Limit, 10))
	q.Set("show_dir", boolTo01(o.ShowDir))
	q.Set("o", o.Order)
	// asc=1 表示升序（上游默认值即 1）。注意我们的 Asc 字段语义与之一致。
	q.Set("asc", boolTo01(o.Asc))
	// ★ `format=json` 是 aps 端点的必需参数：
	// 实测不带它可能返回非 JSON（HTML/其他格式），导致解析失败。
	q.Set("format", "json")
	// natsort=0 关闭"自然排序"：让 o/asc 参数真正生效，
	// 否则文件名排序会按 115 自己的自然序规则（与 UI 的排序选择不一致）。
	q.Set("natsort", "0")
	// custom_order=0 使用"记忆排序"：避免服务端记住用户上次会话的排序
	// 而让我们的 o/asc 参数失效（现象是"传了排序但结果没变"）。
	q.Set("custom_order", "0")
	if o.Suffix != "" {
		q.Set("suffix", o.Suffix)
	}
	if o.Type > 0 {
		q.Set("type", strconv.Itoa(o.Type))
	}

	req, err := c.newReq(http.MethodGet, URLFileList+"?"+q.Encode())
	if err != nil {
		return FilePage{}, err
	}
	env, err := c.do(req)
	if err != nil {
		return FilePage{}, err
	}
	if !env.OK() {
		errno := env.errnoOf()
		return FilePage{}, &LoginError{
			Msg:     orDefault(env.text(), "获取文件列表失败"),
			Errno:   errno,
			NeedsQR: needsRelogin(errno),
		}
	}

	// 复用已读到的 body 再解析一层：信封只取了 state/errno/data，
	// 列表还需要顶层的 count/offset。
	var full fileListResp
	if err := json.Unmarshal(env.raw, &full); err != nil {
		return FilePage{}, fmt.Errorf("文件列表解析失败: %w", err)
	}

	files := make([]File, 0, len(full.Data))
	for _, fi := range full.Data {
		files = append(files, fi.normalize())
	}

	total := int64(full.Count)
	// ★ 下一页位置必须用**服务端回显的 offset + 本页实际条数**，不能本地累加。
	// 原因：服务端可能把我们请求的 limit 截断（如请求 1000 实际只回 200），
	// 本地按请求值累加会**跳过中间部分**——现象是"翻页丢内容"，且不报错。
	//
	// 上游还断言"请求 cid 必须等于响应回显 cid"，用它能发现 cookie 串了账号
	// 或目录被移动的情况；这里不比对该断言（会产生误报），但保留字段。
	nextOffset := int64(full.Offset) + int64(len(files))
	return FilePage{
		Files:   files,
		Total:   total,
		Offset:  nextOffset,
		HasMore: len(files) > 0 && (total <= 0 || nextOffset < total),
	}, nil
}

// ListAll 拉取某目录的**全部**条目（自动翻页）。
//
// [maxPages] 是安全上限，防止服务端 count 异常导致死循环
// （实测会有 count 与实际返回不一致的情况）。
func (c *Client) ListAll(cid string, opts ListOptions, maxPages int) ([]File, error) {
	if maxPages <= 0 {
		maxPages = 50
	}
	var all []File
	o := opts.normalized()
	for page := 0; page < maxPages; page++ {
		p, err := c.ListFiles(cid, o)
		if err != nil {
			return all, err
		}
		all = append(all, p.Files...)
		if !p.HasMore || len(p.Files) == 0 {
			break
		}
		o.Offset = p.Offset
	}
	return all, nil
}

// normalize 把原始条目转成归一化 File。
//
// ★ 目录判据用 **fid 是否为空**，不是 `ico`：
// 目录的 `fid` 为空而 `cid` 有值；文件反之。这是上游反复调整后确定的判据
// （用 ico 判会在某些条目上出错，因为 ico 表示"类型图标"而非"是否目录"）。
func (fi fileInfo) normalize() File {
	isDir := strings.TrimSpace(fi.FID.String()) == ""
	id := fi.FID.String()
	if isDir {
		id = fi.CID.String()
	}
	return File{
		ID:         id,
		Name:       fi.Name,
		IsDir:      isDir,
		Size:       int64(fi.Size),
		PickCode:   fi.PickCode,
		SHA1:       fi.SHA1,
		UpdateTime: fi.UpdateT.String(),
		ThumbURL:   fi.ThumbURL,
		Star:       int(fi.IsStar) != 0,
	}
}

// ---------------- 宽容类型 ----------------
//
// 115 的 JSON 在同一字段上混用字符串与数字，且**同一字段在不同条目上也可能不同**
// （实测：目录条目的 `s` 是数字 0，文件条目可能是字符串）。
// 用原生类型会在真实数据上随机失败，故统一走这两层。

// rawString 接受 string 或 number，统一成 string。
type rawString string

func (r *rawString) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if s == "null" || s == "" {
		*r = ""
		return nil
	}
	if len(s) > 0 && s[0] == '"' {
		var str string
		if err := json.Unmarshal(b, &str); err != nil {
			return err
		}
		*r = rawString(str)
		return nil
	}
	// 数字（可能是大整数，故按 json.Number 保精度）
	var n json.Number
	if err := json.Unmarshal(b, &n); err != nil {
		return err
	}
	*r = rawString(n.String())
	return nil
}

func (r rawString) String() string { return string(r) }

// rawInt / rawInt64 接受 number 或 string（含小数形式），统一成整数。
type rawInt int

func (r *rawInt) UnmarshalJSON(b []byte) error {
	v, err := parseLooseInt(b)
	if err != nil {
		return err
	}
	*r = rawInt(v)
	return nil
}

type rawInt64 int64

func (r *rawInt64) UnmarshalJSON(b []byte) error {
	v, err := parseLooseInt(b)
	if err != nil {
		return err
	}
	*r = rawInt64(v)
	return nil
}

// parseLooseInt 解析可能是 number / 带引号数字 / 空串的整数。
//
// 空串与 null 返回 0 而**不报错**：115 会用空串表示"该字段不适用"
// （如目录没有文件大小）。把它当错误会导致整个列表解析失败。
func parseLooseInt(b []byte) (int64, error) {
	s := strings.TrimSpace(string(b))
	if s == "null" || s == "" || s == `""` {
		return 0, nil
	}
	if s[0] == '"' {
		var str string
		if err := json.Unmarshal(b, &str); err != nil {
			return 0, err
		}
		str = strings.TrimSpace(str)
		if str == "" {
			return 0, nil
		}
		// 可能是 "123" 或 "123.0"
		if i, err := strconv.ParseInt(str, 10, 64); err == nil {
			return i, nil
		}
		f, err := strconv.ParseFloat(str, 64)
		if err != nil {
			return 0, fmt.Errorf("无法解析为整数: %q", str)
		}
		return int64(f), nil
	}
	// 直接是数字（可能是 1.0 形式，如 file_size 偶见）
	if i, err := strconv.ParseInt(s, 10, 64); err == nil {
		return i, nil
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, fmt.Errorf("无法解析为整数: %q", s)
	}
	return int64(f), nil
}

func boolTo01(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// FormatSize 把字节数格式化成可读字符串。
//
// 与 Emby 侧 MediaSource.sizeLabel 的口径**刻意保持一致**（GB 保留 1 位小数、
// MB 取整），这样两个源的"文件大小"在 UI 上看起来是同一种风格。
func FormatSize(size int64) string {
	if size <= 0 {
		return ""
	}
	const (
		gb = 1073741824
		mb = 1048576
		kb = 1024
	)
	switch {
	case size >= gb:
		return strconv.FormatFloat(float64(size)/gb, 'f', 1, 64) + " GB"
	case size >= mb:
		return strconv.FormatInt(size/mb, 10) + " MB"
	case size >= kb:
		return strconv.FormatInt(size/kb, 10) + " KB"
	default:
		return strconv.FormatInt(size, 10) + " B"
	}
}

// ParseTime 尽力解析 115 的时间字符串，失败返回零值。
//
// 115 有两种格式（**不要假设只有一种**）：
//   - 目录：Unix 秒的字符串（如 "1791102171"）
//   - 文件："2006-01-02 15:04"（**不带时区**，按 115 服务端的 Asia/Shanghai 解读）
//
// 解析失败返回零值而不是错误：时间只是展示信息，
// 不应因为一个时间格式变化就让整个列表不可用。
func ParseTime(s string) time.Time {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}
	}
	if sec, err := strconv.ParseInt(s, 10, 64); err == nil && sec > 0 {
		return time.Unix(sec, 0)
	}
	loc := time.FixedZone("UTC+8", 8*3600)
	for _, layout := range []string{"2006-01-02 15:04", "2006-01-02 15:04:05"} {
		if t, err := time.ParseInLocation(layout, s, loc); err == nil {
			return t
		}
	}
	return time.Time{}
}
