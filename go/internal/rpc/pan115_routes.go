package rpc

import (
	"cineflow/go/internal/pan115"
)

// 115 网盘的 FFI 方法路由。
//
// ## 方法命名约定
//
// 沿用既有的 `域.动作` 形式，此处用 `pan115.` 前缀。
// Dart 侧只依赖这些方法名与返回的 JSON 字段，**不依赖 Go 内部结构**，
// 这样将来换 Synurang 生成 typed binding 时（ADR 0004 的替换约定），
// 只需改转发层。
//
// ## 返回约定（与全仓一致）
//
// 成功：`{ok:true, result:{...}}`
// 失败：`{ok:false, error:"中文可读原因"}`
//
// **错误一律转成中文可读文案**：这些 string 会被 UI 直接展示，
// 若把 Go 的 error 原样透出，用户会看到 `Get "https://...": dial tcp ...`
// 这类无意义内容。

// dispatchPan115 处理所有 pan115.* 方法。返回 (结果字符串, 是否已处理)。
func dispatchPan115(method string, req Request) (string, bool) {
	switch method {
	// ---- 登录（扫码）----

	case "pan115.qr.start":
		c := sessions.get(sessionIDOf(req))
		s, err := c.RequestQRCode()
		if err != nil {
			return ErrJSON(errText(err)), true
		}
		// 只回必要字段：uid/time/sign 是后续轮询要用的，
		// qrcode 是扫码内容，imageUrl 可直接给 UI 显示（实测是 PNG）。
		return OkJSON(map[string]any{
			"uid":      s.UID,
			"time":     s.Time,
			"sign":     s.Sign,
			"qrcode":   s.QRCode,
			"imageUrl": s.ImageURL(),
		}), true

	case "pan115.qr.poll":
		c := sessions.get(sessionIDOf(req))
		s := pan115.QRSession{UID: req.UID, Time: req.Time, Sign: req.Sign}
		if s.UID == "" {
			return ErrJSON("缺少 uid（请先调用 pan115.qr.start）"), true
		}
		st, err := c.PollQRStatus(s)
		if err != nil {
			return ErrJSON(errText(err)), true
		}
		return OkJSON(map[string]any{
			"status":   int(st),
			"label":    st.Label(),
			"terminal": st.Terminal(),
			// allowed=true 表示可以调 pan115.qr.finish 换凭据了
			"allowed": st == pan115.QRAllowed,
		}), true

	case "pan115.qr.finish":
		c := sessions.get(sessionIDOf(req))
		s := pan115.QRSession{UID: req.UID, Time: req.Time, Sign: req.Sign}
		if s.UID == "" {
			return ErrJSON("缺少 uid（请先调用 pan115.qr.start）"), true
		}
		cred, err := c.LoginByQRCode(s)
		if err != nil {
			return ErrJSON(errText(err)), true
		}
		sessions.setCredential(sessionIDOf(req), cred)
		// ★ 凭据要回给 Dart 侧存进安全存储。
		// 这是**唯一一次**把凭据传出 FFI 的时机——Go 侧不落盘。
		return OkJSON(map[string]any{
			"credential": map[string]string{
				"UID":  cred.UID,
				"CID":  cred.CID,
				"SEID": cred.SEID,
				"KID":  cred.KID,
			},
		}), true

	// ---- 会话恢复 ----

	case "pan115.session.restore":
		// 应用启动时把安全存储里的凭据交回 Go 侧，
		// 避免每次冷启动都要用户重新扫码。
		cred := pan115.Credential{
			UID:  req.UID,
			CID:  req.CID,
			SEID: req.SEID,
			KID:  req.KID,
		}
		if !cred.Valid() {
			return ErrJSON("凭据不完整（需要 UID/CID/SEID）"), true
		}
		sessions.setCredential(sessionIDOf(req), cred)
		return OkJSON(map[string]any{"ok": true}), true

	case "pan115.session.status":
		c := sessions.get(sessionIDOf(req))
		return OkJSON(map[string]any{"loggedIn": c.LoggedIn()}), true

	case "pan115.session.clear":
		sessions.setCredential(sessionIDOf(req), pan115.Credential{})
		return OkJSON(map[string]any{"ok": true}), true

	// ---- 账号信息 ----

	case "pan115.user.info":
		c := sessions.get(sessionIDOf(req))
		info, err := c.FetchUserInfo()
		if err != nil {
			return ErrJSON(errText(err)), true
		}
		return OkJSON(info), true

	// ---- 文件浏览 ----

	case "pan115.files.list":
		c := sessions.get(sessionIDOf(req))
		cid := req.DirID
		page, err := c.ListFiles(cid, pan115.ListOptions{
			Offset:  req.Offset,
			Limit:   req.Limit,
			ShowDir: req.ShowDir,
			Asc:     req.Asc,
			Order:   req.Order,
			Suffix:  req.Suffix,
			Type:    req.Type,
		})
		if err != nil {
			return ErrJSON(errText(err)), true
		}
		return OkJSON(map[string]any{
			"files":   filesToMaps(page.Files),
			"total":   page.Total,
			"offset":  page.Offset,
			"hasMore": page.HasMore,
		}), true

	case "pan115.files.all":
		// 一次拉全（自动翻页）。用于"媒体库扫描"这类需要全量的场景。
		// 上限 50 页，防止异常 count 导致死循环。
		c := sessions.get(sessionIDOf(req))
		limit := req.MaxPages
		if limit <= 0 {
			limit = 50
		}
		files, err := c.ListAll(req.DirID, pan115.ListOptions{
			ShowDir: req.ShowDir,
			Order:   req.Order,
			Suffix:  req.Suffix,
			Type:    req.Type,
		}, limit)
		if err != nil {
			return ErrJSON(errText(err)), true
		}
		return OkJSON(map[string]any{
			"files": filesToMaps(files),
			"count": len(files),
		}), true

	// ---- 播放 ----

	case "pan115.play.resolve":
		c := sessions.get(sessionIDOf(req))
		pick := req.PickCode
		if pick == "" && req.ItemID != "" {
			// UI 传的是文件 ID（与 Emby 侧 itemId 对齐），此处换 pickCode
			var err error
			pick, err = c.PickCodeFor(req.ItemID)
			if err != nil {
				return ErrJSON(errText(err)), true
			}
		}
		if pick == "" {
			return ErrJSON("缺少 pickCode 或 itemId"), true
		}
		link, err := c.ResolveDirectLink(pick)
		if err != nil {
			return ErrJSON(errText(err)), true
		}
		// ★ headers 必须回给 Dart：115 的 CDN 直链与取地址时的 UA 强绑定，
		// 播放器不带这些头会 403。Dart 侧会塞进 media_kit 的 httpHeaders。
		return OkJSON(map[string]any{
			"url":      link.URL,
			"fileName": link.FileName,
			"fileSize": link.FileSize,
			"headers":  link.Headers,
			"pickCode": pick,
		}), true

	case "pan115.play.invalidate":
		// CDN 返回 401/410（地址过期）时调用，下次会重新取地址。
		// 注意：403 是限流，不要调这个——重取只会加重限流。
		c := sessions.get(sessionIDOf(req))
		if req.PickCode == "" {
			return ErrJSON("缺少 pickCode"), true
		}
		c.InvalidateLink(req.PickCode)
		return OkJSON(map[string]any{"ok": true}), true

	// ---- 纯逻辑（无需网络，可离线单测）----

	case "pan115.sizeLabel":
		return OkJSON(map[string]string{
			"label": pan115.FormatSize(req.Size),
		}), true

	// ---- 全局开关与诊断（不发网络请求）----

	case "pan115.enabled":
		// 读取当前开关；带 enabled 参数时同时设置。
		// 用同一个方法名做读写，是为了让 Dart 侧只需记住一个方法。
		if req.Enabled != nil {
			pan115.SetEnabled(*req.Enabled)
		}
		return OkJSON(map[string]any{
			"enabled":         pan115.Enabled(),
			"dailyCap":        pan115.DailyRequestCap(),
			"usedToday":       pan115.BudgetUsedForTest(),
			"dailyCapReached": pan115.BudgetUsedForTest() >= pan115.DailyRequestCap(),
		}), true

	default:
		return "", false
	}
}

// filesToMaps 把文件列表转成 Dart 侧好用的 JSON 形状。
//
// 显式列出字段而不是直接 Marshal struct：这样 Dart 侧的键名是稳定的契约，
// Go 侧内部改字段名不会破坏 Dart 代码。
func filesToMaps(files []pan115.File) []map[string]any {
	out := make([]map[string]any, 0, len(files))
	for _, f := range files {
		out = append(out, map[string]any{
			"id":         f.ID,
			"name":       f.Name,
			"isDir":      f.IsDir,
			"size":       f.Size,
			"sizeLabel":  pan115.FormatSize(f.Size),
			"pickCode":   f.PickCode,
			"sha1":       f.SHA1,
			"updateTime": f.UpdateTime,
			"thumbUrl":   f.ThumbURL,
			"star":       f.Star,
		})
	}
	return out
}

// errText 把 error 转成可直接展示的中文文案。
//
// 对 LoginError 会额外区分"需要重新登录"——Dart 侧据此决定
// 是提示重试还是引导用户重新扫码（这个区分做错会让用户卡在无限重试里）。
func errText(err error) string {
	if err == nil {
		return ""
	}
	if le, ok := err.(*pan115.LoginError); ok {
		if le.NeedsQR {
			return le.Error() + "（需要重新扫码登录）"
		}
		return le.Error()
	}
	return err.Error()
}
