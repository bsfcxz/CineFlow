package pan115

import (
	"encoding/json"

	"cineflow/go/internal/pan115/m115"
)

// 本文件是 m115 加密算法的**唯一调用点**。
//
// 之所以单独成文件：加密算法本身是有相当体量的移植代码
// （AES + RSA + XOR 组合），单独放 `m115/` 子包便于独立测试；
// 而协议层只需要两个动作——"加密请求参数"与"解密响应"。
// 把调用集中在这里，将来算法若变（115 改协议）只需改这一个文件。

// encodePickCode 生成取直链所需的加密表单值。
//
// 请求明文是一个 JSON 对象，**键名是 `pickcode`**（不是 `pick_code`）。
// 上游对两个键名有区分：`app/chrome/downurl` 用 `pickcode`，
// 而 `android/2.0/ufile/download` 用 `pick_code`。
// 写错键名**不会报错**，只会得到空的下载地址——属于静默失败，故特别注明。
func encodePickCode(pickCode string) (key string, payload string, err error) {
	key = m115.GenerateKey()
	plain, err := json.Marshal(map[string]string{"pickcode": pickCode})
	if err != nil {
		return "", "", err
	}
	return key, m115.Encode(plain, key), nil
}

// decodePayload 解密服务端返回的 data 字段。
func decodePayload(encoded, key string) ([]byte, error) {
	return m115.Decode(encoded, key)
}
