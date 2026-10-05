package pan115

import (
	"io"
	"net/http"
)

// 本文件只放**测试专用**的窄接口。
//
// 为什么要专开文件而不是让生产代码开导出方法：
// `newReq` 与 `do` 是内部实现细节，导出它们会扩大公开 API 面
// （将来重构就不再自由）。但集成测试必须能构造"与生产完全相同的请求"
// 并读原始字节——若让测试自己拼请求，就可能在测一个不存在的路径。
//
// 故用一个文件名表明用途 + 方法名带 ForTest 后缀，
// 让"这是测试用的"在代码里一眼可见。

// NewReqForTest 暴露 newReq，供集成测试构造与生产一致的请求。
func (c *Client) NewReqForTest(method, url string) (*http.Request, error) {
	return c.newReq(method, url)
}

// FetchBytesForTest 发请求并返回原始字节与 Content-Type。
//
// 不复用 do()：do() 会把响应体当 JSON 解析，而二维码端点返回的是图片。
func (c *Client) FetchBytesForTest(req *http.Request) ([]byte, string, error) {
	c.limiter.wait()
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, "", err
	}
	return body, resp.Header.Get("Content-Type"), nil
}
