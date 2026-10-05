package pan115

import "sync"

// 全局启用开关。
//
// ## 为什么需要它（用户实测反馈的直接产物）
//
// 用户在用真机联调 115 时报告"快要触发风控了"，要求先停用登录。
// 这类需求说明一个事实：**访问非公开接口是有代价的，
// 而代价落在用户的账号上**（见 ADR 0007 的风险声明）。
//
// 因此除了"限速"与"每日总量上限"两道自动闸门外，
// 还提供一个**可由用户主动关闭**的总开关：
//
//   - 关闭后：`do()` 在任何请求前就返回错误，一个字节都不发
//   - 用途：用户察觉异常（如收到风控提示、或暂时不想用）时可立即止损
//   - 默认值：**关闭**（见下方说明）
//
// ⚠️ 这是"用户意图"而非"安全策略"——不要用它代替风控退避逻辑。
//
// ## 默认值为什么是**关闭**
//
// 用户实测反馈"快要触发风控了"后要求先停用 115。这说明了：
// 在当前阶段（未联调完、且用户已接近风控阈值），
// **"默认不发请求"才是对用户账号负责的选择**。
//
// 于是默认改为 **off**：应用启动后 115 一个请求都不会发，
// 直到用户主动在设置里打开。这比"默认开启 + 手动关"安全得多——
// 后者要求用户在察觉到异常时才去关，而那时风控往往已经触发了。
//
// 打开后仍有每日 1800 次的总量上限兜底（见 ratelimit.go）。
// defaultEnabled 是**默认开关状态**，抽成常量有两个目的：
//
//  1. 让"默认关闭"这件事在代码里是个**显式声明**，而不是散落在
//     结构体初始化里的一个字面量——改它需要改这里，评审时看得见。
//  2. 让测试能断言它（见 enabled_test.go 的 TestDefaultDisabled），
//     防止有人"顺手"改成默认开启。
//
// 为什么默认关闭：115 走非公开接口，每次请求都消耗用户账号的风控额度。
// 用户实测中已接近阈值并明确要求先停用。**默认不发请求**才是对用户负责。
const defaultEnabled = false

var enabledState = struct {
	mu sync.RWMutex
	on bool
}{on: defaultEnabled}

// SetEnabled 设置全局开关（供 FFI 方法调用）。
func SetEnabled(on bool) {
	enabledState.mu.Lock()
	defer enabledState.mu.Unlock()
	enabledState.on = on
}

// Enabled 返回当前是否启用。
func Enabled() bool {
	enabledState.mu.RLock()
	defer enabledState.mu.RUnlock()
	return enabledState.on
}

// pan115Enabled 是内部读法（与 Enabled 同义，供 do() 用）。
func pan115Enabled() bool { return Enabled() }
