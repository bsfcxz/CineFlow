// Package main 编译为 C 共享库（-buildmode=c-shared），供 Flutter 经 dart:ffi 调用。
//
// 架构位置：计划书定的「Go 核心逻辑层」入口，对应
//
//	Flutter UI → (FFI) → Go 核心层 → Emby REST / 115 / TMDB
//
// ## 本文件只做一件事：C 边界的分配与释放
//
// 路由与业务逻辑全在 `internal/rpc`（纯 Go、零 cgo）。这样拆的**原因是踩过坑**：
// 本文件含 `import "C"`，会让整个 main 包依赖 cgo；而 cgo 需要 C 编译器
// （本机默认 CGO_ENABLED=0、且无 gcc），于是 `go test ./...` 与 `go vet ./...`
// 都编不过 main 包，纯逻辑的单元测试无从谈起。
//
// 拆开后：
//   - `go test ./internal/rpc ./internal/media` 在任意环境可跑（无需 cgo）
//   - 不可测面积只剩本文件这几十行
//
// ## 桥接方案的现状（务必读完再改）
//
// 计划书选型是 **Synurang（gRPC over FFI）**，但它的代码生成器
// `protoc-gen-synurang-ffi` 需要 Rust（`cargo install`），本机尚无 cargo/protoc。
// 当前用**与之同构的「方法名 + JSON」最小 C ABI** 打通链路：
// Synurang 生成的 C ABI 本质也是「扁平化参数 + 字符串缓冲」，
// 替换时**只改本文件的转发，不改 Dart 侧调用契约**
// （`GoCore.invoke(method, payload)` 语义不变）。
//
// ## 内存契约（最容易出错的地方）
//
// 所有返回 *C.char 的函数，其内存都用 C.CString 分配在 C 堆上，
// **必须**由 Dart 侧调用 CineFlowFree 释放。漏掉就是每次调用泄漏一块。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	"cineflow/go/internal/rpc"
)

// CineFlowPing 最小连通性探针。
//
// 走**专用符号**而不是统一入口，是为了在"dispatch 本身出问题"时
// 仍有一个最简通道可做诊断。
//
//export CineFlowPing
func CineFlowPing() *C.char {
	return C.CString(rpc.OkJSON(map[string]string{
		"pong":    "cineflow-go",
		"version": rpc.BridgeVersion,
	}))
}

// CineFlowCall 统一调用入口。
//
// method 为点分方法名（见 internal/rpc.Dispatch），payload 为 JSON 编码的 Request。
// 返回值是 JSON 编码的 Response——**必须由 Dart 侧调用 CineFlowFree 释放**。
//
//export CineFlowCall
func CineFlowCall(method *C.char, payload *C.char) *C.char {
	return C.CString(rpc.Dispatch(C.GoString(method), C.GoString(payload)))
}

// CineFlowFree 释放由本库分配、传回 Dart 的字符串。
//
// 必须成对调用，否则每次调用泄漏一块 C 堆内存。
//
//export CineFlowFree
func CineFlowFree(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// main 在 -buildmode=c-shared 下不会被执行，但包名必须是 main。
func main() {}
