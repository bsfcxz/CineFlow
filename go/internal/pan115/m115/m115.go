// 移植自 github.com/SheltonZhu/115driver 的 pkg/crypto/m115（MIT License）。
// 原版权归 SheltonZhu 所有。本移植遵守 MIT 条款保留署名。
//
// 上游源码：pkg/crypto/m115/public.go / rsa.go / util.go / xor.go
// 关键约束：常量逐字节取自上游，禁止改动；本包零 cgo，仅使用 Go 标准库。
package m115

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
)

// keyLen 是协议内嵌密钥长度：请求体以 16 字节一次性随机 key 开头（明文形式，随 RSA 一起保护）。
const keyLen = 16

// wireKeyLen 是 xorDeriveKey(key, 4) / (data, 12) 两个派生尺寸，均为上游硬编码常量：
//   - 4：客户端请求 body 的内层 XOR 密钥长度
//   - 12：服务端响应 body 的外层 XOR 密钥长度
const (
	innerKeySize = 4
	outerKeySize = 12
)

// GenerateKey 生成一次性的随机密钥（每次请求都要新生成）。
//
// 返回 32 个字符的小写十六进制串（= 16 字节 crypto/rand 随机数）。
// 上游此处是 [16]byte 类型；为满足调用方约定的 string 签名，这里做十六进制编码，
// 由 Encode/Decode 内部解码还原，协议字节完全一致。
//
// 注意：密钥只用于本次请求/响应对，不可复用，也不要求保密（它随请求体明文发送）。
func GenerateKey() string {
	var k [keyLen]byte
	// crypto/rand.Read 在正常系统上不会失败（Go 1.24+ 内部直接 panic）；
	// 本函数签名无 error 返回，失败时保持零值 key 并交由服务端拒绝，而不是伪造随机数。
	_, _ = io.ReadFull(rand.Reader, k[:])
	return hex.EncodeToString(k[:])
}

// Encode 加密明文（通常是 JSON 字节），返回可直接作为表单字段值的字符串。
//
// 处理链（与上游 public.go 的 Encode 逐步一致）：
//
//	key(16B) ‖ plain → XOR(derive(key,4)) → 整体反转 → XOR(clientKey 12B) → RSA → base64
//
// RSA 使用 115 内置公钥（1024 位，e=65537），PKCS#1 v1.5 填充后按 117 字节分块裸模幂。
// 由于 PKCS#1 v1.5 填充使用 crypto/rand，同一 (plain, key) 每次调用产生不同密文——这是
// 上游的既定行为，不做"为可测而固定种子"的改动。
func Encode(plain []byte, key string) string {
	return encodeWith(parseKey(key), rsaN, rsaE, plain)
}

// Decode 解密服务端返回的密文。
//
// 处理链（与上游 public.go 的 Decode 逐步一致）：
//
//	base64 → RSA → 剥掉 PKCS#1 头 → body = data[16:]
//	→ XOR(derive(内嵌前缀 16B, 12)) → 整体反转 → XOR(derive(调用方 key, 4))
//
// 注意最后一步用的是**调用方传入的 key**（即请求时 GenerateKey 的返回值），
// 而中间 12 字节那步用的是**密文内嵌前缀**派生的密钥——两者不可互换。
//
// 由于客户端只持有公钥指数 e，Decode 并非 Encode 的严格逆运算：把本包 Encode 的输出
// 直接喂给 Decode 只会得到垃圾（真实逆运算需要服务端私钥 d）。详见 rsa.go 与测试说明。
func Decode(encoded, key string) ([]byte, error) {
	return decodeWith(parseKey(key), rsaN, rsaE, encoded)
}

// encodeWith 是 Encode 的可参数化实现：n/exp 用于注入测试密钥对，生产路径传 115 内置公钥。
// 除 RSA 参数外，其余步骤与上游逐字对应。
func encodeWith(k [keyLen]byte, n, exp *big.Int, plain []byte) string {
	return base64.StdEncoding.EncodeToString(rsaEncryptWith(n, exp, encodePayload(k, plain)))
}

// encodePayload 生成 RSA 之前的明文载荷（本包与测试共用的"加密前半段"）：
//
//	k(16) ‖ plain → XOR(derive(k,4)) → reverse → XOR(clientKey)
func encodePayload(k [keyLen]byte, plain []byte) []byte {
	buf := make([]byte, keyLen+len(plain))
	copy(buf, k[:])
	copy(buf[keyLen:], plain)
	body := buf[keyLen:]
	xorTransform(body, xorDeriveKey(k[:], innerKeySize))
	reverseBytes(body)
	xorTransform(body, xorClientKey[:])
	return buf
}

// decodeWith 是 Decode 的可参数化实现（n/exp 用于测试注入；生产路径为 115 内置公钥）。
// 相比上游实现，这里补齐了长度校验：上游对过短/非法输入会 make([]byte, 负长度) 直接 panic。
func decodeWith(k [keyLen]byte, n, exp *big.Int, encoded string) ([]byte, error) {
	if encoded == "" {
		return nil, errors.New("m115: 密文为空")
	}
	cipher, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("m115: base64 解码失败: %w", err)
	}
	blockSize := (n.BitLen() + 7) / 8
	if len(cipher) == 0 || len(cipher)%blockSize != 0 {
		return nil, fmt.Errorf("m115: 密文长度 %d 不是 RSA 分块 %d 的整数倍（可能被截断）", len(cipher), blockSize)
	}
	data := rsaDecryptWith(n, exp, cipher)
	if len(data) < keyLen {
		return nil, fmt.Errorf("m115: 解密结果仅 %d 字节，不足 %d 字节内嵌 key 前缀", len(data), keyLen)
	}
	out := make([]byte, len(data)-keyLen)
	copy(out, data[keyLen:])
	xorTransform(out, xorDeriveKey(data[:keyLen], outerKeySize))
	reverseBytes(out)
	xorTransform(out, xorDeriveKey(k[:], innerKeySize))
	return out, nil
}

// parseKey 把调用方传入的 key 字符串还原为 16 字节密钥。
//
// 受支持的形态只有 GenerateKey 的输出（32 位十六进制）。其余输入按以下次序兜底，
// 目的是"永不 panic、行为确定"，而不是宣称协议上有效：
//  1. 恰好 16 字节的原始字节串（兼容直接传原始 key 的调用方）；
//  2. 其它任意字符串 → SHA-256 取前 16 字节（含空串）。
func parseKey(key string) [keyLen]byte {
	if b, err := hex.DecodeString(key); err == nil && len(b) == keyLen {
		return [keyLen]byte(b)
	}
	if len(key) == keyLen {
		return [keyLen]byte([]byte(key))
	}
	sum := sha256.Sum256([]byte(key))
	var out [keyLen]byte
	copy(out[:], sum[:])
	return out
}
