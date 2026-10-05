// 移植自 github.com/SheltonZhu/115driver 的 pkg/crypto/m115（MIT License）。
// 原版权归 SheltonZhu 所有。本移植遵守 MIT 条款保留署名。
//
// 本文件对应上游 pkg/crypto/m115/rsa.go：115 自带的 1024 位 RSA 公钥与分块模幂。
package m115

import (
	"crypto/rand"
	"math/big"
)

// 115 网盘内置 RSA 公钥。模数逐字节取自上游 pkg/crypto/m115/rsa.go 的十六进制字面量，
// 指数与原代码一致为 0x10001。任何改动都会导致服务端拒绝——不要"修正"这两个常量。
var (
	rsaN, _ = big.NewInt(0).SetString(
		"8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021"+
			"36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633"+
			"8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1"+
			"0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683", 16)
	rsaE, _ = big.NewInt(0).SetString("10001", 16)
)

// rsaBits 是 115 内置公钥的位长。上游不写死这两个常量，而是由 _N.BitLen()/8 推导；
// 这里把位长显式声明、由它推导分块长度，避免"两个数字各自硬编码后悄悄漂移"。
// TestRSAKeyLengthMatchesModulus 断言 rsaN.BitLen() 确实等于 rsaBits。
const rsaBits = 1024

// rsaKeyLen 是 RSA 分块长度（字节）；1024 位 = 128 字节。
const rsaKeyLen = rsaBits / 8

// pkcs1Overhead 是 PKCS#1 v1.5 加密填充的固定开销（0x00 ‖ 0x02 ‖ ≥8 随机 ‖ 0x00），
// 故每个 RSA 分块的明文上限为 128-11 = 117 字节。
const pkcs1Overhead = 11

// rsaEncryptWith 用给定模数/指数做分块 RSA 加密，密文按模数字节长度对齐。
//
// 注意：这里没有使用 crypto/rsa（上游如此）。PKCS#1 v1.5 填充由本函数手工拼装，
// 与 crypto/rsa.EncryptPKCS1v15 等价；与之同样要求明文块 ≤ 117 字节，且填充字节
// 必须非零（否则解填充时会被误判为前导 0x00）。
func rsaEncryptWith(n, exp *big.Int, input []byte) []byte {
	keyLen := (n.BitLen() + 7) / 8
	out := make([]byte, 0, len(input)+keyLen)
	for off := 0; off < len(input); {
		size := keyLen - pkcs1Overhead
		if size > len(input)-off {
			size = len(input) - off
		}
		out = append(out, rsaEncryptBlockWith(n, exp, keyLen, input[off:off+size])...)
		off += size
	}
	return out
}

// rsaEncryptBlockWith 加密单个明文块（长度必须 ≤ keyLen-11），返回定长 keyLen 字节。
func rsaEncryptBlockWith(n, exp *big.Int, keyLen int, block []byte) []byte {
	padSize := keyLen - len(block) - 3
	pad := make([]byte, padSize)
	_, _ = rand.Read(pad)
	buf := make([]byte, keyLen)
	buf[0], buf[1] = 0x00, 0x02
	// 上游用 b%0xff+0x01 把每个填充字节压到 1..255，保证非零。
	for i, b := range pad {
		buf[2+i] = b%0xff + 0x01
	}
	buf[padSize+2] = 0x00
	copy(buf[padSize+3:], block)
	ret := new(big.Int).Exp(new(big.Int).SetBytes(buf), exp, n).Bytes()
	// 大整数转字节会丢掉前导零，这里补齐到定长，否则服务端按 128 字节切块会错位。
	out := make([]byte, keyLen)
	copy(out[keyLen-len(ret):], ret)
	return out
}

// rsaDecryptWith 对裸密文按 128 字节分块做模幂，并剥掉每块的 PKCS#1 头。
//
// 关键事实（决定了本协议的真实性质）：全流程**只有公开指数 e 参与**，没有任何私钥 d。
// 因此这不是真正的解密——对非本公钥加密（即服务端用私钥加密）的数据做模幂，结果并无
// 明文语义。上游也只是"取第一个 0x00 之后的内容"再往下走。详见 Decode 的说明。
func rsaDecryptWith(n, exp *big.Int, input []byte) []byte {
	keyLen := (n.BitLen() + 7) / 8
	out := make([]byte, 0, len(input))
	for off := 0; off < len(input); off += keyLen {
		end := off + keyLen
		if end > len(input) {
			end = len(input)
		}
		out = append(out, rsaDecryptBlockWith(n, exp, input[off:end])...)
	}
	return out
}

// rsaDecryptBlockWith 处理单个密文块：模幂后丢弃第一个 0x00 之前的内容。
func rsaDecryptBlockWith(n, exp *big.Int, block []byte) []byte {
	m := new(big.Int).Exp(new(big.Int).SetBytes(block), exp, n).Bytes()
	for i, b := range m {
		if b == 0 && i != 0 {
			return m[i+1:]
		}
	}
	// 与上游一致：整块没有可作为分隔的 0x00 时该块不产出任何字节。
	return nil
}
