// 移植自 github.com/SheltonZhu/115driver 的 pkg/crypto/m115（MIT License）。
// 原版权归 SheltonZhu 所有。本移植遵守 MIT 条款保留署名。
//
// 本文件是 m115 的离线单元测试。三个必须知道的测试前提：
//
//  1. 生产常量（115 内置 RSA 公钥 N/e）只持有公开指数 e，**没有私钥 d**。
//     因此 `Decode(Encode(x,k),k) == x` 在数学上不可能成立，真实逆运算需要服务端私钥。
//     协议里 Encode 与 Decode 服务于两个相反方向（客户端→服务端 / 服务端→客户端），
//     它们共用 e，但不是彼此的逆。本文件用"随堂生成的真实 RSA 密钥对 + 服务端模拟"
//     来验证两条方向各自的正确性（见 TestEncodeWireFormatViaServerPrivateKey 与
//     TestDecodeInvertsServerResponse）。
//  2. 该验证能证明 XOR/反转/分帧/分块/base64 这一整条**对称管线**是自洽的，
//     但不能证明生产常量与 115 线上公钥一致——后者只能靠源码出处与线上联调确认。
//  3. 未做线上联调（本机无可用的 115 账号凭据）。
package m115

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/hex"
	"math/big"
	"strings"
	"sync"
	"testing"
)

// ---------------------------------------------------------------------------
// 测试用 RSA 密钥对（本地生成，与 115 的生产公钥无关）
// ---------------------------------------------------------------------------

type testKeyPair struct {
	n *big.Int
	e *big.Int
	d *big.Int
}

var (
	testKPOnce sync.Once
	testKP     *testKeyPair
)

// testKeyPairForTest 生成 1024 位测试密钥对，用来在离线环境扮演"服务端私钥 d"。
// 生产路径永远不会用到 d（客户端只持有公钥）。
func testKeyPairForTest(t *testing.T) *testKeyPair {
	t.Helper()
	testKPOnce.Do(func() {
		priv, err := rsa.GenerateKey(rand.Reader, 1024)
		if err != nil {
			t.Fatalf("生成测试 RSA 密钥对失败: %v", err)
		}
		testKP = &testKeyPair{
			n: priv.N,
			e: big.NewInt(int64(priv.E)),
			d: priv.D,
		}
	})
	return testKP
}

// testKey 返回固定字节的 16 字节测试密钥（key 内容本身不影响管线正确性）。
func testKey(seed byte) [keyLen]byte {
	var k [keyLen]byte
	for i := range k {
		k[i] = seed + byte(i)
	}
	return k
}

// sealResponse 模拟**服务端**构造响应体：先用客户端 key 做内层 XOR，再整体反转，
// 用新随机前缀 R 的派生密钥（derive(R,12)）做外层 XOR，前置 R，最后用**私钥 d**
// 做分块 RSA 并对齐 128 字节，得到 base64。
//
// 这是 Decode 各步骤的严格逆序，因此是 Decode 的正确性基准。
func sealResponse(t *testing.T, plain []byte, k, r [keyLen]byte, n, d *big.Int) string {
	t.Helper()
	inner := make([]byte, len(plain))
	copy(inner, plain)
	xorTransform(inner, xorDeriveKey(k[:], innerKeySize))
	reverseBytes(inner)
	xorTransform(inner, xorDeriveKey(r[:], outerKeySize))

	payload := make([]byte, 0, keyLen+len(inner))
	payload = append(payload, r[:]...)
	payload = append(payload, inner...)

	// 服务端用私钥 d 做"加密"（RSA 里等价于签名方向），客户端用公钥 e 即可还原。
	cipher := rsaEncryptWith(n, d, payload)
	return base64.StdEncoding.EncodeToString(cipher)
}

// testInputs 覆盖题目要求的全部输入形态。
func testInputs() []struct {
	name  string
	plain []byte
} {
	long := strings.Repeat("长文本 payload 分块测试 abcdefghijklmnopqrstuvwxyz 0123456789 ", 40) // >1KB
	return []struct {
		name  string
		plain []byte
	}{
		{"空串", []byte{}},
		{"短ASCII", []byte("hi")},
		{"JSON", []byte(`{"pick_code":"abcd1234","share_code":"sw1abc","receive_code":""}`)},
		{"中文UTF8", []byte("115网盘下载地址：测试文件.mkv")},
		{"正好117字节分块边界", bytes.Repeat([]byte("A"), rsaKeyLen-pkcs1Overhead)},
		{"118字节跨分块", bytes.Repeat([]byte("B"), rsaKeyLen-pkcs1Overhead+1)},
		{"长文本(>1KB)", []byte(long)},
		{"含NUL与控制字节", []byte{0x00, 0x01, 0x7f, 0x80, 0xff, 0x00}},
	}
}

// ---------------------------------------------------------------------------
// 1. 方向一：Encode 的线格式（用测试私钥 d 扮演服务端解出，验证 PKCS#1 v1.5 + 分块）
// ---------------------------------------------------------------------------

func TestEncodeWireFormatViaServerPrivateKey(t *testing.T) {
	kp := testKeyPairForTest(t)
	key := testKey(0x10)

	for _, tc := range testInputs() {
		t.Run(tc.name, func(t *testing.T) {
			enc := encodeWith(key, kp.n, kp.e, tc.plain)

			raw, err := base64.StdEncoding.DecodeString(enc)
			if err != nil {
				t.Fatalf("Encode 输出不是合法 base64: %v", err)
			}
			// 分块校验：密文必须是 128 字节的整数倍。
			if len(raw)%rsaKeyLen != 0 {
				t.Fatalf("密文长度 %d 不是 %d 的整数倍", len(raw), rsaKeyLen)
			}
			wantPayload := encodePayload(key, tc.plain)
			wantBlocks := (len(wantPayload) + (rsaKeyLen - pkcs1Overhead) - 1) / (rsaKeyLen - pkcs1Overhead)
			if got := len(raw) / rsaKeyLen; got != wantBlocks {
				t.Fatalf("分块数 = %d，期望 %d（payload %d 字节）", got, wantBlocks, len(wantPayload))
			}

			// 服务端用私钥 d 解回：应精确还原 key‖XOR/反转后的明文。
			got := rsaDecryptWith(kp.n, kp.d, raw)
			if !bytes.Equal(got, wantPayload) {
				t.Fatalf("服务端解出的载荷与 encodePayload 不一致\n got=%x\nwant=%x", got, wantPayload)
			}
			// 线上协议约定：前 16 字节是本次请求的一次性 key。
			if !bytes.Equal(got[:keyLen], key[:]) {
				t.Fatalf("载荷前 16 字节不是请求 key: %x", got[:keyLen])
			}
		})
	}
}

// TestEncodedPayloadIsDeterministic 记录"哪一层是确定性的"：
// XOR/反转分帧这一层完全确定（同 key + 同明文 → 逐字节相同）；
// 不确定性只来自 RSA 的 PKCS#1 v1.5 随机填充（见下一个测试）。
func TestEncodedPayloadIsDeterministic(t *testing.T) {
	k := testKey(0x20)
	plain := []byte("deterministic-layer-check")

	a := encodePayload(k, plain)
	b := encodePayload(k, plain)
	if !bytes.Equal(a, b) {
		t.Fatalf("XOR/反转层应为确定性，实际不同\n a=%x\n b=%x", a, b)
	}
	if !bytes.Equal(a[:keyLen], k[:]) {
		t.Fatalf("载荷前缀应为 16 字节 key")
	}
}

// TestEncodeIsNonDeterministicDueToPKCS1Padding 断言实际行为：**非确定性**。
// 原因是 RSA PKCS#1 v1.5 的随机填充使用 crypto/rand（上游既定行为，
// 不为了"可测"而改成固定种子）。
func TestEncodeIsNonDeterministicDueToPKCS1Padding(t *testing.T) {
	key := GenerateKey()
	plain := []byte(`{"pick_code":"same-input"}`)

	first := Encode(plain, key)
	second := Encode(plain, key)
	if first == second {
		t.Fatal("同一 key + 同一明文两次 Encode 应产生不同密文（PKCS#1 v1.5 随机填充），实际相同——" +
			"请检查是否把 crypto/rand 换成了固定种子或去掉了填充")
	}
	// 但两者长度必须一致（分块数由明文长度决定）。
	if len(first) != len(second) {
		t.Fatalf("两次 Encode 长度不同: %d vs %d", len(first), len(second))
	}
}

// ---------------------------------------------------------------------------
// 2. 方向二：Decode 是服务端响应构造的严格逆（真正的往返验证）
// ---------------------------------------------------------------------------

func TestDecodeInvertsServerResponse(t *testing.T) {
	kp := testKeyPairForTest(t)
	key := testKey(0x30)
	r := testKey(0x90)

	for _, tc := range testInputs() {
		t.Run(tc.name, func(t *testing.T) {
			enc := sealResponse(t, tc.plain, key, r, kp.n, kp.d)

			got, err := decodeWith(key, kp.n, kp.e, enc)
			if err != nil {
				t.Fatalf("Decode 返回错误: %v", err)
			}
			if !bytes.Equal(got, tc.plain) {
				t.Fatalf("往返失败\n got=%q\nwant=%q", got, tc.plain)
			}
		})
	}
}

// TestDecodeIsDeterministic：同一密文 + 同一 key，重复 Decode 结果必须一致。
func TestDecodeIsDeterministic(t *testing.T) {
	kp := testKeyPairForTest(t)
	key := testKey(0x40)
	enc := sealResponse(t, []byte(`{"url":"https://cdn.example/x.mkv"}`), key, testKey(0xa0), kp.n, kp.d)

	first, err := decodeWith(key, kp.n, kp.e, enc)
	if err != nil {
		t.Fatalf("Decode 失败: %v", err)
	}
	second, err := decodeWith(key, kp.n, kp.e, enc)
	if err != nil {
		t.Fatalf("Decode 失败: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Fatalf("Decode 应为确定性: %q vs %q", first, second)
	}
}

// TestEncodeDecodeAreNotInversesByDesign 用**生产常量**断言上游的真实行为：
// `Decode(Encode(plain,key),key)` **不可能**还原明文。
//
// 这不是缺陷，是协议性质：客户端只有公开指数 e（rsa.go 里没有任何私钥 d 参与），
// Encode 与 Decode 分别面向服务端/客户端两个方向，互不为逆。
// 任何"修好"往返的改法（例如给 rsaDecrypt 传私钥 d）都会与 115 线上协议不符。
//
// 实测到的精确行为（见断言）：生产常量下，对本包 Encode 的输出做 Decode 时，
// 每块模幂后都找不到可作为 PKCS#1 分隔的 0x00，故解出 0 字节，本包返回 error。
// 上游源码同样会解出 0 字节，但它随后执行 make([]byte, 0-16) 会直接 panic；
// 本移植把该情形转成 error（Decode 的公开契约要求返回 error 而非 panic）。
func TestEncodeDecodeAreNotInversesByDesign(t *testing.T) {
	key := GenerateKey()
	plain := []byte(`{"pick_code":"abcd1234"}`)

	enc := Encode(plain, key)

	out, err := Decode(enc, key)
	if err == nil {
		// 允许"不报错但内容是垃圾"这条分支（服务端真实响应的正常路径），
		// 但绝不能还原出明文。
		if bytes.Equal(out, plain) {
			t.Fatal("Decode(Encode(x,k),k) 竟然还原了原文——说明 Encode/Decode 之一被改成了对称实现，" +
				"与 115 线上协议不符")
		}
		return
	}
	// 当前实现走的是这一支：解出 0 字节 → 报 error，而不是上游的 panic。
	if !strings.Contains(err.Error(), "不足") && !strings.Contains(err.Error(), "长度") {
		t.Fatalf("自产密文应因解出字节过少而报长度错误，实际: %v", err)
	}
}

// TestDecodeDoesNotPanicWhereUpstreamWould 固化对上游客栈的一个硬化：
// 上游 Decode 在解出 0 字节时执行 make([]byte, len(data)-16) 会 panic（负长度），
// 本移植返回 error。这里用"解不出内容的密文"直接验证不再 panic。
func TestDecodeDoesNotPanicWhereUpstreamWould(t *testing.T) {
	key := GenerateKey()
	enc := Encode([]byte(`{"pick_code":"panic-check"}`), key)

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("Decode 仍会 panic（上游负长度切片缺陷未硬化）: %v", r)
		}
	}()
	if _, err := Decode(enc, key); err == nil {
		t.Log("本次未走 error 分支（结果仍为垃圾，属可接受）")
	}
}

// ---------------------------------------------------------------------------
// 3. 密钥必须真的参与运算
// ---------------------------------------------------------------------------

func TestDifferentKeysDoNotInterop(t *testing.T) {
	kp := testKeyPairForTest(t)
	keyA := testKey(0x50)
	keyB := testKey(0x60)
	plain := []byte(`{"pick_code":"key-must-matter"}`)

	enc := sealResponse(t, plain, keyA, testKey(0xb0), kp.n, kp.d)

	ok, err := decodeWith(keyA, kp.n, kp.e, enc)
	if err != nil {
		t.Fatalf("正确 key 解密失败: %v", err)
	}
	if !bytes.Equal(ok, plain) {
		t.Fatalf("正确 key 未还原原文: %q", ok)
	}

	bad, err := decodeWith(keyB, kp.n, kp.e, enc)
	if err != nil {
		t.Fatalf("错误 key 不应报错（XOR 层无法感知），实际: %v", err)
	}
	if bytes.Equal(bad, plain) {
		t.Fatal("用 keyB 解密 keyA 的密文竟然得到了原文——key 没有真正参与运算")
	}
}

// TestGenerateKeyIsDifferentEveryTime 防止把 GenerateKey 误实现成常量。
func TestGenerateKeyIsDifferentEveryTime(t *testing.T) {
	const rounds = 512
	seen := make(map[string]struct{}, rounds)
	for i := 0; i < rounds; i++ {
		k := GenerateKey()
		if _, dup := seen[k]; dup {
			t.Fatalf("第 %d 次 GenerateKey 与之前重复: %s", i, k)
		}
		seen[k] = struct{}{}
	}
}

// TestGenerateKeyFormat 断言 key 形态：32 位小写十六进制 = 16 字节。
func TestGenerateKeyFormat(t *testing.T) {
	k := GenerateKey()
	if len(k) != 2*keyLen {
		t.Fatalf("GenerateKey 长度 = %d，期望 %d", len(k), 2*keyLen)
	}
	if k != strings.ToLower(k) {
		t.Fatalf("GenerateKey 应为小写十六进制: %s", k)
	}
	raw, err := hex.DecodeString(k)
	if err != nil {
		t.Fatalf("GenerateKey 不是合法十六进制: %v", err)
	}
	if len(raw) != keyLen {
		t.Fatalf("解码后长度 = %d，期望 %d", len(raw), keyLen)
	}
}

// TestEncodeOutputDiffersFromPlaintext 防"其实没加密"。
func TestEncodeOutputDiffersFromPlaintext(t *testing.T) {
	key := GenerateKey()
	for _, tc := range testInputs() {
		t.Run(tc.name, func(t *testing.T) {
			enc := Encode(tc.plain, key)
			if enc == string(tc.plain) {
				t.Fatalf("Encode 输出等于明文（未加密）")
			}
			if strings.Contains(enc, string(tc.plain)) && len(tc.plain) > 3 {
				t.Fatalf("Encode 输出中直接含有明文")
			}
			if enc == "" && len(tc.plain) > 0 {
				t.Fatalf("Encode 输出为空")
			}
			// 密文必须长于明文（RSA 膨胀）。
			if len(enc) <= len(tc.plain) {
				t.Fatalf("密文长度 %d 不大于明文长度 %d", len(enc), len(tc.plain))
			}
		})
	}
}

// TestEncodeAcceptsAnyKeyString 记录 parseKey 的兜底行为：不 panic、结果确定。
func TestEncodeAcceptsAnyKeyString(t *testing.T) {
	plain := []byte(`{"pick_code":"x"}`)
	for _, k := range []string{"", "short", strings.Repeat("z", 16), GenerateKey(), strings.Repeat("f", 64)} {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("key=%q 时 Encode panic: %v", k, r)
				}
			}()
			if out := Encode(plain, k); out == "" {
				t.Fatalf("key=%q 时 Encode 返回空", k)
			}
		}()
	}
}

// ---------------------------------------------------------------------------
// 4. 垃圾输入：必须返回 error，绝不 panic
// ---------------------------------------------------------------------------

func TestDecodeRejectsGarbage(t *testing.T) {
	key := GenerateKey()

	cases := []struct {
		name    string
		encoded string
	}{
		{"空串", ""},
		{"非base64字符", "!!!!not base64!!!!"},
		{"含非法填充的base64", "AAAA===="},
		{"长度不足一个RSA块", base64.StdEncoding.EncodeToString([]byte("short"))},
		{"100字节(非128倍数)", base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x41}, 100))},
		{"127字节(少1字节被截断)", base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, 127))},
		{"129字节(非128倍数)", base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x43}, 129))},
		{"全零128字节", base64.StdEncoding.EncodeToString(make([]byte, 128))},
		{"纯空白", "   "},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("Decode 对垃圾输入 panic 了: %v", r)
				}
			}()
			out, err := Decode(tc.encoded, key)
			if err == nil {
				t.Fatalf("期望 error，实际 err=nil out=%x", out)
			}
		})
	}
}

// TestDecodeNeverPanicsOnRandomInput 用随机字节与随机截断验证"不 panic"。
//
// 注意：随机字节偶尔可能通过 base64 + 分块校验并解出 ≥16 字节，从而**不报错**，
// 这是上游算法的固有性质（XOR 层无法校验完整性，也没有认证标签/MAC）。
// 所以这里断言的是"不 panic + 行为确定 + 不产生越界"，而不是"必然报错"——
// 强断言"随机输入必须报错"会写出一个偶发失败的测试。
func TestDecodeNeverPanicsOnRandomInput(t *testing.T) {
	key := GenerateKey()
	for i := 0; i < 200; i++ {
		n := i * 7 % 600
		garbage := make([]byte, n)
		if _, err := rand.Read(garbage); err != nil {
			t.Fatalf("rand.Read: %v", err)
		}

		var variants []string
		variants = append(variants, string(garbage))
		variants = append(variants, base64.StdEncoding.EncodeToString(garbage))
		if enc := base64.StdEncoding.EncodeToString(garbage); len(enc) > 4 {
			variants = append(variants, enc[:len(enc)/2]) // 截断的 base64
		}

		for _, v := range variants {
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Fatalf("Decode(%q) panic: %v", v, r)
					}
				}()
				first, err1 := Decode(v, key)
				second, err2 := Decode(v, key)
				if (err1 == nil) != (err2 == nil) {
					t.Fatalf("Decode 对同一输入两次结果不一致: %v vs %v", err1, err2)
				}
				if !bytes.Equal(first, second) {
					t.Fatalf("Decode 非确定性")
				}
			}()
		}
	}
}

// FuzzDecode 以 fuzz 目标固化"绝不 panic"（go test 默认只跑种子语料，
// 需要更深度覆盖时用 go test -fuzz=FuzzDecode）。
func FuzzDecode(f *testing.F) {
	f.Add("")
	f.Add("!!!!")
	f.Add(base64.StdEncoding.EncodeToString(make([]byte, 128)))
	f.Add(base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0xff}, 256)))
	f.Add(GenerateKey())
	f.Fuzz(func(t *testing.T, encoded string) {
		key := GenerateKey()
		out, err := Decode(encoded, key)
		if err == nil && out == nil {
			t.Fatalf("err=nil 时不应返回 nil 切片")
		}
	})
}

// ---------------------------------------------------------------------------
// 5. 常量与参数自检
// ---------------------------------------------------------------------------

// TestRSAKeyLengthMatchesModulus 断言硬编码的 128 与模数实际位长一致。
func TestRSAKeyLengthMatchesModulus(t *testing.T) {
	if got := rsaN.BitLen(); got != 1024 {
		t.Fatalf("RSA 模数位长 = %d，期望 1024", got)
	}
	if got := (rsaN.BitLen() + 7) / 8; got != rsaKeyLen {
		t.Fatalf("模数字节长 = %d，与 rsaKeyLen=%d 不一致", got, rsaKeyLen)
	}
	if rsaN.Sign() <= 0 {
		t.Fatal("RSA 模数解析失败（SetString 返回 nil）")
	}
	if rsaE == nil || rsaE.Int64() != 65537 {
		t.Fatalf("RSA 指数应为 65537，实际 %v", rsaE)
	}
	if rsaKeyLen-pkcs1Overhead != 117 {
		t.Fatalf("每块明文上限应为 117 字节，实际 %d", rsaKeyLen-pkcs1Overhead)
	}
}

// TestModulusMatchesUpstreamHex 把模数与上游十六进制字面量逐字符比对，
// 防止有人"顺手格式化"改坏常量。
func TestModulusMatchesUpstreamHex(t *testing.T) {
	const upstream = "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021" +
		"36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633" +
		"8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1" +
		"0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
	got := hex.EncodeToString(rsaN.Bytes())
	if got != upstream {
		t.Fatalf("RSA 模数与上游不一致\n got=%s\nwant=%s", got, upstream)
	}
}

// TestXorSeedLengthCoversDeriveIndex 断言种子长度足以支撑 size=4 与 size=12 的最大下标。
func TestXorSeedLengthCoversDeriveIndex(t *testing.T) {
	if len(xorKeySeed) != 144 {
		t.Fatalf("xorKeySeed 长度 = %d，期望 144", len(xorKeySeed))
	}
	for _, size := range []int{innerKeySize, outerKeySize} {
		maxIdx := size*size - 1
		if maxIdx >= len(xorKeySeed) {
			t.Fatalf("size=%d 需要下标 %d，超出种子长度 %d", size, maxIdx, len(xorKeySeed))
		}
	}
	if len(xorClientKey) != 12 {
		t.Fatalf("xorClientKey 长度 = %d，期望 12", len(xorClientKey))
	}
}

// TestXorDeriveKeyMatchesUpstreamFormula 用独立实现复算派生密钥，
// 避免"实现与测试互相证明"。
func TestXorDeriveKeyMatchesUpstreamFormula(t *testing.T) {
	seed := testKey(0x77)
	for _, size := range []int{innerKeySize, outerKeySize} {
		got := xorDeriveKey(seed[:], size)
		want := make([]byte, size)
		for i := 0; i < size; i++ {
			x := (int(seed[i]) + int(xorKeySeed[size*i])) & 0xff
			want[i] = byte(x ^ int(xorKeySeed[size*(size-i-1)]))
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("size=%d 派生密钥不一致\n got=%x\nwant=%x", size, got, want)
		}
	}
}

// TestXorTransformIsSelfInverse 断言 XOR 层可逆（自逆），这是管线正确性的基础。
func TestXorTransformIsSelfInverse(t *testing.T) {
	key := []byte{0x11, 0x22, 0x33, 0x44}
	for _, n := range []int{0, 1, 2, 3, 4, 5, 8, 13, 64} {
		data := make([]byte, n)
		for i := range data {
			data[i] = byte(i * 31)
		}
		orig := append([]byte(nil), data...)
		xorTransform(data, key)
		xorTransform(data, key)
		if !bytes.Equal(data, orig) {
			t.Fatalf("n=%d 时 xorTransform 非自逆", n)
		}
	}
}

// TestReverseBytesIsSelfInverse 覆盖奇数/偶数长度。
func TestReverseBytesIsSelfInverse(t *testing.T) {
	for _, n := range []int{0, 1, 2, 3, 18, 91, 128} {
		data := make([]byte, n)
		for i := range data {
			data[i] = byte(i)
		}
		orig := append([]byte(nil), data...)
		reverseBytes(data)
		reverseBytes(data)
		if !bytes.Equal(data, orig) {
			t.Fatalf("n=%d 时 reverseBytes 非自逆", n)
		}
	}
}

// TestParseKeyForms 记录 key 字符串的三种解析形态。
func TestParseKeyForms(t *testing.T) {
	raw := testKey(0x01)
	if got := parseKey(hex.EncodeToString(raw[:])); got != raw {
		t.Fatalf("十六进制形态解析不一致: %x vs %x", got, raw)
	}
	if got := parseKey(string(raw[:])); got != raw {
		t.Fatalf("16 字节原始形态解析不一致: %x vs %x", got, raw)
	}
	// 其它任意输入走 SHA-256 兜底，只要求确定且不 panic。
	a := parseKey("whatever")
	b := parseKey("whatever")
	if a != b {
		t.Fatal("兜底解析应确定")
	}
	if parseKey("") != parseKey("") {
		t.Fatal("空 key 兜底解析应确定")
	}
}
