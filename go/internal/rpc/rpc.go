// Package rpc 承载 FFI 桥接的**纯 Go** 路由逻辑。
//
// 为什么单独成包（这是踩过坑的）：
// 桥接入口 `go/bridge.go` 含 `import "C"`，使整个 main 包**依赖 cgo**。
// 而 cgo 需要 C 编译器：本机默认 `CGO_ENABLED=0` 且无 gcc，
// 于是 `go test ./...` 与 `go vet ./...` 都编不过 main 包——
// 纯逻辑的单元测试就无从谈起（必须先用 NDK clang 交叉编译才行）。
//
// 把路由与信封逻辑移到这里后：
//   - 本包**零 cgo 依赖**，`go test ./internal/rpc` 在任意环境可跑
//   - `bridge.go` 退化为三个薄包装，只负责 C 字符串的分配/释放
//
// 这是"让边界层尽可能薄"的直接收益：可测面积变大，不可测面积只剩几行。
package rpc

import (
	"encoding/json"

	"cineflow/go/internal/media"
)

// BridgeVersion 是桥接协议版本。Dart 侧可校验，
// 避免 .so 与 Dart 代码版本错配后出现「调用了不存在的方法」。
const BridgeVersion = "1"

// Response 是所有方法的统一返回信封。
//
// 用显式 Ok/Error 而不是 HTTP 状态码或 panic：
// 让调用方只需判断一个布尔值，错误信息也能原样带回 Dart 便于提示用户。
type Response struct {
	Ok     bool            `json:"ok"`
	Error  string          `json:"error,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
}

// Request 是统一入参信封。空 payload 时各字段为零值。
//
// 字段按"域"分组（media.* 用前四项，pan115.* 用后面那些）。
// 用一个大结构体而不是 map[string]any：前者在 Go 侧有编译期类型检查，
// 写错字段名会编译失败；后者只会得到零值（静默失效）。
type Request struct {
	// ---- media.*（Emby 媒体规则）----
	Items  []media.Item    `json:"items"`
	Spec   *media.SortSpec `json:"spec"`
	Types  []string        `json:"types"`
	Field  media.SortField `json:"field"`
	Method string          `json:"method"`

	// ---- pan115.* ----
	// SessionID 区分登录会话；缺省为 "default"（当前只支持单账号）。
	SessionID string `json:"sessionId"`
	// 扫码会话三件套（qr.start 返回，qr.poll/finish 传回）
	UID  string `json:"uid"`
	Time int64  `json:"time"`
	Sign string `json:"sign"`
	// 凭据（session.restore 用）。⚠️ 这些是敏感值，只在内存与安全存储间传递。
	CID  string `json:"cid"`
	SEID string `json:"seid"`
	KID  string `json:"kid"`
	// 文件浏览
	//
	// ⚠️ 命名注意：115 的凭据里有 `CID`（客户端 ID），
	// 而文件浏览参数里的 cid 是**目录 ID**（category id）——同名不同义。
	// 若复用同一个字段，登录后浏览根目录会意外带着凭据里的 CID
	// 去列目录（结果不可预测）。故此处用 `dirId` 明确区分。
	DirID  string `json:"dirId"`
	Offset int64  `json:"offset"`
	Limit  int64  `json:"limit"`
	// ShowDir 是否包含目录
	ShowDir bool   `json:"showDir"`
	Asc     bool   `json:"asc"`
	Order   string `json:"order"`
	Suffix  string `json:"suffix"`
	Type    int    `json:"type"`
	// MaxPages 自动翻页上限（防死循环）
	MaxPages int `json:"maxPages"`
	// 播放
	PickCode string `json:"pickCode"`
	ItemID   string `json:"itemId"`
	// 全局开关（115）：nil=只读，非 nil=同时设置
	Enabled *bool `json:"enabled"`
	// 杂项
	Size int64 `json:"size"`
}

// OkJSON 序列化成功信封（纯 Go，不碰 C 堆）。
func OkJSON(v any) string {
	raw, err := json.Marshal(v)
	if err != nil {
		return ErrJSON("序列化结果失败: " + err.Error())
	}
	out, err := json.Marshal(Response{Ok: true, Result: raw})
	if err != nil {
		return ErrJSON("序列化信封失败: " + err.Error())
	}
	return string(out)
}

// ErrJSON 序列化失败信封。
func ErrJSON(msg string) string {
	out, _ := json.Marshal(Response{Ok: false, Error: msg})
	return string(out)
}

// ParseRequest 解析 payload；空串视为零值请求（不是错误）。
func ParseRequest(payload string) (Request, error) {
	var req Request
	if payload == "" {
		return req, nil
	}
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return req, err
	}
	return req, nil
}

// Dispatch 是路由主体：method + JSON payload → JSON 信封字符串。
//
// panic 在此被吃掉并转成错误信封——绝不能穿过 FFI 边界
// （那会直接终止宿主进程，Flutter 一起挂）。
func Dispatch(method, payload string) (out string) {
	defer func() {
		if r := recover(); r != nil {
			out = ErrJSON("内部错误: " + toString(r))
		}
	}()

	req, err := ParseRequest(payload)
	if err != nil {
		return ErrJSON("payload 不是合法 JSON: " + err.Error())
	}

	switch method {
	case "system.version":
		return OkJSON(map[string]string{"bridge": BridgeVersion})

	case "system.echo":
		return OkJSON(map[string]any{"echo": req})
	}

	// ---- 115 网盘（方法较多，单独成文件避免本文件膨胀）----
	//
	// 注意：先匹配 pan115.*，未命中才继续走下面的 media.* 分支。
	// 这样新增 115 方法时不必回来改这里。
	if out, handled := dispatchPan115(method, req); handled {
		return out
	}

	switch method {
	// ---- 媒体规则（与 internal/media 同源，Dart 侧可直接复用）----

	// 清洗 /Latest 裸数组：只保留可播放条目
	case "media.normalizeLatest":
		items := media.NormalizeLatest(req.Items)
		return OkJSON(map[string]any{"items": items, "count": len(items)})

	// 按类型复筛（服务端 IncludeItemTypes 不可信）
	case "media.filterByType":
		items := media.FilterByType(req.Items, req.Types)
		return OkJSON(map[string]any{"items": items, "count": len(items)})

	// 排序参数规范化：补方向 + 加次级键。
	// 返回可直接拼进 Emby 查询串的 SortBy / SortOrder。
	case "media.sortParams":
		spec := media.SortSpec{Field: req.Field}
		if req.Spec != nil {
			spec = *req.Spec
		}
		by, order := spec.Normalize()
		return OkJSON(map[string]string{"sortBy": by, "sortOrder": order})

	// 单条进度/是否看完/剩余分钟（口径与详情页、播放器一致）
	case "media.progress":
		if len(req.Items) == 0 {
			return ErrJSON("media.progress 需要一条 item")
		}
		it := req.Items[0]
		return OkJSON(map[string]any{
			"progress":        media.Progress(it),
			"completed":       media.Completed(it),
			"remainingMinute": media.RemainingMinutes(it),
			"playable":        media.IsPlayable(it),
		})

	default:
		return ErrJSON("未知方法: " + method)
	}
}

func toString(v any) string {
	switch s := v.(type) {
	case string:
		return s
	case error:
		return s.Error()
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return "未知错误"
		}
		return string(b)
	}
}
