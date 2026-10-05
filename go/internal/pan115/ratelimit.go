package pan115

import (
	"strings"
	"sync"
	"time"
)

// 限流器。
//
// ## 为什么必须有（这是账号安全问题，不是性能优化）
//
// 上游有**真实前车之鉴**：issue #7 的场景与本项目几乎一致
// （WebDAV 挂 115 给 Emby 扫库），现象是**扫描媒体库时被拦截**，
// 返回 HTTP 418 + 阿里云 WAF 页；维护者判断原因是"文件数量过多、
// 调用分页 API 过多"，并明确警告**并发有封号风险**。
// 另一位贡献者的实测是"6000+ 文件并发时触发"。
//
// 因此本项目采取与生产级实现（OpenList）一致的口径：
//
//	全局 2 请求/秒、突发容量 1（即两次请求最小间隔 500ms）、**串行翻页**
//
// 宁可扫库慢一点，也不要冒封号风险——被封的是**用户的账号**。
type rateLimiter struct {
	mu       sync.Mutex
	interval time.Duration // 两次请求的最小间隔
	last     time.Time
}

// newRateLimiter 按"每秒 n 次"构造。
func newRateLimiter(perSecond int) *rateLimiter {
	if perSecond <= 0 {
		perSecond = 2
	}
	return &rateLimiter{interval: time.Second / time.Duration(perSecond)}
}

// 硬性每日请求上限。
//
// ## 为什么在"限速"之外还要再加一层"总量上限"
//
// 限速（2 req/s）控制的是**速率**，但控制不了**总量**：
// 一个整页拉全的循环、或用户反复进出页面，仍可能在几分钟内积累
// 上千次请求。而风控判定的依据里，总量往往比速率更关键。
//
// 上游的实测记录是"6000+ 文件并发时触发 WAF"——量级就在数千次。
// 故这里设一个**保守的每日上限**：达到后当天不再发请求，
// 直到进程重启或跨天。**宁可功能降级，也不要拿用户账号冒险。**
//
// 1800 次的取法：按 2 req/s 满速跑，约 15 分钟就会用完。
// 对正常使用（扫一个目录、播几集）远远够用；
// 而对"失控的循环"能在伤害发生前就刹住。
const dailyRequestCap = 1800

// requestBudget 是全局的"当日请求预算"。
//
// 进程级而非客户端级：多个 Client 实例（每次 FFI 调用可能新建）
// 必须共享同一个预算，否则上限形同虚设。
var requestBudget = struct {
	mu   sync.Mutex
	used int
	day  string // YYYY-MM-DD（本地时区）
}{}

// tryConsumeBudget 尝试消耗一次请求额度。
//
// 返回 false 表示**今日额度已用完**，调用方应当直接失败而不发请求。
// 跨天自动重置。
func tryConsumeBudget() bool {
	requestBudget.mu.Lock()
	defer requestBudget.mu.Unlock()

	today := time.Now().Format("2006-01-02")
	if requestBudget.day != today {
		requestBudget.day = today
		requestBudget.used = 0
	}
	if requestBudget.used >= dailyRequestCap {
		return false
	}
	requestBudget.used++
	return true
}

// BudgetUsedForTest 返回今日已用额度（供测试与诊断）。
func BudgetUsedForTest() int {
	requestBudget.mu.Lock()
	defer requestBudget.mu.Unlock()
	return requestBudget.used
}

// ResetBudgetForTest 清空当日额度。
//
// ⚠️ **仅供测试**：用于隔离"把额度用满"的测试与其它测试——
// 否则一个测试用满 1800 次后，同包所有后续测试都会因额度耗尽而失败
// （实测踩过：表现为一堆与测试意图完全无关的失败，很难一眼看出原因）。
//
// 生产代码**不得调用**它：那会让每日上限形同虚设。
func ResetBudgetForTest() {
	requestBudget.mu.Lock()
	defer requestBudget.mu.Unlock()
	requestBudget.used = 0
	requestBudget.day = ""
}

// wait 阻塞到允许发起下一次请求。
//
// 用"上次请求时刻 + 固定间隔"而不是令牌桶实现：
// 后者在突发时仍会连发（bucket 容量 >1），而我们要的是**严格串行节流**，
// 语义更直白也更容易验证。
func (r *rateLimiter) wait() {
	r.mu.Lock()
	now := time.Now()
	next := r.last.Add(r.interval)
	if now.Before(next) {
		sleep := next.Sub(now)
		// 先更新时间再睡，避免并发调用者同时醒来（把串行语义破坏掉）
		r.last = next
		r.mu.Unlock()
		time.Sleep(sleep)
		return
	}
	r.last = now
	r.mu.Unlock()
}

// isWAFBlocked 判断是否为 WAF 拦截页。
//
// ★ 上游把 WAF 页分成两类，**可绕过性不同**，这个区分有实际意义：
//
//	A 类：`<!doctypehtml>`（小写）+ title 405 —— 可由"带 UID cookie"绕过
//	B 类：`<!DOCTYPE html>`（大写）+ "阿里云 Web应用防火墙" —— 未能绕过
//
// 因此提示文案要分开：A 类应提示"检查登录状态"，B 类只能提示"稍后重试"。
func isWAFBlocked(body []byte) (blocked bool, classB bool) {
	s := string(body)
	if len(s) == 0 {
		return false, false
	}
	if len(s) > 4096 {
		s = s[:4096]
	}
	lower := strings.ToLower(s)

	// 先判 B 类：明确的 WAF 品牌页。
	// 特征是大写 `<!DOCTYPE html>` + 品牌名（A 类是小写 `<!doctypehtml>`）。
	if strings.Contains(s, "阿里云 Web应用防火墙") ||
		strings.Contains(s, "Web应用防火墙") ||
		strings.Contains(s, "阿里云Web应用防火墙") {
		return true, true
	}
	// 任何 HTML 响应都算被拦：这些端点**只应返回 JSON**，
	// 出现 HTML 一定是网关/WAF 兜底页而非业务响应。
	// 只判 `<!doctypehtml`/`访问被阻断` 会漏掉 WAF 的其他模板（实测有多种）。
	if strings.Contains(lower, "<!doctype") ||
		strings.Contains(lower, "<html") ||
		strings.Contains(s, "访问被阻断") ||
		strings.Contains(lower, "blocked as it may cause potential threats") {
		return true, false
	}
	return false, false
}

// looksLikeWAF 保留旧名以便既有的测试与调用点不改。
func looksLikeWAF(body []byte) bool {
	b, _ := isWAFBlocked(body)
	return b
}

// DailyRequestCap 返回每日请求上限（供 UI 展示与诊断）。
func DailyRequestCap() int { return dailyRequestCap }
