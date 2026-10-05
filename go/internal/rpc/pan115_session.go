package rpc

import (
	"sync"

	"cineflow/go/internal/pan115"
)

// 115 会话管理。
//
// ## 为什么需要它（FFI 是无状态的）
//
// Dart 侧每次调用都是 `CineFlowCall(method, payload)`，Go 侧不保留调用上下文。
// 但 115 的多数操作都需要**同一个已登录客户端**（凭据 + 直链缓存），
// 若每次调用都新建客户端，直链缓存会失效（导致每次都重取地址 → 触发限流）。
//
// 因此用进程内的会话表：Dart 侧首次登录后拿到 sessionID，
// 后续调用带上它。凭据本身仍由 **Dart 侧的安全存储**持有
// （见 AGENTS.md 安全红线），Go 侧只在内存里缓存，进程退出即消失。
type pan115Sessions struct {
	mu sync.Mutex
	m  map[string]*pan115.Client
	// 记住每个会话的凭据，便于 Dart 侧查询/迁移。
	cred map[string]pan115.Credential
}

var sessions = &pan115Sessions{
	m:    make(map[string]*pan115.Client),
	cred: make(map[string]pan115.Credential),
}

// 单会话模式：本项目当前只需登录一个 115 账号
// （多账号是 Phase 8 的后续需求，届时按 sessionID 区分即可）。
const defaultSessionID = "default"

func (s *pan115Sessions) get(id string) *pan115.Client {
	if id == "" {
		id = defaultSessionID
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.m[id]
	if !ok {
		// 未知会话：返回一个未登录客户端而不是错误。
		// 这样"还没登录就点浏览"会得到明确的"尚未登录"业务提示，
		// 而不是一个需要调用方额外处理的技术性错误。
		cred := s.cred[id]
		c = pan115.NewClient(cred)
		s.m[id] = c
	}
	return c
}

func (s *pan115Sessions) setCredential(id string, cred pan115.Credential) {
	if id == "" {
		id = defaultSessionID
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cred[id] = cred
	if c, ok := s.m[id]; ok {
		c.SetCredential(cred)
	} else {
		s.m[id] = pan115.NewClient(cred)
	}
}

// sessionIDOf 从请求里取会话 ID，缺省用 default。
func sessionIDOf(req Request) string {
	if req.SessionID == "" {
		return defaultSessionID
	}
	return req.SessionID
}
