// 移植自 github.com/SheltonZhu/115driver 的 pkg/crypto/m115（MIT License）。
// 原版权归 SheltonZhu 所有。本移植遵守 MIT 条款保留署名。
//
// 本文件对应上游 pkg/crypto/m115/util.go。
package m115

// reverseBytes reverses data in place.
//
// 上游对"反转范围"的调用是整段 buffer 反转：Encode 传入 buf[16:]（即 key 之后的整个
// 明文区），因此本函数永远只作用于调用方指定的切片，长度由调用方决定。
func reverseBytes(data []byte) {
	for i, j := 0, len(data)-1; i < j; i, j = i+1, j-1 {
		data[i], data[j] = data[j], data[i]
	}
}
